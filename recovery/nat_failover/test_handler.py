import importlib.util
import unittest
from pathlib import Path


SPEC = importlib.util.spec_from_file_location("nat_handler", Path(__file__).with_name("handler.py"))
HANDLER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HANDLER)


MAPPINGS = {
    "nat-a-failed": {
        "route_table_id": "rtb-a",
        "standby_instance": "i-b",
        "standby_network_if": "eni-b",
    }
}


class FakeEC2:
    def __init__(self, healthy=True, current_eni="eni-a"):
        self.healthy = healthy
        self.current_eni = current_eni
        self.replacements = []

    def describe_instance_status(self, **_kwargs):
        state = "ok" if self.healthy else "impaired"
        return {
            "InstanceStatuses": [{
                "InstanceState": {"Name": "running"},
                "InstanceStatus": {"Status": state},
                "SystemStatus": {"Status": state},
            }]
        }

    def describe_route_tables(self, **_kwargs):
        return {"RouteTables": [{"Routes": [{
            "DestinationCidrBlock": "0.0.0.0/0",
            "NetworkInterfaceId": self.current_eni,
        }]}]}

    def replace_route(self, **kwargs):
        self.replacements.append(kwargs)


class NatFailoverTest(unittest.TestCase):
    def test_replaces_failed_route_with_healthy_standby(self):
        ec2 = FakeEC2()
        result = HANDLER.failover("nat-a-failed", MAPPINGS, ec2)
        self.assertEqual(result["reason"], "route_replaced")
        self.assertEqual(ec2.replacements[0]["NetworkInterfaceId"], "eni-b")

    def test_duplicate_event_is_idempotent(self):
        ec2 = FakeEC2(current_eni="eni-b")
        result = HANDLER.failover("nat-a-failed", MAPPINGS, ec2)
        self.assertEqual(result["reason"], "already_failed_over")
        self.assertEqual(ec2.replacements, [])

    def test_refuses_unhealthy_standby(self):
        ec2 = FakeEC2(healthy=False)
        result = HANDLER.failover("nat-a-failed", MAPPINGS, ec2)
        self.assertEqual(result, {
            "outcome": "failed",
            "reason": "standby_unhealthy",
            "duration_seconds": result["duration_seconds"],
        })
        self.assertEqual(ec2.replacements, [])

    def test_unknown_alarm_is_ignored(self):
        result = HANDLER.failover("other", MAPPINGS, FakeEC2())
        self.assertEqual(result, {"outcome": "ignored", "reason": "unknown_alarm"})


if __name__ == "__main__":
    unittest.main()
