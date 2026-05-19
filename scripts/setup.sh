#!/usr/bin/env bash
#
# Script de mise en place complete de l'architecture API-driven sur LocalStack.
#
# Crée :
#   - 1 AMI fictive
#   - 1 instance EC2 (avec tag Name=atelier-ec2)
#   - 1 Lambda Python qui pilote l'EC2 par TAG
#   - 1 API Gateway HTTP v2 avec routes /start /stop /status

set -euo pipefail

# === Parametres ============================================================
LAMBDA_NAME="${LAMBDA_NAME:-ec2-control}"
API_NAME="${API_NAME:-ec2-control-api}"
REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t2.micro}"
STAGE_NAME="${STAGE_NAME:-prod}"
ATELIER_TAG="${ATELIER_TAG:-atelier-ec2}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAMBDA_DIR="${ROOT_DIR}/lambda"
BUILD_DIR="${ROOT_DIR}/build"
ZIP_FILE="${BUILD_DIR}/lambda.zip"

GREEN="\033[0;32m"
BLUE="\033[0;34m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
NC="\033[0m"

log()   { echo -e "${BLUE}[setup]${NC} $*"; }
ok()    { echo -e "${GREEN}[ok]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC} $*"; }
fail()  { echo -e "${RED}[fail]${NC} $*" >&2; exit 1; }

# === 0. Verifications ======================================================
command -v awslocal >/dev/null || fail "awslocal introuvable. Installe-le : pip install awscli-local"
command -v zip      >/dev/null || fail "zip introuvable. Installe-le : sudo apt-get install -y zip"
curl -sf http://localhost:4566/_localstack/health >/dev/null \
    || fail "LocalStack ne repond pas sur localhost:4566. Demarre-le : localstack start -d"

# === 1. Enregistrer une AMI fictive fraiche ================================
# On enregistre toujours une nouvelle AMI pour eviter les bizarreries des AMI
# pre-chargees par LocalStack (ex : ami-eks-* qui auto-terminent les instances).
log "Enregistrement d'une AMI fictive fraiche..."
AMI_ID=$(awslocal ec2 register-image \
    --name "atelier-ami-$(date +%s)" \
    --description "AMI fictive atelier API-Driven" \
    --root-device-name "/dev/sda1" \
    --architecture x86_64 \
    --query 'ImageId' --output text)
ok "AMI creee : ${AMI_ID}"

# === 2. Empaqueter la Lambda ===============================================
log "Empaquetage de la Lambda..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cp "${LAMBDA_DIR}/lambda_function.py" "${BUILD_DIR}/"
(cd "${BUILD_DIR}" && zip -q "${ZIP_FILE}" lambda_function.py)
ok "Zip cree : ${ZIP_FILE}"

# === 3. Creer (ou mettre a jour) la Lambda =================================
LAMBDA_ENV_VARS="Variables={ATELIER_TAG=${ATELIER_TAG},AMI_ID=${AMI_ID},INSTANCE_TYPE=${INSTANCE_TYPE}}"

if awslocal lambda get-function --function-name "${LAMBDA_NAME}" >/dev/null 2>&1; then
    warn "Lambda ${LAMBDA_NAME} existe deja, mise a jour..."
    awslocal lambda update-function-code \
        --function-name "${LAMBDA_NAME}" \
        --zip-file "fileb://${ZIP_FILE}" >/dev/null
    awslocal lambda wait function-updated --function-name "${LAMBDA_NAME}"
    awslocal lambda update-function-configuration \
        --function-name "${LAMBDA_NAME}" \
        --environment "${LAMBDA_ENV_VARS}" >/dev/null
else
    log "Creation de la Lambda ${LAMBDA_NAME}..."
    awslocal lambda create-function \
        --function-name "${LAMBDA_NAME}" \
        --runtime python3.11 \
        --role arn:aws:iam::000000000000:role/lambda-role \
        --handler lambda_function.handler \
        --zip-file "fileb://${ZIP_FILE}" \
        --environment "${LAMBDA_ENV_VARS}" >/dev/null
fi
ok "Lambda prete : ${LAMBDA_NAME}"

LAMBDA_ARN=$(awslocal lambda get-function \
    --function-name "${LAMBDA_NAME}" \
    --query 'Configuration.FunctionArn' --output text)

# === 4. Creer l'instance EC2 initiale via la Lambda (par tag) =============
# Au lieu de creer l'EC2 directement, on laisse la Lambda le faire au premier
# appel /start. C'est plus coherent avec la philosophie API-driven.
log "L'instance EC2 sera creee a la premiere requete /start"

# === 5. Creer l'API Gateway (HTTP v2) ======================================
log "Creation de l'API Gateway (HTTP v2)..."
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

# === 6. Brancher 3 routes ==================================================
log "Creation des routes /start /stop /status..."
INTEGRATION_ID=$(awslocal apigatewayv2 get-integrations \
    --api-id "${API_ID}" \
    --query 'Items[0].IntegrationId' --output text)

create_route() {
    awslocal apigatewayv2 create-route \
        --api-id "${API_ID}" \
        --route-key "$1" \
        --target "integrations/${INTEGRATION_ID}" >/dev/null || true
}

create_route "POST /start"
create_route "POST /stop"
create_route "GET /status"

awslocal lambda add-permission \
    --function-name "${LAMBDA_NAME}" \
    --statement-id apigw-invoke-$(date +%s) \
    --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com >/dev/null 2>&1 || true

awslocal apigatewayv2 create-stage \
    --api-id "${API_ID}" \
    --stage-name "${STAGE_NAME}" \
    --auto-deploy >/dev/null 2>&1 || true

API_ENDPOINT="http://${API_ID}.execute-api.localhost.localstack.cloud:4566"

# Etat persistant
mkdir -p "${ROOT_DIR}/.state"
{
    echo "AMI_ID=${AMI_ID}"
    echo "LAMBDA_NAME=${LAMBDA_NAME}"
    echo "API_ID=${API_ID}"
    echo "STAGE_NAME=${STAGE_NAME}"
    echo "API_ENDPOINT=${API_ENDPOINT}"
    echo "ATELIER_TAG=${ATELIER_TAG}"
} > "${ROOT_DIR}/.state/resources.env"

echo ""
ok "Architecture deployee :"
echo ""
echo "  AMI fictive   : ${AMI_ID}"
echo "  Lambda        : ${LAMBDA_NAME}"
echo "  API ID        : ${API_ID}"
echo "  Stage         : ${STAGE_NAME}"
echo "  Tag EC2       : ${ATELIER_TAG}"
echo ""
echo "  URL d'invocation : ${API_ENDPOINT}"
echo ""
echo "  Commandes a tester :"
echo "    make start    # cree l'EC2 si absente, sinon la redemarre"
echo "    make status   # affiche l'etat actuel"
echo "    make stop     # arrete l'EC2"
echo ""
