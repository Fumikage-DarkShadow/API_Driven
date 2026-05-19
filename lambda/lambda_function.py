"""
Fonction Lambda pour piloter une instance EC2 (start / stop) via API Gateway.

Cette Lambda est invoquee par API Gateway. Elle recoit un event au format
"proxy integration" qui contient le chemin (ex: /start, /stop, /status).

L'instance EC2 cible est identifiee par la variable d'environnement
INSTANCE_ID (definie au moment du deploiement de la Lambda).

Boto3 est utilise pour parler a EC2. En production AWS, boto3 pointe sur
l'API publique d'AWS. En local (LocalStack), on lui dit de pointer sur
http://localhost:4566 via la variable d'environnement AWS_ENDPOINT_URL ou
en lui passant endpoint_url=... explicitement.
"""

import json
import os
import boto3


def _client():
    """Cree un client EC2 boto3 qui marche aussi bien sur LocalStack qu'AWS reel.

    Quand la Lambda tourne dans LocalStack, elle est dans un container Docker
    isole. Pour parler a LocalStack depuis ce container, on utilise la variable
    d'environnement LOCALSTACK_HOSTNAME auto-injectee par LocalStack, qui pointe
    vers le service LocalStack sur le reseau Docker.
    """
    endpoint = os.getenv("AWS_ENDPOINT_URL")

    if not endpoint:
        localstack_host = os.getenv("LOCALSTACK_HOSTNAME")
        if localstack_host:
            edge_port = os.getenv("EDGE_PORT", "4566")
            endpoint = f"http://{localstack_host}:{edge_port}"

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
    """Construit une reponse HTTP au format attendu par API Gateway proxy."""
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=str),
    }


def handler(event, context):
    instance_id = os.getenv("INSTANCE_ID")
    if not instance_id:
        return _response(500, {"error": "INSTANCE_ID non defini cote Lambda"})

    # Recupere le chemin appele (/start, /stop, /status)
    # API Gateway peut envoyer ca dans path ou dans rawPath selon la version.
    path = event.get("path") or event.get("rawPath") or ""
    action = path.strip("/").lower()

    ec2 = _client()

    try:
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

        return _response(400, {
            "error": "Action inconnue",
            "received_path": path,
            "actions_supportees": ["/start", "/stop", "/status"],
        })

    except Exception as e:
        return _response(500, {
            "error": "Echec de l'action EC2",
            "action": action,
            "detail": str(e),
        })
