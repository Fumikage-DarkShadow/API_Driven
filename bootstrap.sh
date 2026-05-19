#!/usr/bin/env bash
#
# Script bootstrap : installe tout ce qu'il faut et lance le setup complet.
# Usage dans le Codespace :
#   bash bootstrap.sh
#
# Pre-requis : LocalStack deja demarre (localstack start -d).

set -e

GREEN="\033[0;32m"; YELLOW="\033[1;33m"; RED="\033[0;31m"; NC="\033[0m"
log()  { echo -e "${YELLOW}▶${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

# === 1. PATH user binaries =================================================
log "Ajout de ~/.local/bin et ~/.python/current/bin au PATH..."
export PATH="$HOME/.local/bin:$HOME/.python/current/bin:$PATH"

# Persister dans bashrc s'il n'y est pas deja
if ! grep -q '.local/bin' ~/.bashrc 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$HOME/.python/current/bin:$PATH"' >> ~/.bashrc
fi
ok "PATH ok"

# === 2. Installer AWS CLI ==================================================
if ! command -v aws >/dev/null 2>&1; then
    log "Installation de AWS CLI (peut prendre ~30s)..."
    python3 -m pip install --user --quiet awscli
fi
command -v aws >/dev/null || fail "aws CLI introuvable apres install"
ok "aws CLI : $(aws --version 2>&1 | head -1)"

# === 3. Installer awscli-local =============================================
if ! command -v awslocal >/dev/null 2>&1; then
    log "Installation de awscli-local..."
    python3 -m pip install --user --quiet awscli-local
fi
command -v awslocal >/dev/null || fail "awslocal introuvable apres install"
ok "awslocal : $(which awslocal)"

# === 4. Installer jq =======================================================
if ! command -v jq >/dev/null 2>&1; then
    log "Installation de jq..."
    sudo apt-get install -y -qq jq >/dev/null 2>&1 || true
fi
command -v jq >/dev/null && ok "jq : $(jq --version)" || log "jq pas indispensable, on continue"

# === 5. Verifier LocalStack ================================================
log "Verification de LocalStack..."
if ! curl -sf http://localhost:4566/_localstack/health >/dev/null; then
    fail "LocalStack ne repond pas sur localhost:4566. Lance d'abord : localstack start -d"
fi
ok "LocalStack repond sur localhost:4566"

# === 6. Tester awslocal contre LocalStack ==================================
log "Test de connexion awslocal -> LocalStack..."
if ! awslocal sts get-caller-identity >/dev/null 2>&1; then
    log "awslocal sts ne renvoie pas grand chose (normal en CE), on continue..."
fi
ok "awslocal communique avec LocalStack"

# === 7. Lancer make setup ==================================================
echo ""
log "============================================================="
log "  Pre-requis OK. Lancement de make setup..."
log "============================================================="
echo ""
make setup
