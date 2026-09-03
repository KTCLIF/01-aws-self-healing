import json
import unittest
from datetime import datetime
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "docs" / "evidence" / "web-host-loss-local-20260904.json"
SCHEMA = ROOT / "experiments" / "web-host-loss" / "evidence.schema.json"


def timestamp(value):
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%S.%fZ")


class WebHostLossEvidenceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = json.loads(EVIDENCE.read_text(encoding="utf-8"))
        cls.schema = json.loads(SCHEMA.read_text(encoding="utf-8"))

    def test_schema_declares_required_evidence(self):
        required = set(self.schema["required"])
        self.assertTrue({"failure", "pre_failure", "timeline", "recovery", "failure_reason"} <= required)

    def test_curated_runs_have_ordered_timestamps_and_consistent_duration(self):
        self.assertEqual(len(self.document["runs"]), 2)
        for run in self.document["runs"]:
            timeline = run["timeline"]
            injected = timestamp(timeline["failure_injected_at"])
            detected = timestamp(timeline["failure_detected_at"])
            recovery_started = timestamp(timeline["recovery_started_at"])
            ready = timestamp(timeline["workload_ready_at"])
            recovered = timestamp(timeline["service_recovered_at"])
            self.assertLessEqual(injected, detected)
            self.assertLessEqual(detected, recovery_started)
            self.assertLessEqual(recovery_started, ready)
            self.assertLessEqual(ready, recovered)
            measured = (recovered - injected).total_seconds()
            self.assertAlmostEqual(measured, run["recovery"]["total_duration_seconds"], places=2)
            self.assertEqual(run["recovery"]["outcome"], "success")
            self.assertIsNone(run["failure_reason"])

    def test_host_failure_moves_workload_to_surviving_node(self):
        host_run = next(run for run in self.document["runs"] if run["scenario"] == "host_failure")
        self.assertNotEqual(
            host_run["recovery"]["original_node"],
            host_run["recovery"]["new_node"],
        )
        self.assertTrue(host_run["recovery"]["service_unavailable_observed"])


if __name__ == "__main__":
    unittest.main()
