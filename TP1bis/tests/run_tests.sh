#!/usr/bin/env bash
# Scénarios de test du parcours HTTP -> Lambda A -> SQS -> Lambda B -> DynamoDB.
# Prérequis : LocalEmu démarré (bash infra/start-localemu.sh) et ressources créées (bash infra/deploy.sh).
# Usage (dans Ubuntu, depuis TP1bis/) : bash tests/run_tests.sh
#
# Aucune intervention manuelle : le script envoie les requêtes HTTP puis observe DynamoDB.
# Les sorties sont enregistrées dans preuves/ (preuves d'exécution).
set -uo pipefail

source "$(dirname "$0")/../infra/config.sh"
PREUVES="$TP_DIR/preuves"
mkdir -p "$PREUVES"
exec > >(tee "$PREUVES/run_tests.txt") 2>&1

PASS=0
FAIL=0
ok()  { echo "  [OK]    $1"; PASS=$((PASS + 1)); }
ko()  { echo "  [ECHEC] $1"; FAIL=$((FAIL + 1)); }

URL=""
post() {  # $1 = corps JSON -> affiche "code|réponse"
    curl -s -w "|%{http_code}" -X POST "$URL" -H "Content-Type: application/json" -d "$1"
}
item_client() {  # $1 = id -> client de l'item DynamoDB, ou "None" s'il n'existe pas
    awsl dynamodb get-item --table-name "$TABLE_NAME" --key "{\"id\":{\"S\":\"$1\"}}" \
        --query Item.client.S --output text
}
wait_item() {  # $1 = id -> attend que l'item apparaisse (60 s max), affiche le délai
    local start=$SECONDS
    while [ $((SECONDS - start)) -lt 60 ]; do
        [ "$(item_client "$1")" != "None" ] && { echo $((SECONDS - start)); return 0; }
        sleep 1
    done
    return 1
}
count_items() {
    awsl dynamodb scan --table-name "$TABLE_NAME" --select COUNT --query Count --output text
}

echo "Exécution des tests : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
check_localemu
URL=$(api_url)
echo "API : $URL"
echo "Items dans la table avant les tests : $(count_items)"

