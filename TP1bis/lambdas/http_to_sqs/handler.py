"""Lambda A : API Gateway -> SQS.

Reçoit une requête HTTP (intégration proxy API Gateway), valide les données
et publie un message dans la file SQS. Ne fait rien d'autre :
- pas d'écriture dans DynamoDB,
- pas d'appel à la Lambda B,
- aucun état conservé entre deux invocations (stateless).
"""

import json
import logging
import os
import uuid
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

QUEUE_NAME = os.environ["QUEUE_NAME"]

# Le client est créé une seule fois par conteneur (réutilisé entre invocations).
# Dans LocalEmu, boto3 lit automatiquement AWS_ENDPOINT_URL injecté dans le conteneur.
sqs = boto3.client("sqs")


def response(status, body):
    """Construit la réponse au format attendu par API Gateway (proxy)."""
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, ensure_ascii=False),
    }


def validate(data):
    """Retourne la liste des erreurs de validation (vide si les données sont correctes)."""
    if not isinstance(data, dict):
        return ["le corps doit être un objet JSON"]

    errors = []
    client = data.get("client")
    if not isinstance(client, str) or not client.strip():
        errors.append("'client' doit être un texte non vide")

    montant = data.get("montant")
    # bool est un sous-type de int en Python : on l'exclut explicitement
    if isinstance(montant, bool) or not isinstance(montant, (int, float)) or montant <= 0:
        errors.append("'montant' doit être un nombre strictement positif")

    return errors


def lambda_handler(event, context):
    # 1. Lire le corps de la requête
    try:
        data = json.loads(event.get("body") or "")
    except (json.JSONDecodeError, TypeError):
        logger.warning("Requête refusée : corps JSON invalide")
        return response(400, {"error": "corps JSON invalide"})

    # 2. Valider les données
    errors = validate(data)
    if errors:
        logger.warning("Requête refusée : %s", errors)
        return response(400, {"error": "données invalides", "details": errors})

    # 3. Construire le message
    message = {
        "id": str(uuid.uuid4()),
        "receivedAt": datetime.now(timezone.utc).isoformat(),
        "data": {"client": data["client"].strip(), "montant": data["montant"]},
    }

    # 4. Publier dans SQS
    try:
        queue_url = sqs.get_queue_url(QueueName=QUEUE_NAME)["QueueUrl"]
        result = sqs.send_message(QueueUrl=queue_url, MessageBody=json.dumps(message))
    except Exception:
        logger.exception("Échec de l'envoi du message %s dans SQS", message["id"])
        return response(500, {"error": "impossible de publier le message"})

    logger.info("Message %s publié dans %s (SQS MessageId=%s)",
                message["id"], QUEUE_NAME, result["MessageId"])

    # 5. 202 Accepted : la demande est acceptée, mais pas encore traitée
    return response(202, {"status": "accepted", "id": message["id"]})
