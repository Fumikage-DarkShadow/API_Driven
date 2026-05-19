#!/usr/bin/env bash
#
# Supprime toute l'infrastructure deployee par setup.sh.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${ROOT_DIR}/.state/resources.env"

LAMBDA_NAME="${LAMBDA_NAME:-ec2-control}"
API_NAME="${API_NAME:-ec2-control-api}"
ATELIER_TAG="${ATELIER_TAG:-atelier-ec2}"

GREEN="\033[0;32m"; YELLOW="\033[1;33m"; NC="\033[0m"
log()  { echo -e "${YELLOW}[teardown]${NC} $*"; }
ok()   { echo -e "${GREEN}[ok]${NC} $*"; }

if [ -f "${STATE_FILE}" ]; then
    # shellcheck disable=SC1090
    source "${STATE_FILE}"
fi

# 1) API Gateway
log "Suppression des APIs ${API_NAME}..."
for id in $(awslocal apigatewayv2 get-apis --query "Items[?Name=='${API_NAME}'].ApiId" --output text 2>/dev/null); do
    awslocal apigatewayv2 delete-api --api-id "${id}" >/dev/null 2>&1 || true
done

# 2) Lambda
log "Suppression de la Lambda ${LAMBDA_NAME}..."
awslocal lambda delete-function --function-name "${LAMBDA_NAME}" >/dev/null 2>&1 || true

# 3) Toutes les instances EC2 portant notre tag
log "Terminaison des instances EC2 taggees ${ATELIER_TAG}..."
INSTANCE_IDS=$(awslocal ec2 describe-instances \
    --filters "Name=tag:Name,Values=${ATELIER_TAG}" \
    --query 'Reservations[*].Instances[?State.Name!=`terminated`].InstanceId' \
    --output text 2>/dev/null)
if [ -n "${INSTANCE_IDS}" ] && [ "${INSTANCE_IDS}" != "None" ]; then
    awslocal ec2 terminate-instances --instance-ids ${INSTANCE_IDS} >/dev/null 2>&1 || true
fi

# 4) Nettoyage local
rm -rf "${ROOT_DIR}/build" "${ROOT_DIR}/.state"

ok "Infrastructure supprimee."
