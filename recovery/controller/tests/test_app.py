import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

import yaml


CONTROLLER_DIR = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("recovery_controller", CONTROLLER_DIR / "app.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class RecoveryControllerTest(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.evidence = Path(self.temp_dir.name) / "events.jsonl"
        self.policy = Path(self.temp_dir.name) / "policy.yml"
        self.policy.write_text(
            yaml.safe_dump(
                {
                    "NginxDown": {
                        "max_attempts": 2,
                        "cooldown_seconds": 60,
                        "action": {
                            "executable": "scripts/recover_service.sh",
                            "args": ["webservers", "nginx"],
                        },
                        "verify": {
                            "executable": "scripts/verify_service.sh",
                            "args": ["webservers", "nginx"],
                        },
                    },
                    "AlwaysFails": {
                        "max_attempts": 2,
                        "cooldown_seconds": 0,
                        "action": {"executable": "scripts/fail_test.sh"},
                    },
                }
            ),
            encoding="utf-8",
        )
        app = MODULE.create_app(
            {
                "TESTING": True,
                "RECOVERY_MAP_FILE": str(self.policy),
                "RECOVERY_EVIDENCE_FILE": str(self.evidence),
                "RECOVERY_BASE_DIR": str(CONTROLLER_DIR),
                "SLACK_WEBHOOK_URL": None,
            }
        )
        self.client = app.test_client()

    def tearDown(self):
        self.temp_dir.cleanup()

    def fixture(self, name):
        path = Path(__file__).with_name("fixtures") / name
        return json.loads(path.read_text(encoding="utf-8"))

    def events(self):
        return [json.loads(line) for line in self.evidence.read_text(encoding="utf-8").splitlines()]

    def test_health(self):
        response = self.client.get("/health")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json(), {"status": "running"})

    def test_success_writes_structured_evidence(self):
        response = self.client.post("/webhook", json=self.fixture("nginx_down.json"))
        result = response.get_json()["results"][0]
        self.assertEqual(result["outcome"], "success")
        self.assertEqual(result["attempts"], 1)
        event = self.events()[0]
        self.assertEqual(event["alertname"], "NginxDown")
        self.assertIn("duration_seconds", event)
        self.assertIn("event_id", event)

    def test_second_identical_alert_is_suppressed_by_cooldown(self):
        payload = self.fixture("nginx_down.json")
        self.client.post("/webhook", json=payload)
        response = self.client.post("/webhook", json=payload)
        result = response.get_json()["results"][0]
        self.assertEqual(result["outcome"], "skipped")
        self.assertEqual(result["reason"], "cooldown_active")

    def test_unknown_alert_is_recorded_without_execution(self):
        response = self.client.post("/webhook", json=self.fixture("unknown.json"))
        result = response.get_json()["results"][0]
        self.assertEqual(result["outcome"], "unmapped")
        self.assertEqual(result["attempts"], 0)

    def test_resolved_alert_is_skipped(self):
        response = self.client.post("/webhook", json=self.fixture("resolved.json"))
        result = response.get_json()["results"][0]
        self.assertEqual(result["outcome"], "skipped")
        self.assertEqual(result["reason"], "not_firing")

    def test_action_failure_retries_and_records_failure(self):
        payload = {
            "alerts": [
                {
                    "status": "firing",
                    "labels": {"alertname": "AlwaysFails", "instance": "test-host"},
                }
            ]
        }
        response = self.client.post("/webhook", json=payload)
        result = response.get_json()["results"][0]
        self.assertEqual(result["outcome"], "failed")
        self.assertEqual(result["reason"], "action_failed")
        self.assertEqual(result["attempts"], 2)

    def test_invalid_payload_is_rejected(self):
        response = self.client.post("/webhook", json={"not_alerts": []})
        self.assertEqual(response.status_code, 400)
        self.assertFalse(self.evidence.exists())


if __name__ == "__main__":
    unittest.main()
