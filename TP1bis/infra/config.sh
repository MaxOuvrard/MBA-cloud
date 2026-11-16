#!/usr/bin/env bash
# Configuration commune aux scripts du TP1bis.
# Tout pointe vers LocalEmu (http://localhost:4566) : aucune ressource AWS réelle n'est utilisée.

# --- Cible locale ---
export LOCALEMU_ENDPOINT="${LOCALEMU_ENDPOINT:-http://localhost:4566}"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_REGION="$AWS_DEFAULT_REGION"
ACCOUNT_ID="000000000000"   # compte simulé par LocalEmu

# Identifiants d'exemple publiés par AWS (acceptés par LocalEmu, ne donnent accès à rien chez AWS)
export AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
export AWS_SECRET_ACCESS_KEY="wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

# --- Noms des ressources ---
QUEUE_NAME="requests-queue"          # file SQS principale
DLQ_NAME="requests-queue-dlq"        # file des messages en échec (dead-letter queue)
TABLE_NAME="requests"                # table DynamoDB
ROLE_NAME="tp1bis-lambda-role"       # rôle IAM des Lambdas
LAMBDA_HTTP="http-to-sqs"            # Lambda A : API Gateway -> SQS
LAMBDA_WORKER="sqs-to-dynamodb"      # Lambda B : SQS -> DynamoDB
API_NAME="tp1bis-api"                # API Gateway REST
API_STAGE="local"
LAMBDA_RUNTIME="python3.12"

# --- Chemins ---
TP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$TP_DIR/build"
