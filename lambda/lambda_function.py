"""
Fonction Lambda pour piloter une instance EC2 (start / stop) via API Gateway.

Recoit un event API Gateway (v1 REST ou v2 HTTP), determine l'action a faire
(/start, /stop, /status) et appelle EC2 via boto3.
"""

import json
import os
import sys
import traceback


def _log(msg):
    """Force le flush pour que CloudWatch capte les logs."""
    print(msg, flush=True)
    sys.stdout.flush()


def _client():
    """Cree un client EC2 boto3 qui marche sur LocalStack ou AWS reel."""
    import boto3

    endpoint = os.getenv("AWS_ENDPOINT_URL")

    if not endpoint:
        localstack_host = os.getenv("LOCALSTACK_HOSTNAME")
        if localstack_host:
            edge_port = os.getenv("EDGE_PORT", "4566")
            endpoint = f"http://{localstack_host}:{edge_port}"

    _log(f"[ec2-client] endpoint={endpoint}")

    if endpoint:
        return boto3.client(
            "ec2",
            endpoint_url=endpoint,
            region_name=os.getenv("AWS_REGION", "us-east-1"),
            aws_access_key_id="test",
            aws_secret_access_key="test",
        )
    return boto3.client("ec2", region_name=os.getenv("AWS_REGION", "us-east-1"))


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=str),
    }


def _extract_action(event):
    """Extrait l'action /start /stop /status du payload, quel que soit le format."""
    # Format API Gateway v1 REST
    path = event.get("path")
    # Format API Gateway v2 HTTP
    if not path:
        path = event.get("rawPath")
    # Format requestContext (v2)
    if not path:
        rc = event.get("requestContext") or {}
        path = rc.get("http", {}).get("path") if isinstance(rc.get("http"), dict) else None
    # Format direct invocation
    if not path:
        path = event.get("action") or ""

    return (path or "").strip("/").lower()


def handler(event, context):
    _log("===== INVOCATION =====")
    _log(f"EVENT: {json.dumps(event, default=str)}")

    try:
        instance_id = os.getenv("INSTANCE_ID")
        if not instance_id:
            _log("[fatal] INSTANCE_ID non defini")
            return _response(500, {"error": "INSTANCE_ID non defini cote Lambda"})

        action = _extract_action(event)
        _log(f"[parse] action extraite = '{action}'")

        ec2 = _client()

        if action == "start":
            resp = ec2.start_instances(InstanceIds=[instance_id])
            return _response(200, {
                "action": "start",
                "instance_id": instance_id,
                "previous_state": resp["StartingInstances"][0]["PreviousState"]["Name"],
                "current_state": resp["StartingInstances"][0]["CurrentState"]["Name"],
            })

        if action == "stop":
            resp = ec2.stop_instances(InstanceIds=[instance_id])
            return _response(200, {
                "action": "stop",
                "instance_id": instance_id,
                "previous_state": resp["StoppingInstances"][0]["PreviousState"]["Name"],
                "current_state": resp["StoppingInstances"][0]["CurrentState"]["Name"],
            })

        if action == "status":
            resp = ec2.describe_instances(InstanceIds=[instance_id])
            inst = resp["Reservations"][0]["Instances"][0]
            return _response(200, {
                "action": "status",
                "instance_id": instance_id,
                "state": inst["State"]["Name"],
                "instance_type": inst.get("InstanceType"),
                "launch_time": inst.get("LaunchTime"),
            })

        _log(f"[warn] action inconnue : '{action}'")
        return _response(400, {
            "error": "Action inconnue",
            "received_action": action,
            "received_event_keys": list(event.keys()),
            "actions_supportees": ["start", "stop", "status"],
        })

    except Exception as e:
        _log(f"[fatal] Exception : {type(e).__name__}: {e}")
        _log(traceback.format_exc())
        return _response(500, {
            "error": "Echec interne Lambda",
            "type": type(e).__name__,
            "detail": str(e),
        })
