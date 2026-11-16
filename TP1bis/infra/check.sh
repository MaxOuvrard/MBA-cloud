#!/usr/bin/env bash
# Affiche les ressources du TP1bis présentes dans LocalEmu (preuve qu'elles existent et sont locales).
# Usage (dans Ubuntu, depuis TP1bis/) : bash infra/check.sh
set -uo pipefail

source "$(dirname "$0")/config.sh"
check_localemu

echo; echo "--- Files SQS ---"
awsl sqs list-queues --query QueueUrls --output table

echo; echo "--- Tables DynamoDB ---"
awsl dynamodb list-tables --query TableNames --output table

echo; echo "--- Lambdas ---"
awsl lambda list-functions --query "Functions[].[FunctionName,Runtime,FunctionArn]" --output table

echo; echo "--- Déclencheurs (event source mappings) ---"
awsl lambda list-event-source-mappings --query "EventSourceMappings[].[FunctionArn,EventSourceArn,State]" --output table

echo; echo "--- API Gateway ---"
awsl apigateway get-rest-apis --query "items[].[name,id]" --output table
echo "URL : $(api_url)"
