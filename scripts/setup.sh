#!/usr/bin/env bash
#
# Script de mise en place complete de l'architecture API-driven sur LocalStack.
#
# Ce script :
#   1. Lance une instance EC2 (simulee par LocalStack)
#   2. Empaquette le code Python de la Lambda dans un .zip
#   3. Cree la fonction Lambda dans LocalStack avec l'INSTANCE_ID en env var
#   4. Cree une API Gateway HTTP avec 3 routes : POST /start, POST /stop, GET /status
#   5. Branche chaque route sur la Lambda
#   6. Affiche l'URL d'invocation finale
#
# Pre-requis :
#   - LocalStack tourne sur localhost:4566
#   - awslocal est installe (pip install awscli-local)
#   - zip est installe (deja present sur Codespace par defaut)

set -euo pipefail

# === Parametres ajustables =============================================
LAMBDA_NAME="${LAMBDA_NAME:-ec2-control}"
API_NAME="${API_NAME:-ec2-control-api}"
REGION="${AWS_REGION:-us-east-1}"
AMI_ID="${AMI_ID:-ami-0abcdef1234567890}"   # AMI fictive, LocalStack accepte n'importe quoi
INSTANCE_TYPE="${INSTANCE_TYPE:-t2.micro}"
STAGE_NAME="${STAGE_NAME:-prod}"

# Chemins
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAMBDA_DIR="${ROOT_DIR}/lambda"
BUILD_DIR="${ROOT_DIR}/build"
ZIP_FILE="${BUILD_DIR}/lambda.zip"

# Couleurs pour les logs
GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

log()   { echo -e "${BLUE}[setup]${NC} $*"; }
ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
fail()  { echo -e "${RED}[fail]${NC} $*" >&2; exit 1; }

# === 0. Verifications ===================================================
command -v awslocal >/dev/null || fail "awslocal introuvable. Installe-le : pip install awscli-local"
command -v zip      >/dev/null || fail "zip introuvable. Installe-le : sudo apt-get install -y zip"
curl -sf http://localhost:4566/_localstack/health >/dev/null \
    || fail "LocalStack ne repond pas sur localhost:4566. Demarre-le : localstack start -d"

# === 1. Lancer l'instance EC2 ==========================================
log "Lancement d'une instance EC2 (AMI=${AMI_ID}, type=${INSTANCE_TYPE})..."
INSTANCE_ID=$(awslocal ec2 run-instances \
    --image-id "${AMI_ID}" \
    --instance-type "${INSTANCE_TYPE}" \
    --count 1 \
    --query 'Instances[0].InstanceId' \
    --output text)
ok "EC2 cree : ${INSTANCE_ID}"

# === 2. Empaqueter la Lambda ===========================================
log "Empaquetage de la Lambda..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cp "${LAMBDA_DIR}/lambda_function.py" "${BUILD_DIR}/"
(cd "${BUILD_DIR}" && zip -q "${ZIP_FILE}" lambda_function.py)
ok "Zip cree : ${ZIP_FILE}"

# === 3. Creer (ou mettre a jour) la Lambda =============================
if awslocal lambda get-function --function-name "${LAMBDA_NAME}" >/dev/null 2>&1; then
    warn "La Lambda ${LAMBDA_NAME} existe deja, mise a jour du code et des variables..."
    awslocal lambda update-function-code \
        --function-name "${LAMBDA_NAME}" \
        --zip-file "fileb://${ZIP_FILE}" >/dev/null
    # On attend que l'update-function-code soit fini avant l'update-function-configuration
    awslocal lambda wait function-updated --function-name "${LAMBDA_NAME}"
    awslocal lambda update-function-configuration \
        --function-name "${LAMBDA_NAME}" \
        --environment "Variables={INSTANCE_ID=${INSTANCE_ID},AWS_ENDPOINT_URL=http://localhost.localstack.cloud:4566}" >/dev/null
else
    log "Creation de la Lambda ${LAMBDA_NAME}..."
    awslocal lambda create-function \
        --function-name "${LAMBDA_NAME}" \
        --runtime python3.11 \
        --role arn:aws:iam::000000000000:role/lambda-role \
        --handler lambda_function.handler \
        --zip-file "fileb://${ZIP_FILE}" \
        --environment "Variables={INSTANCE_ID=${INSTANCE_ID},AWS_ENDPOINT_URL=http://localhost.localstack.cloud:4566}" >/dev/null
