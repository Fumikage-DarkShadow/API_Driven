"""
Fonction Lambda pour piloter une instance EC2 (start / stop / status) via API Gateway.

L'instance EC2 cible est identifiee par un TAG (ATELIER_TAG), pas par un ID fixe.
Cela permet de gerer le cas ou LocalStack auto-termine l'instance : la Lambda
peut alors en recreer une fraiche en gardant la meme identite logique.

Variables d'environnement attendues :
  - ATELIER_TAG        : tag Name de l'instance a piloter (ex : "atelier-ec2")
  - AMI_ID             : AMI a utiliser pour creer une nouvelle instance
  - INSTANCE_TYPE      : type d'instance (ex : "t2.micro")
  - LOCALSTACK_HOSTNAME (auto-injecte par LocalStack)
"""

import json
import os
import sys
import traceback


def _log(msg):
    print(msg, flush=True)
    sys.stdout.flush()


def _client():
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
    path = (
        event.get("path")
        or event.get("rawPath")
        or (event.get("requestContext", {}).get("http", {}) or {}).get("path")
        or event.get("action")
        or ""
    )
    return path.strip("/").lower()


def _find_instance(ec2, tag_value):
    """Trouve l'instance la plus recente portant le tag Name=<tag_value>.

    Ignore les instances terminees ou en cours de terminaison.
    Retourne (instance_dict, state_name) ou (None, None).
    """
    resp = ec2.describe_instances(Filters=[
        {"Name": "tag:Name", "Values": [tag_value]},
    ])
    candidates = []
    for reservation in resp.get("Reservations", []):
        for inst in reservation.get("Instances", []):
            state = inst.get("State", {}).get("Name", "")
            if state in ("terminated", "shutting-down"):
                continue
            candidates.append(inst)

    if not candidates:
        return None, None

    # Plus recente en premier
    candidates.sort(key=lambda i: i.get("LaunchTime") or "", reverse=True)
    inst = candidates[0]
    return inst, inst["State"]["Name"]


def _create_instance(ec2, tag_value, ami_id, instance_type):
    """Cree une instance EC2 avec le tag Name=<tag_value>."""
    _log(f"[create] AMI={ami_id} type={instance_type} tag={tag_value}")
    resp = ec2.run_instances(
        ImageId=ami_id,
        InstanceType=instance_type,
        MinCount=1,
        MaxCount=1,
        TagSpecifications=[{
            "ResourceType": "instance",
            "Tags": [{"Key": "Name", "Value": tag_value}],
        }],
    )
    return resp["Instances"][0]


def handler(event, context):
    _log("===== INVOCATION =====")
    _log(f"EVENT: {json.dumps(event, default=str)}")

    tag_value = os.getenv("ATELIER_TAG", "atelier-ec2")
    ami_id = os.getenv("AMI_ID")
    instance_type = os.getenv("INSTANCE_TYPE", "t2.micro")

    if not ami_id:
        return _response(500, {"error": "AMI_ID non defini cote Lambda"})

    try:
        action = _extract_action(event)
        _log(f"[parse] action='{action}', tag='{tag_value}'")

        ec2 = _client()
        inst, state = _find_instance(ec2, tag_value)

        if action == "status":
            if inst is None:
                return _response(200, {
                    "action": "status",
                    "state": "absent",
                    "message": "Aucune instance active. Lance /start pour en creer une.",
                })
            return _response(200, {
                "action": "status",
                "instance_id": inst["InstanceId"],
                "state": state,
                "instance_type": inst.get("InstanceType"),
                "launch_time": inst.get("LaunchTime"),
            })

        if action == "start":
            # Cas 1 : aucune instance active -> on en cree une
            if inst is None:
                new_inst = _create_instance(ec2, tag_value, ami_id, instance_type)
                return _response(200, {
                    "action": "start",
                    "instance_id": new_inst["InstanceId"],
                    "previous_state": "absent",
                    "current_state": new_inst["State"]["Name"],
                    "message": "Instance creee",
                })

            # Cas 2 : instance deja en cours -> rien a faire
            if state in ("running", "pending"):
                return _response(200, {
                    "action": "start",
                    "instance_id": inst["InstanceId"],
                    "previous_state": state,
                    "current_state": state,
                    "message": "Instance deja active",
                })

            # Cas 3 : instance arretee -> on la redemarre
            resp = ec2.start_instances(InstanceIds=[inst["InstanceId"]])
            return _response(200, {
                "action": "start",
                "instance_id": inst["InstanceId"],
                "previous_state": resp["StartingInstances"][0]["PreviousState"]["Name"],
                "current_state": resp["StartingInstances"][0]["CurrentState"]["Name"],
            })

        if action == "stop":
            if inst is None:
                return _response(404, {
                    "action": "stop",
                    "error": "Aucune instance active a arreter",
                })

            if state in ("stopped", "stopping"):
                return _response(200, {
                    "action": "stop",
                    "instance_id": inst["InstanceId"],
                    "previous_state": state,
                    "current_state": state,
                    "message": "Instance deja arretee",
                })

            resp = ec2.stop_instances(InstanceIds=[inst["InstanceId"]])
            return _response(200, {
                "action": "stop",
                "instance_id": inst["InstanceId"],
                "previous_state": resp["StoppingInstances"][0]["PreviousState"]["Name"],
                "current_state": resp["StoppingInstances"][0]["CurrentState"]["Name"],
            })

        return _response(400, {
            "error": "Action inconnue",
            "received": action,
            "actions_supportees": ["start", "stop", "status"],
        })

    except Exception as e:
        _log(f"[fatal] {type(e).__name__}: {e}")
        _log(traceback.format_exc())
        return _response(500, {
            "error": "Echec interne Lambda",
            "type": type(e).__name__,
            "detail": str(e),
        })
