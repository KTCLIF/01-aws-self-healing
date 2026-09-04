import os
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "experiments" / "aws-web-host-loss" / "run-experiment.sh"


class AwsExperimentSafetyGuardTest(unittest.TestCase):
    def test_runner_refuses_without_explicit_destructive_gate(self):
        environment = os.environ.copy()
        environment.pop("EXECUTE_AWS_HOST_LOSS", None)
        result = subprocess.run(
            [str(RUNNER)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            env=environment,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("Refusing to terminate an AWS instance", result.stderr)

    def test_screenshot_checkpoints_do_not_pause_recovery_polling(self):
        text = RUNNER.read_text(encoding="utf-8")
        termination = text.index("aws ec2 terminate-instances")
        checkpoint_a = text.index("wait_for_screenshot A")
        checkpoint_b = text.index("CHECKPOINT_B_READY")
        convergence = text.index('if [[ -n "$replacement_ready_at"')
        checkpoint_c = text.index("wait_for_screenshot C")
        evidence = text.index('>"$evidence_file"')
        self.assertLess(checkpoint_a, termination)
        self.assertLess(checkpoint_b, convergence)
        self.assertNotIn("wait_for_screenshot B", text)
        self.assertGreater(checkpoint_c, evidence)

    def test_harness_preserves_success_and_failure_machine_evidence(self):
        text = RUNNER.read_text(encoding="utf-8")
        self.assertIn('status_log="${artifact_dir}/${run_id}-aws-status.jsonl"', text)
        self.assertIn('failure_evidence_file="${artifact_dir}/${run_id}-failure.json"', text)
        self.assertIn("failure_reason:$reason", text)
        self.assertIn('python3 "$script_dir/curate_evidence.py"', text)
        self.assertIn('require_dashboard_state "100"', text)
        self.assertIn('/api/dashboards/uid/p01-resilience', text)


if __name__ == "__main__":
    unittest.main()