fi
ok "Lambda prete : ${LAMBDA_NAME} (INSTANCE_ID=${INSTANCE_ID})"

LAMBDA_ARN=$(awslocal lambda get-function \
    --function-name "${LAMBDA_NAME}" \
    --query 'Configuration.FunctionArn' --output text)

# === 4. Creer l'API Gateway (HTTP API v2) ==============================
log "Creation de l'API Gateway (HTTP API v2)..."
# On supprime l'eventuelle API precedente du meme nom pour repartir propre
EXISTING_API_ID=$(awslocal apigatewayv2 get-apis \
    --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text 2>/dev/null || echo "None")
if [ "${EXISTING_API_ID}" != "None" ] && [ -n "${EXISTING_API_ID}" ]; then
    warn "API existante ${EXISTING_API_ID} supprimee"
    awslocal apigatewayv2 delete-api --api-id "${EXISTING_API_ID}" >/dev/null
fi

API_ID=$(awslocal apigatewayv2 create-api \
    --name "${API_NAME}" \
    --protocol-type HTTP \
    --target "${LAMBDA_ARN}" \
    --query 'ApiId' --output text)
ok "API creee : ${API_ID}"

# === 5. Brancher 3 routes /start /stop /status ========================
log "Creation des routes /start /stop /status..."

# L'integration AWS_PROXY est deja creee automatiquement par --target ci-dessus.
# Recuperons son ID pour la reutiliser sur les routes specifiques.
INTEGRATION_ID=$(awslocal apigatewayv2 get-integrations \
    --api-id "${API_ID}" \
    --query 'Items[0].IntegrationId' --output text)

create_route() {
    local route_key="$1"
    awslocal apigatewayv2 create-route \
        --api-id "${API_ID}" \
        --route-key "${route_key}" \
        --target "integrations/${INTEGRATION_ID}" >/dev/null || true
}

create_route "POST /start"
create_route "POST /stop"
create_route "GET /status"

# Donne la permission a API Gateway d'invoquer la Lambda
awslocal lambda add-permission \
    --function-name "${LAMBDA_NAME}" \
    --statement-id apigw-invoke-$(date +%s) \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com >/dev/null 2>&1 || true

# === 6. Deployer (creer un stage) ======================================
awslocal apigatewayv2 create-stage \
    --api-id "${API_ID}" \
    --stage-name "${STAGE_NAME}" \
    --auto-deploy >/dev/null 2>&1 || true

# === 7. Afficher l'URL finale ==========================================
API_ENDPOINT="http://localhost:4566/restapis/${API_ID}/${STAGE_NAME}/_user_request_"
# Pour les HTTP APIs (v2), LocalStack expose aussi via :
API_ENDPOINT_V2="http://${API_ID}.execute-api.localhost.localstack.cloud:4566"

# Persister les ID dans un fichier pour les autres scripts
mkdir -p "${ROOT_DIR}/.state"
{
    echo "INSTANCE_ID=${INSTANCE_ID}"
    echo "LAMBDA_NAME=${LAMBDA_NAME}"
    echo "API_ID=${API_ID}"
    echo "STAGE_NAME=${STAGE_NAME}"
    echo "API_ENDPOINT=${API_ENDPOINT_V2}"
} > "${ROOT_DIR}/.state/resources.env"

echo ""
ok "Architecture deployee :"
echo ""
echo "  EC2 instance : ${INSTANCE_ID}"
echo "  Lambda       : ${LAMBDA_NAME}"
echo "  API ID       : ${API_ID}"
echo "  Stage        : ${STAGE_NAME}"
echo ""
echo "  URL d'invocation : ${API_ENDPOINT_V2}"
echo ""
echo "  Teste avec :"
echo "    curl -X POST ${API_ENDPOINT_V2}/start"
echo "    curl -X POST ${API_ENDPOINT_V2}/stop"
echo "    curl -X GET  ${API_ENDPOINT_V2}/status"
echo ""
echo "  Ou plus simple :"
echo "    make start"
echo "    make stop"
echo "    make status"
