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


if __name__ == "__main__":
    unittest.main()
