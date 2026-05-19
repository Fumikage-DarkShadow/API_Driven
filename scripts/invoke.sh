#!/usr/bin/env bash
#
# Helper qui invoque l'API HTTP deployee par setup.sh.
# Usage : ./scripts/invoke.sh start|stop|status

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_FILE="${ROOT_DIR}/.state/resources.env"

if [ ! -f "${STATE_FILE}" ]; then
    echo "[invoke] Etat manquant : lance d'abord 'make setup' (ou ./scripts/setup.sh)" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${STATE_FILE}"

ACTION="${1:-status}"

case "${ACTION}" in
    start)
        curl -sS -X POST "${API_ENDPOINT}/start" | jq . || true
        ;;
    stop)
        curl -sS -X POST "${API_ENDPOINT}/stop" | jq . || true
        ;;
    status)
        curl -sS -X GET "${API_ENDPOINT}/status" | jq . || true
        ;;
    *)
        echo "Usage : $0 [start|stop|status]" >&2
        exit 1
        ;;
esac
echo ""