# ---------------------------------------------------------------------------
echo
echo "=== Test 1 : appel valide + réponse HTTP avant la fin du traitement asynchrone ==="
T0=$(date +%s.%N)
R=$(post '{"client":"Alice","montant":42}')
T1=$(date +%s.%N)
CODE=${R##*|}; BODY=${R%|*}
ID=$(echo "$BODY" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
echo "  Réponse ($(python3 -c "print(f'{($T1-$T0)*1000:.0f} ms')")) : HTTP $CODE $BODY"
[ "$CODE" = "202" ] && [ -n "$ID" ] && ok "HTTP 202 avec un id" || ko "HTTP 202 attendu"

STATE=$(item_client "$ID")
echo "  Item $ID dans DynamoDB juste après la réponse : $([ "$STATE" = "None" ] && echo "absent" || echo "déjà présent")"
[ "$STATE" = "None" ] && ok "la réponse HTTP arrive avant l'écriture en base (traitement asynchrone)" \
                      || echo "  [INFO]  le traitement a été plus rapide que la vérification"
if D=$(wait_item "$ID"); then
    ok "item écrit dans DynamoDB par la Lambda B ${D} s après la réponse HTTP"
else
    ko "item $ID absent de DynamoDB après 60 s"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Test 2 : plusieurs appels successifs avec des données distinctes ==="
declare -A ATTENDU
for p in '{"client":"Bob","montant":19.99}' '{"client":"Chloé","montant":7}' \
         '{"client":"David","montant":1500}' '{"client":"Emma","montant":0.5}'; do
    R=$(post "$p"); CODE=${R##*|}; BODY=${R%|*}
    ID=$(echo "$BODY" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
    CLIENT=$(echo "$p" | python3 -c "import json,sys; print(json.load(sys.stdin)['client'])")
    echo "  $p -> HTTP $CODE id=$ID"
    [ "$CODE" = "202" ] && ATTENDU[$ID]=$CLIENT || ko "HTTP 202 attendu pour $p"
done
for ID in "${!ATTENDU[@]}"; do
    if wait_item "$ID" > /dev/null && [ "$(item_client "$ID")" = "${ATTENDU[$ID]}" ]; then
        ok "item ${ATTENDU[$ID]} ($ID) présent avec les bonnes données"
    else
        ko "item ${ATTENDU[$ID]} ($ID) absent ou incorrect"
    fi
done

# ---------------------------------------------------------------------------
echo
echo "=== Test 3 : appels avec des données invalides ==="
AVANT=$(count_items)
while IFS= read -r p; do
    R=$(post "$p"); CODE=${R##*|}; BODY=${R%|*}
    echo "  $p -> HTTP $CODE $BODY"
    [ "$CODE" = "400" ] && ok "requête invalide refusée (400)" || ko "HTTP 400 attendu"
done <<'EOF'
{"client":"Bob","montant":"abc"}
{"montant":10}
{"client":"","montant":10}
{"client":"Zoé","montant":-5}
{"client":"Zoé","montant":true}
{pas du json
EOF
sleep 10
APRES=$(count_items)
echo "  Items avant : $AVANT, 10 s après : $APRES"
[ "$AVANT" = "$APRES" ] && ok "aucune donnée invalide n'est arrivée dans DynamoDB" \
                        || ko "des items ont été ajoutés malgré des requêtes invalides"

# ---------------------------------------------------------------------------
echo
echo "=== Test 4 : message livré deux fois (idempotence de la Lambda B) ==="
QURL=$(awsl sqs get-queue-url --queue-name "$QUEUE_NAME" --query QueueUrl --output text)
DUP_ID="doublon-$(date +%s)"
DUP="{\"id\":\"$DUP_ID\",\"receivedAt\":\"$(date -u +%Y-%m-%dT%H:%M:%S+00:00)\",\"data\":{\"client\":\"Doublon\",\"montant\":1}}"
AVANT=$(count_items)
awsl sqs send-message --queue-url "$QURL" --message-body "$DUP" > /dev/null
awsl sqs send-message --queue-url "$QURL" --message-body "$DUP" > /dev/null
echo "  Même message (id=$DUP_ID) envoyé 2 fois dans la file"
wait_item "$DUP_ID" > /dev/null
sleep 10
APRES=$(count_items)
echo "  Items avant : $AVANT, après : $APRES"
[ $((APRES - AVANT)) -eq 1 ] && ok "un seul item créé pour le message en double" \
                             || ko "1 item attendu, $((APRES - AVANT)) créé(s)"

# ---------------------------------------------------------------------------
echo
echo "=== Test 5 : message illisible dans la file -> 3 tentatives puis DLQ ==="
DLQURL=$(awsl sqs get-queue-url --queue-name "$DLQ_NAME" --query QueueUrl --output text)
dlq_count() {
    awsl sqs get-queue-attributes --queue-url "$DLQURL" \
        --attribute-names ApproximateNumberOfMessages --query Attributes.ApproximateNumberOfMessages --output text
}
DLQ_AVANT=$(dlq_count)
awsl sqs send-message --queue-url "$QURL" --message-body '{"pas":"le bon format"}' > /dev/null
echo "  Message {\"pas\":\"le bon format\"} déposé dans la file (attente jusqu'à 150 s)"
START=$SECONDS
while [ $((SECONDS - START)) -lt 150 ] && [ "$(dlq_count)" -le "$DLQ_AVANT" ]; do sleep 5; done
if [ "$(dlq_count)" -gt "$DLQ_AVANT" ]; then
    ok "message déplacé dans la DLQ après $((SECONDS - START)) s"
    echo "  Contenu de la DLQ : $(awsl sqs receive-message --queue-url "$DLQURL" --visibility-timeout 0 \
        --query 'Messages[0].Body' --output text)"
else
    ko "le message n'est pas arrivé dans la DLQ"
fi

# ---------------------------------------------------------------------------
echo
echo "=== Bilan : $PASS OK, $FAIL échec(s) ==="

# --- Preuves complémentaires ---
bash "$TP_DIR/infra/check.sh" > "$PREUVES/ressources.txt" 2>&1
awsl dynamodb scan --table-name "$TABLE_NAME" \
    --query "Items[].[id.S,client.S,montant.N,receivedAt.S,processedAt.S]" --output table \
    > "$PREUVES/dynamodb_scan.txt"
for fn in "$LAMBDA_HTTP" "$LAMBDA_WORKER"; do
    awsl logs filter-log-events --log-group-name "/aws/lambda/$fn" --query "events[].message" --output json \
        | python3 -c "import json,sys; [print(m.rstrip()) for m in json.load(sys.stdin) if not m.startswith(('START','END','REPORT'))]" \
        > "$PREUVES/logs_$fn.txt"
done
echo "Preuves enregistrées dans preuves/ : run_tests.txt, ressources.txt, dynamodb_scan.txt, logs_$LAMBDA_HTTP.txt, logs_$LAMBDA_WORKER.txt"

[ "$FAIL" -eq 0 ]
