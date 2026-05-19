#!/usr/bin/env bash
#
# Supprime toute l'infrastructure deployee par setup.sh.
# Utile pour repartir d'un etat propre.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${ROOT_DIR}/.state/resources.env"

LAMBDA_NAME="${LAMBDA_NAME:-ec2-control}"
API_NAME="${API_NAME:-ec2-control-api}"

GREEN="\033[0;32m"; YELLOW="\033[1;33m"; NC="\033[0m"
log()  { echo -e "${YELLOW}[teardown]${NC} $*"; }
ok()   { echo -e "${GREEN}[ok]${NC} $*"; }

# Charge l'etat si dispo
if [ -f "${STATE_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
fi

# 1) Supprime l'API
if [ -n "${API_ID:-}" ]; then
    log "Suppression de l'API ${API_ID}..."
    awslocal apigatewayv2 delete-api --api-id "${API_ID}" >/dev/null 2>&1 || true
fi
# Au cas ou : nettoie toute API du meme nom
for id in $(awslocal apigatewayv2 get-apis --query "Items[?Name=='${API_NAME}'].ApiId" --output text 2>/dev/null); do
    awslocal apigatewayv2 delete-api --api-id "${id}" >/dev/null 2>&1 || true
done

# 2) Supprime la Lambda
log "Suppression de la Lambda ${LAMBDA_NAME}..."
awslocal lambda delete-function --function-name "${LAMBDA_NAME}" >/dev/null 2>&1 || true

# 3) Termine l'EC2
if [ -n "${INSTANCE_ID:-}" ]; then
    log "Terminaison de l'instance EC2 ${INSTANCE_ID}..."
    awslocal ec2 terminate-instances --instance-ids "${INSTANCE_ID}" >/dev/null 2>&1 || true
fi

# 4) Nettoyage local
rm -rf "${ROOT_DIR}/build" "${ROOT_DIR}/.state"

ok "Infrastructure supprimee."
