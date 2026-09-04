import os
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "scripts" / "aws-account-guard.sh"
EXPERIMENT = ROOT / "experiments" / "aws-web-host-loss" / "run-experiment.sh"
RUNBOOK = ROOT / "docs" / "aws-web-host-loss-runbook.md"


class AwsAccountGuardTest(unittest.TestCase):
    def run_guard(self, extra_environment=None):
        environment = os.environ.copy()
        for name in (
            "AWS_PROFILE",
            "P1_EXPECTED_ACCOUNT_ID",
            "P1_EXPECTED_REGION",
            "ALLOW_DEFAULT_PROFILE_FOR_P1",
        ):
            environment.pop(name, None)
        environment.update(extra_environment or {})
        return subprocess.run(
            [str(GUARD)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            env=environment,
        )

    def test_requires_explicit_profile(self):
        result = self.run_guard()
        self.assertNotEqual(result.returncode, 0)

    def test_default_profile_requires_separate_override(self):
        result = self.run_guard({
            "AWS_PROFILE": "default",
            "P1_EXPECTED_ACCOUNT_ID": "000000000000",
        })
        self.assertEqual(result.returncode, 2)
        self.assertIn("Refusing the default profile", result.stderr)

    def test_destructive_harness_invokes_guard_and_explicit_profile(self):
        text = EXPERIMENT.read_text(encoding="utf-8")
        self.assertIn('scripts/aws-account-guard.sh', text)
        self.assertIn('--profile "$profile"', text)

    def test_runbook_requires_independent_default_profile_check(self):
        text = RUNBOOK.read_text(encoding="utf-8")
        self.assertIn("aws sts get-caller-identity --profile default", text)
        self.assertIn("ALLOW_DEFAULT_PROFILE_FOR_P1=yes", text)
        self.assertIn("not by assigning the STS output back as the expectation", text)


if __name__ == "__main__":
    unittest.main()
