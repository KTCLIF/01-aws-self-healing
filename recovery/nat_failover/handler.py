"""Degraded-mode NAT route failover for the instance_ha learning lab."""

import json
import os
import time


DESTINATION = "0.0.0.0/0"


def trigger_from_event(event):
    detail = event.get("detail", {})
    return detail.get("alarmName") or detail.get("instance-id", "")


def _standby_is_healthy(ec2, instance_id):
    response = ec2.describe_instance_status(
        InstanceIds=[instance_id], IncludeAllInstances=True
    )
    statuses = response.get("InstanceStatuses", [])
    if len(statuses) != 1:
        return False
    status = statuses[0]
    return (
        status.get("InstanceState", {}).get("Name") == "running"
        and status.get("InstanceStatus", {}).get("Status") == "ok"
        and status.get("SystemStatus", {}).get("Status") == "ok"
    )


def failover(alarm_name, mappings, ec2, clock=time.time):
    started = clock()
    mapping = mappings.get(alarm_name)
    if not mapping:
        return {"outcome": "ignored", "reason": "unknown_alarm"}

    if not _standby_is_healthy(ec2, mapping["standby_instance"]):
        return {
            "outcome": "failed",
            "reason": "standby_unhealthy",
            "duration_seconds": round(clock() - started, 6),
        }

    response = ec2.describe_route_tables(RouteTableIds=[mapping["route_table_id"]])
    routes = response["RouteTables"][0].get("Routes", [])
    current = next(
        (route for route in routes if route.get("DestinationCidrBlock") == DESTINATION),
        {},
    )
    if current.get("NetworkInterfaceId") == mapping["standby_network_if"]:
        return {
            "outcome": "success",
            "reason": "already_failed_over",
            "duration_seconds": round(clock() - started, 6),
        }

    ec2.replace_route(
        RouteTableId=mapping["route_table_id"],
        DestinationCidrBlock=DESTINATION,
        NetworkInterfaceId=mapping["standby_network_if"],
    )
    return {
        "outcome": "success",
        "reason": "route_replaced",
        "route_table_id": mapping["route_table_id"],
        "standby_network_if": mapping["standby_network_if"],
        "duration_seconds": round(clock() - started, 6),
    }


def lambda_handler(event, _context):
    import boto3

    trigger = trigger_from_event(event)
    mappings = json.loads(os.environ["FAILOVER_MAP"])
    result = failover(trigger, mappings, boto3.client("ec2"))
    print(json.dumps({"trigger": trigger, **result}, sort_keys=True))
    return result
