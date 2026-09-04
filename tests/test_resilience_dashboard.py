import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OBSERVABILITY = ROOT / "observability" / "resilience-experiment"
DASHBOARD = OBSERVABILITY / "grafana" / "dashboards" / "resilience-experiment.json"
COMPOSE = OBSERVABILITY / "docker-compose.yml"
EXPORTER = OBSERVABILITY / "metrics-exporter" / "metrics_exporter.py"
MOCK = OBSERVABILITY / "mock" / "generate_mock.py"
CURATOR = ROOT / "experiments" / "aws-web-host-loss" / "curate_evidence.py"


def load_module(name, path):
    specification = importlib.util.spec_from_file_location(name, str(path))
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class ResilienceDashboardTest(unittest.TestCase):
    def test_dashboard_has_one_bounded_three_row_story(self):
        dashboard = json.loads(DASHBOARD.read_text(encoding="utf-8"))
        rows = [panel["title"] for panel in dashboard["panels"] if panel["type"] == "row"]
        self.assertEqual(rows, [
            "Experiment Summary",
            "Service Availability",
            "Infrastructure Recovery",
        ])
        panel_titles = {panel["title"] for panel in dashboard["panels"]}
        self.assertTrue({
            "Current HTTP Availability",
            "Continuous HTTP Probe",
            "Target Health and Capacity",
            "Recovery Events",
            "Evidence Source",
        } <= panel_titles)
        annotations = dashboard["annotations"]["list"]
        self.assertEqual(annotations[0]["expr"], "changes(p1_event_reached[2s]) > 0")

    def test_local_stack_has_no_cloudwatch_or_aws_credentials(self):
        text = COMPOSE.read_text(encoding="utf-8")
        self.assertNotIn("cloudwatch", text.lower())
        self.assertNotIn("AWS_ACCESS_KEY", text)
        self.assertNotIn(".aws", text)
        self.assertIn('127.0.0.1:${P01_GRAFANA_PORT:-33000}:3000', text)
        self.assertIn('127.0.0.1:${P01_PROMETHEUS_PORT:-39090}:9090', text)

    def test_exporter_renders_probe_capacity_and_events(self):
        exporter = load_module("metrics_exporter", EXPORTER)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "probes.tsv").write_text(
                "1000\t1970-01-01T00:00:01.000Z\t1\tnode-a\n"
                "1250\t1970-01-01T00:00:01.250Z\t0\t\n",
                encoding="utf-8",
            )
            (root / "state.json").write_text(json.dumps({
                "phase": "degraded",
                "probe_file": "probes.tsv",
                "desired_capacity": 2,
                "inservice_instances": 1,
                "healthy_targets": 1,
                "events": {"failure_injected": 1.0},
                "synthetic": True,
            }), encoding="utf-8")
            metrics = exporter.render_metrics(root / "state.json")
        self.assertIn("p1_http_availability_percent 50.000000", metrics)
        self.assertIn("p1_alb_healthy_targets 1", metrics)
        self.assertIn('p1_event_reached{event="failure_injected"} 1', metrics)
        self.assertIn("p1_synthetic_evidence 1", metrics)

    def test_mock_and_curator_are_explicitly_synthetic_and_identifier_free(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(
                ["python3", str(MOCK), "--artifact-dir", str(root), "--tick-seconds", "0"],
                check=True,
                stdout=subprocess.PIPE,
                universal_newlines=True,
            )
            raw_path = root / "mock-raw-evidence.json"
            raw = json.loads(raw_path.read_text(encoding="utf-8"))
            raw["failure"] = {"target": "i-sensitive"}
            raw["aws_state"] = {"target_group_arn": "arn:sensitive"}
            raw_path.write_text(json.dumps(raw), encoding="utf-8")
            output_json = root / "curated.json"
            output_md = root / "summary.md"
            subprocess.run([
                "python3", str(CURATOR), str(raw_path),
                "--status", str(root / "mock-aws-status.jsonl"),
                "--json-output", str(output_json),
                "--markdown-output", str(output_md),
            ], check=True)
            curated_text = output_json.read_text(encoding="utf-8")
            summary = output_md.read_text(encoding="utf-8")
        self.assertNotIn("i-sensitive", curated_text)
        self.assertNotIn("arn:sensitive", curated_text)
        self.assertIn('"evidence_class": "synthetic_mock"', curated_text)
        self.assertIn("SYNTHETIC MOCK", summary)

if __name__ == "__main__":
    unittest.main()
