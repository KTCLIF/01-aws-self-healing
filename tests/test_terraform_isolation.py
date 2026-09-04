import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TF_DIR = ROOT / "infra" / "terraform"
TF_TEXT = "\n".join(path.read_text(encoding="utf-8") for path in TF_DIR.glob("*.tf"))


class TerraformIsolationContractTest(unittest.TestCase):
    def test_p1_has_dedicated_local_state_path(self):
        self.assertIn('backend "local"', TF_TEXT)
        self.assertIn('path = "state/p01-self-healing.tfstate"', TF_TEXT)

    def test_identity_tags_are_fixed(self):
        self.assertIn('Project   = "01-aws-self-healing"', TF_TEXT)
        self.assertIn('Owner     = "KTCLIF"', TF_TEXT)
        self.assertIn('Purpose   = "portfolio-resilience-test"', TF_TEXT)

    def test_names_use_dedicated_prefix(self):
        self.assertIn('default     = "p01-self-healing"', TF_TEXT)
        self.assertNotIn("var.project_name", TF_TEXT)

    def test_no_existing_network_or_compute_resource_data_sources(self):
        data_types = set(re.findall(r'^data\s+"([^"]+)"', TF_TEXT, flags=re.MULTILINE))
        self.assertEqual(data_types, {
            "archive_file",
            "aws_ami",
            "aws_availability_zones",
            "aws_caller_identity",
        })

    def test_plan_requires_expected_account_match(self):
        self.assertIn("self.account_id == var.expected_account_id", TF_TEXT)
        self.assertIn("postcondition", TF_TEXT)
        self.assertNotIn('check "personal_account_guard"', TF_TEXT)
        self.assertIn("profile = var.aws_profile", TF_TEXT)

    def test_asg_instances_and_volumes_receive_identity_tags(self):
        web_text = (TF_DIR / "web-asg.tf").read_text(encoding="utf-8")
        self.assertIn('resource_type = "instance"', web_text)
        self.assertIn('resource_type = "volume"', web_text)
        self.assertGreaterEqual(web_text.count("merge(local.common_tags"), 3)
        self.assertIn('dynamic "tag"', web_text)


if __name__ == "__main__":
    unittest.main()
