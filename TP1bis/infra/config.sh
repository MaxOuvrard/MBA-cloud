#!/usr/bin/env bash
# Configuration commune aux scripts du TP1bis.
# Tout pointe vers LocalEmu (http://localhost:4566) : aucune ressource AWS réelle n'est utilisée.

# --- AWS CLI (installé avec LocalEmu dans ~/localemu-env) ---
if ! command -v aws > /dev/null 2>&1 && [ -f "$HOME/localemu-env/bin/activate" ]; then
    source "$HOME/localemu-env/bin/activate"
fi

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

# --- AWS CLI forcé sur l'émulateur ---
# Chaque commande passe explicitement --endpoint-url vers LocalEmu.
awsl() {
    aws --endpoint-url="$LOCALEMU_ENDPOINT" --output json "$@"
}

# Garde-fou : refuse de continuer si on ne parle pas à LocalEmu.
check_localemu() {
    case "$LOCALEMU_ENDPOINT" in
        http://localhost:*|http://127.0.0.1:*) ;;
        *) echo "ERREUR : endpoint non local ($LOCALEMU_ENDPOINT), arrêt." >&2; exit 1 ;;
    esac
    local account
    account=$(awsl sts get-caller-identity --query Account --output text 2>/dev/null) || {
        echo "ERREUR : LocalEmu ne répond pas sur $LOCALEMU_ENDPOINT (lancer 'localemu start')." >&2; exit 1; }
    if [ "$account" != "$ACCOUNT_ID" ]; then
        echo "ERREUR : compte $account inattendu (attendu : $ACCOUNT_ID simulé), arrêt." >&2; exit 1
    fi
    echo "OK : cible = LocalEmu ($LOCALEMU_ENDPOINT), compte simulé $account"
}

# URL locale d'appel de l'API Gateway
api_url() {
    local api_id
    api_id=$(awsl apigateway get-rest-apis --query "items[?name=='$API_NAME'].id | [0]" --output text)
    echo "$LOCALEMU_ENDPOINT/restapis/$api_id/$API_STAGE/_user_request_/requests"
}
