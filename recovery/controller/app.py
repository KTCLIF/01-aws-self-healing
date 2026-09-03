"""Policy-driven Alertmanager recovery webhook with JSONL evidence."""

import json
import os
import subprocess
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import requests
import yaml
from flask import Flask, jsonify, request


BASE_DIR = Path(__file__).resolve().parent
DEFAULT_MAP_FILE = BASE_DIR / "config" / "recovery_map.yml"
DEFAULT_EVIDENCE_FILE = BASE_DIR.parent.parent / "artifacts" / "recovery-events.jsonl"
_EVIDENCE_LOCK = threading.Lock()


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _load_policy(path: Path) -> Dict[str, Any]:
    with path.open(encoding="utf-8") as stream:
        policy = yaml.safe_load(stream) or {}
    if not isinstance(policy, dict):
        raise ValueError("recovery map must be a mapping")
    return policy


def _safe_executable(raw_path: str, base_dir: Path) -> Path:
    candidate = (base_dir / raw_path).resolve()
    scripts_dir = (base_dir / "scripts").resolve()
    if scripts_dir not in candidate.parents:
        raise ValueError("executable must be under controller/scripts")
    if not candidate.is_file() or not os.access(candidate, os.X_OK):
        raise ValueError(f"executable is missing or not executable: {raw_path}")
    return candidate


def _command(spec: Dict[str, Any], base_dir: Path) -> List[str]:
    executable = _safe_executable(str(spec.get("executable", "")), base_dir)
    args = spec.get("args", [])
    if not isinstance(args, list) or not all(isinstance(arg, str) for arg in args):
        raise ValueError("command args must be a list of strings")
    return [str(executable), *args]


def _run(spec: Dict[str, Any], base_dir: Path, default_timeout: int) -> subprocess.CompletedProcess:
    timeout = int(spec.get("timeout_seconds", default_timeout))
    if not 1 <= timeout <= 300:
        raise ValueError("timeout_seconds must be between 1 and 300")
    return subprocess.run(
        _command(spec, base_dir),
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
        timeout=timeout,
    )


def _append_evidence(path: Path, event: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with _EVIDENCE_LOCK, path.open("a", encoding="utf-8") as stream:
        stream.write(json.dumps(event, ensure_ascii=False, sort_keys=True) + "\n")


def _notify_slack(url: Optional[str], message: str) -> None:
    if not url:
        return
    try:
        requests.post(url, json={"text": message}, timeout=5).raise_for_status()
    except requests.RequestException:
        # Recovery outcome must not be changed by an optional notification failure.
        return


def create_app(config: Optional[Dict[str, Any]] = None) -> Flask:
    app = Flask(__name__)
    app.config.from_mapping(
        RECOVERY_MAP_FILE=os.getenv("RECOVERY_MAP_FILE", str(DEFAULT_MAP_FILE)),
        RECOVERY_EVIDENCE_FILE=os.getenv("RECOVERY_EVIDENCE_FILE", str(DEFAULT_EVIDENCE_FILE)),
        SLACK_WEBHOOK_URL=os.getenv("SLACK_WEBHOOK_URL"),
        RECOVERY_BASE_DIR=str(BASE_DIR),
    )
    if config:
        app.config.update(config)

    cooldowns = {}  # type: Dict[str, float]

    @app.get("/health")
    def health():
        return jsonify({"status": "running"}), 200

    @app.post("/webhook")
    def webhook():
        payload = request.get_json(silent=True)
        if not isinstance(payload, dict) or not isinstance(payload.get("alerts"), list):
            return jsonify({"status": "error", "message": "alerts array is required"}), 400

        policy = _load_policy(Path(app.config["RECOVERY_MAP_FILE"]))
        evidence_path = Path(app.config["RECOVERY_EVIDENCE_FILE"])
        base_dir = Path(app.config["RECOVERY_BASE_DIR"])
        event_id = str(uuid.uuid4())
        results = []

        for alert in payload["alerts"]:
            started_monotonic = time.monotonic()
            started_at = _utc_now()
            labels = alert.get("labels", {}) if isinstance(alert, dict) else {}
            alertname = str(labels.get("alertname", "UNKNOWN"))
            instance = str(labels.get("instance", "UNKNOWN"))
            alert_status = str(alert.get("status", payload.get("status", "firing")))
            key = f"{alertname}:{instance}"
            result = {
                "event_id": event_id,
                "alertname": alertname,
                "instance": instance,
                "status": alert_status,
                "started_at": started_at,
                "attempts": 0,
            }

            if alert_status != "firing":
                result.update(outcome="skipped", reason="not_firing")
            elif alertname not in policy:
                result.update(outcome="unmapped", reason="no_policy")
            else:
                recovery = policy[alertname]
                cooldown = int(recovery.get("cooldown_seconds", 0))
                remaining = cooldown - (time.monotonic() - cooldowns.get(key, 0))
                if key in cooldowns and remaining > 0:
                    result.update(outcome="skipped", reason="cooldown_active")
                    result["cooldown_remaining_seconds"] = round(remaining, 3)
                else:
                    retries = int(recovery.get("max_attempts", 1))
                    retries = min(max(retries, 1), 5)
                    reason = "recovery_failed"
                    for attempt in range(1, retries + 1):
                        result["attempts"] = attempt
                        try:
                            action = _run(recovery["action"], base_dir, 60)
                            if action.returncode != 0:
                                reason = "action_failed"
                                continue
                            verification = recovery.get("verify")
                            if verification:
                                verified = _run(verification, base_dir, 30)
                                if verified.returncode != 0:
                                    reason = "verification_failed"
                                    continue
                        except (KeyError, TypeError, ValueError) as exc:
                            reason = f"invalid_policy:{exc}"
                            break
                        except subprocess.TimeoutExpired:
                            reason = "timeout"
                            continue

                        cooldowns[key] = time.monotonic()
                        result.update(outcome="success", reason="verified")
                        break
                    else:
                        result.update(outcome="failed", reason=reason)
                    if "outcome" not in result:
                        result.update(outcome="failed", reason=reason)

            result["finished_at"] = _utc_now()
            result["duration_seconds"] = round(time.monotonic() - started_monotonic, 6)
            _append_evidence(evidence_path, result)
            results.append(result)

            if result["outcome"] == "success":
                _notify_slack(app.config.get("SLACK_WEBHOOK_URL"), f"Recovery succeeded: {alertname} on {instance}")
            elif result["outcome"] == "failed":
                _notify_slack(app.config.get("SLACK_WEBHOOK_URL"), f"Recovery failed: {alertname} on {instance} ({result['reason']})")

        return jsonify({"status": "accepted", "event_id": event_id, "results": results}), 200

    return app


app = create_app()


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5001)
