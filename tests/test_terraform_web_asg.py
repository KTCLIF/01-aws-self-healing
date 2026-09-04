import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WEB_TF = (ROOT / "infra" / "terraform" / "web-asg.tf").read_text(encoding="utf-8")
VARIABLES_TF = (ROOT / "infra" / "terraform" / "variables.tf").read_text(encoding="utf-8")


class TerraformWebAsgContractTest(unittest.TestCase):
    def test_web_stack_is_disabled_by_default(self):
        block = VARIABLES_TF.split('variable "enable_web_asg"', 1)[1].split("}", 1)[0]
        self.assertIn("default     = false", block)
        self.assertIn("default     = []", VARIABLES_TF)

    def test_two_instance_asg_uses_both_app_subnets_and_elb_health(self):
        self.assertIn("min_size            = 2", WEB_TF)
        self.assertIn("desired_capacity    = 2", WEB_TF)
        self.assertIn("vpc_zone_identifier = aws_subnet.app[*].id", WEB_TF)
        self.assertIn('health_check_type         = "ELB"', WEB_TF)

    def test_instances_accept_application_traffic_only_from_alb(self):
        self.assertIn("referenced_security_group_id = aws_security_group.web_alb[0].id", WEB_TF)
        self.assertNotIn("key_name", WEB_TF)

    def test_target_group_has_explicit_fast_health_contract(self):
        self.assertIn('path                = "/health"', WEB_TF)
        self.assertIn("interval            = 5", WEB_TF)
        self.assertIn("unhealthy_threshold = 2", WEB_TF)

    def test_web_ami_is_free_tier_eligible_al2023_x86(self):
        self.assertIn('values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]', WEB_TF)
        self.assertIn('name   = "free-tier-eligible"', WEB_TF)


if __name__ == "__main__":
    unittest.main()
