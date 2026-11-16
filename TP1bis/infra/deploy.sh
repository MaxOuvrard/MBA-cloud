#!/usr/bin/env bash
# Crée toutes les ressources du TP1bis dans LocalEmu.
# Le script repart de zéro à chaque lancement (il supprime d'abord les anciennes ressources).
# Usage (dans Ubuntu, depuis TP1bis/) : bash infra/deploy.sh
set -euo pipefail

source "$(dirname "$0")/config.sh"

echo "=== 0. Vérification de la cible ==="
check_localemu

echo "=== 1. Nettoyage des anciennes ressources ==="
bash "$(dirname "$0")/destroy.sh" > /dev/null 2>&1 || true

echo "=== 2. SQS : file principale + dead-letter queue ==="
DLQ_URL=$(awsl sqs create-queue --queue-name "$DLQ_NAME" --query QueueUrl --output text)
DLQ_ARN=$(awsl sqs get-queue-attributes --queue-url "$DLQ_URL" \
    --attribute-names QueueArn --query Attributes.QueueArn --output text)

# Après 3 échecs de traitement, le message part dans la DLQ.
# VisibilityTimeout (30 s) > timeout de la Lambda B (10 s), comme recommandé par AWS.
cat > /tmp/tp1bis-queue-attrs.json <<EOF
{
  "VisibilityTimeout": "30",
  "RedrivePolicy": "{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"3\"}"
}
EOF
QUEUE_URL=$(awsl sqs create-queue --queue-name "$QUEUE_NAME" \
    --attributes file:///tmp/tp1bis-queue-attrs.json --query QueueUrl --output text)
QUEUE_ARN=$(awsl sqs get-queue-attributes --queue-url "$QUEUE_URL" \
    --attribute-names QueueArn --query Attributes.QueueArn --output text)
echo "File : $QUEUE_URL"
echo "DLQ  : $DLQ_URL"

echo "=== 3. DynamoDB : table $TABLE_NAME ==="
awsl dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=id,AttributeType=S \
    --key-schema AttributeName=id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST > /dev/null
awsl dynamodb wait table-exists --table-name "$TABLE_NAME"
echo "Table : $TABLE_NAME"

echo "=== 4. IAM : rôle des Lambdas ==="
cat > /tmp/tp1bis-trust.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF
cat > /tmp/tp1bis-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["sqs:SendMessage", "sqs:GetQueueUrl"], "Resource": "$QUEUE_ARN" },
    { "Effect": "Allow", "Action": ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"], "Resource": "$QUEUE_ARN" },
    { "Effect": "Allow", "Action": ["dynamodb:PutItem"], "Resource": "arn:aws:dynamodb:$AWS_DEFAULT_REGION:$ACCOUNT_ID:table/$TABLE_NAME" },
    { "Effect": "Allow", "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], "Resource": "*" }
  ]
}
EOF
ROLE_ARN=$(awsl iam create-role --role-name "$ROLE_NAME" \
    --assume-role-policy-document file:///tmp/tp1bis-trust.json --query Role.Arn --output text)
awsl iam put-role-policy --role-name "$ROLE_NAME" \
    --policy-name tp1bis-permissions --policy-document file:///tmp/tp1bis-policy.json
echo "Rôle : $ROLE_ARN"

echo "=== 5. Lambdas : packaging et création ==="
mkdir -p "$BUILD_DIR"
package() {  # $1 = dossier de la lambda -> zip dans build/
    local zip="$BUILD_DIR/$1.zip"
    rm -f "$zip"
    (cd "$TP_DIR/lambdas/$1" && python3 -m zipfile -c "$zip" handler.py)
    echo "$zip"
}

ZIP_HTTP=$(package http_to_sqs)
awsl lambda create-function \
    --function-name "$LAMBDA_HTTP" \
    --runtime "$LAMBDA_RUNTIME" \
    --handler handler.lambda_handler \
    --role "$ROLE_ARN" \
    --timeout 10 \
    --zip-file "fileb://$ZIP_HTTP" \
    --environment "Variables={QUEUE_NAME=$QUEUE_NAME}" > /dev/null

ZIP_WORKER=$(package sqs_to_dynamodb)
awsl lambda create-function \
    --function-name "$LAMBDA_WORKER" \
    --runtime "$LAMBDA_RUNTIME" \
    --handler handler.lambda_handler \
    --role "$ROLE_ARN" \
    --timeout 10 \
    --zip-file "fileb://$ZIP_WORKER" \
    --environment "Variables={TABLE_NAME=$TABLE_NAME}" > /dev/null

awsl lambda wait function-active-v2 --function-name "$LAMBDA_HTTP"
awsl lambda wait function-active-v2 --function-name "$LAMBDA_WORKER"
LAMBDA_HTTP_ARN=$(awsl lambda get-function --function-name "$LAMBDA_HTTP" --query Configuration.FunctionArn --output text)
echo "Lambda A : $LAMBDA_HTTP_ARN"
echo "Lambda B : $(awsl lambda get-function --function-name "$LAMBDA_WORKER" --query Configuration.FunctionArn --output text)"

echo "=== 6. Déclencheur SQS -> Lambda B (event source mapping) ==="
# ReportBatchItemFailures : seuls les messages en erreur sont renvoyés dans la file.
awsl lambda create-event-source-mapping \
    --function-name "$LAMBDA_WORKER" \
    --event-source-arn "$QUEUE_ARN" \
    --batch-size 5 \
    --function-response-types ReportBatchItemFailures \
    --query UUID --output text

echo "=== 7. API Gateway : POST /requests -> Lambda A ==="
API_ID=$(awsl apigateway create-rest-api --name "$API_NAME" --query id --output text)
ROOT_ID=$(awsl apigateway get-resources --rest-api-id "$API_ID" --query "items[?path=='/'].id | [0]" --output text)
RES_ID=$(awsl apigateway create-resource --rest-api-id "$API_ID" \
    --parent-id "$ROOT_ID" --path-part requests --query id --output text)
awsl apigateway put-method --rest-api-id "$API_ID" --resource-id "$RES_ID" \
    --http-method POST --authorization-type NONE > /dev/null
awsl apigateway put-integration --rest-api-id "$API_ID" --resource-id "$RES_ID" \
    --http-method POST --type AWS_PROXY --integration-http-method POST \
    --uri "arn:aws:apigateway:$AWS_DEFAULT_REGION:lambda:path/2015-03-31/functions/$LAMBDA_HTTP_ARN/invocations" > /dev/null
awsl lambda add-permission --function-name "$LAMBDA_HTTP" \
    --statement-id apigateway-invoke --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:$AWS_DEFAULT_REGION:$ACCOUNT_ID:$API_ID/*/POST/requests" > /dev/null
awsl apigateway create-deployment --rest-api-id "$API_ID" --stage-name "$API_STAGE" > /dev/null

echo
echo "=== Déploiement terminé ==="
echo "URL de l'API : $(api_url)"
