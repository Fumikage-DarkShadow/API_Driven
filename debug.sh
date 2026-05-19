#!/usr/bin/env bash
#
# Diagnostic complet : re-deploie la Lambda et l'invoque de plusieurs facons
# pour comprendre ce qui se passe.
#
# Usage :
#   bash debug.sh
#
# Le script affiche tous les detail. Tu n'as qu'a coller la sortie integrale.

set -e

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

echo ""
echo "======================================================================="
echo "  ETAPE 1/6 : Re-deploiement complet (reset + setup)"
echo "======================================================================="
make reset

echo ""
echo "======================================================================="
echo "  ETAPE 2/6 : Etat des ressources"
echo "======================================================================="
make info

# Recharge les IDs
source "${ROOT_DIR}/.state/resources.env"

echo ""
echo "======================================================================="
echo "  ETAPE 3/6 : Test direct Lambda - payload type API Gateway v1 (path)"
echo "======================================================================="
awslocal lambda invoke \
    --function-name "${LAMBDA_NAME}" \
    --payload "$(echo -n '{"path":"/status"}' | base64)" \
    /tmp/out_v1.json
echo ""
echo ">>> Reponse Lambda (v1 path) :"
cat /tmp/out_v1.json
echo ""

echo ""
echo "======================================================================="
echo "  ETAPE 4/6 : Test direct Lambda - payload type API Gateway v2 (rawPath)"
echo "======================================================================="
awslocal lambda invoke \
    --function-name "${LAMBDA_NAME}" \
    --payload "$(echo -n '{"rawPath":"/status"}' | base64)" \
    /tmp/out_v2.json
echo ""
echo ">>> Reponse Lambda (v2 rawPath) :"
cat /tmp/out_v2.json
echo ""

echo ""
echo "======================================================================="
echo "  ETAPE 5/6 : Test via API Gateway HTTP"
echo "======================================================================="
echo ">>> Reponse API Gateway /status :"
curl -sS "${API_ENDPOINT}/status" -o /tmp/out_api.json -w "HTTP %{http_code}\n"
echo ">>> Body :"
cat /tmp/out_api.json
echo ""

echo ""
echo "======================================================================="
echo "  ETAPE 6/6 : Logs Lambda (les 3 dernieres invocations)"
echo "======================================================================="
GROUP="/aws/lambda/${LAMBDA_NAME}"
STREAMS=$(awslocal logs describe-log-streams \
    --log-group-name "${GROUP}" \
    --order-by LastEventTime \
    --descending \
    --limit 3 \
    --query 'logStreams[*].logStreamName' \
    --output text 2>/dev/null || echo "")

if [ -z "${STREAMS}" ]; then
    echo "Aucun log trouve."
else
    for STREAM in ${STREAMS}; do
        echo ""
        echo "---- Stream: ${STREAM} ----"
        awslocal logs get-log-events \
            --log-group-name "${GROUP}" \
            --log-stream-name "${STREAM}" \
            --query 'events[*].message' \
            --output text 2>/dev/null || echo "(pas de logs)"
    done
fi

echo ""
echo "======================================================================="
echo "  FIN DU DIAGNOSTIC"
echo "======================================================================="
echo "Copie-colle tout ce qui est au-dessus dans le chat."
