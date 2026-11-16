"""Lambda B : SQS -> DynamoDB.

Déclenchée automatiquement par l'event source mapping SQS (jamais appelée directement).
Pour chaque message du lot : lecture, vérification, écriture dans la table DynamoDB.

- Idempotence : l'écriture est conditionnelle (attribute_not_exists(id)), donc un message
  livré deux fois ne crée pas de doublon et n'écrase pas l'item existant.
- Erreurs : un message en échec est journalisé puis renvoyé à SQS via batchItemFailures
  (seul ce message est retenté ; après 3 échecs il part dans la DLQ).
"""

import json
import logging
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

TABLE_NAME = os.environ["TABLE_NAME"]

# Dans LocalEmu, boto3 lit automatiquement AWS_ENDPOINT_URL injecté dans le conteneur.
table = boto3.resource("dynamodb").Table(TABLE_NAME)


class InvalidMessage(Exception):
    """Message illisible ou incomplet."""


def parse_message(body):
    """Lit le message SQS et retourne l'item à écrire dans DynamoDB."""
    try:
        # DynamoDB refuse les float Python : les décimaux sont lus en Decimal
        message = json.loads(body, parse_float=Decimal)
    except json.JSONDecodeError as exc:
        raise InvalidMessage(f"JSON illisible ({exc})")

    if not isinstance(message, dict):
        raise InvalidMessage("le message doit être un objet JSON")

    data = message.get("data")
    msg_id = message.get("id")
    if not isinstance(msg_id, str) or not msg_id:
        raise InvalidMessage("champ 'id' manquant")
    if not isinstance(data, dict):
        raise InvalidMessage("champ 'data' manquant")

    client = data.get("client")
    montant = data.get("montant")
    if not isinstance(client, str) or not client:
        raise InvalidMessage("champ 'data.client' manquant")
    if isinstance(montant, bool) or not isinstance(montant, (int, Decimal)):
        raise InvalidMessage("champ 'data.montant' non numérique")

    return {
        "id": msg_id,
        "client": client,
        "montant": montant,
        "receivedAt": message.get("receivedAt", ""),
        "processedAt": datetime.now(timezone.utc).isoformat(),
    }


def process_record(record):
    """Traite un message. Lève une exception si le message doit être retenté."""
    item = parse_message(record["body"])
    try:
        table.put_item(Item=item, ConditionExpression="attribute_not_exists(id)")
        logger.info("Item %s écrit dans %s (client=%s, montant=%s)",
                    item["id"], TABLE_NAME, item["client"], item["montant"])
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            # Message déjà traité (livraison en double) : rien à faire, ce n'est pas une erreur
            logger.warning("Item %s déjà présent : message en double ignoré", item["id"])
            return
        raise


def lambda_handler(event, context):
    records = event.get("Records", [])
    logger.info("Lot reçu de SQS : %d message(s)", len(records))

    failures = []
    for record in records:
        message_id = record.get("messageId")
        try:
            process_record(record)
        except InvalidMessage as exc:
            logger.error("Message SQS %s invalide : %s | body=%s",
                         message_id, exc, record.get("body"))
            failures.append({"itemIdentifier": message_id})
        except Exception:
            logger.exception("Échec du traitement du message SQS %s", message_id)
            failures.append({"itemIdentifier": message_id})

    if failures:
        logger.warning("%d message(s) en échec renvoyé(s) dans la file", len(failures))

    # Réponse partielle : seuls les messages listés sont renvoyés dans la file
    return {"batchItemFailures": failures}
