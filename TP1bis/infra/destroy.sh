#!/usr/bin/env bash
# Supprime toutes les ressources du TP1bis dans LocalEmu (les erreurs "n'existe pas" sont ignorées).
# Usage (dans Ubuntu, depuis TP1bis/) : bash infra/destroy.sh
set -uo pipefail

source "$(dirname "$0")/config.sh"
check_localemu

echo "Suppression de l'API Gateway..."
for id in $(awsl apigateway get-rest-apis --query "items[?name=='$API_NAME'].id" --output text); do
    awsl apigateway delete-rest-api --rest-api-id "$id"
done

echo "Suppression du déclencheur SQS..."
list_mappings() {
    awsl lambda list-event-source-mappings --function-name "$LAMBDA_WORKER" \
        --query "EventSourceMappings[].UUID" --output text 2>/dev/null
}
for uuid in $(list_mappings); do
    awsl lambda delete-event-source-mapping --uuid "$uuid" > /dev/null
done
# La suppression est asynchrone : on attend qu'elle soit effective (30 s max)
for _ in $(seq 1 30); do
    [ -z "$(list_mappings)" ] && break
    sleep 1
done

echo "Suppression des Lambdas..."
awsl lambda delete-function --function-name "$LAMBDA_HTTP" 2>/dev/null
awsl lambda delete-function --function-name "$LAMBDA_WORKER" 2>/dev/null

echo "Suppression du rôle IAM..."
awsl iam delete-role-policy --role-name "$ROLE_NAME" --policy-name tp1bis-permissions 2>/dev/null
awsl iam delete-role --role-name "$ROLE_NAME" 2>/dev/null

echo "Suppression de la table DynamoDB..."
awsl dynamodb delete-table --table-name "$TABLE_NAME" > /dev/null 2>&1

echo "Suppression des files SQS..."
for q in "$QUEUE_NAME" "$DLQ_NAME"; do
    url=$(awsl sqs get-queue-url --queue-name "$q" --query QueueUrl --output text 2>/dev/null) \
        && awsl sqs delete-queue --queue-url "$url"
done

echo "Ressources supprimées."
