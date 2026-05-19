SHELL := /bin/bash

# ============================================================================
# Atelier API-Driven Infrastructure
# Pilotage d'une instance EC2 via API Gateway + Lambda sur LocalStack
# ============================================================================

ROOT      := $(shell pwd)
SCRIPTS   := $(ROOT)/scripts
STATE     := $(ROOT)/.state/resources.env

.DEFAULT_GOAL := help

# ---------- Aide ----------------------------------------------------------
help: ## Liste les commandes disponibles
	@echo ""
	@echo "Commandes disponibles :"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	    | awk 'BEGIN{FS=":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ---------- Pre-requis ----------------------------------------------------
deps: ## Installe awscli-local et jq (a faire une fois dans le Codespace)
	@echo "[deps] Installation awscli-local + jq..."
	@pip install awscli-local --quiet
	@which jq >/dev/null || sudo apt-get install -y jq
	@echo "[deps] OK"

check: ## Verifie que LocalStack tourne et que ses services sont disponibles
	@curl -sf http://localhost:4566/_localstack/health > /dev/null \
	    && echo "[check] LocalStack repond sur localhost:4566 ✓" \
	    || (echo "[check] LocalStack ne repond pas. Lance : localstack start -d" && exit 1)
	@awslocal --version > /dev/null \
	    && echo "[check] awslocal disponible ✓" \
	    || (echo "[check] awslocal manquant. Lance : make deps" && exit 1)

# ---------- Cycle de vie de l'infrastructure ------------------------------
setup: check ## Cree EC2 + Lambda + API Gateway dans LocalStack
	@bash $(SCRIPTS)/setup.sh

teardown: ## Supprime EC2 + Lambda + API Gateway
	@bash $(SCRIPTS)/teardown.sh

reset: teardown setup ## Supprime puis recree toute l'infra

# ---------- Actions metier ------------------------------------------------
start: ## Demarre l'instance EC2 via l'API
	@bash $(SCRIPTS)/invoke.sh start

stop: ## Arrete l'instance EC2 via l'API
	@bash $(SCRIPTS)/invoke.sh stop

status: ## Affiche l'etat actuel de l'instance EC2
	@bash $(SCRIPTS)/invoke.sh status

# ---------- Outillage -----------------------------------------------------
info: ## Affiche les IDs des ressources deployees
	@if [ -f $(STATE) ]; then \
	    echo ""; \
	    echo "Etat actuel :"; \
	    cat $(STATE) | sed 's/^/  /'; \
	    echo ""; \
	else \
	    echo "Aucune ressource deployee. Lance : make setup"; \
	fi

logs: ## Affiche les logs Lambda les plus recents
	@LAMBDA_NAME=$$(grep LAMBDA_NAME $(STATE) 2>/dev/null | cut -d= -f2); \
	if [ -z "$$LAMBDA_NAME" ]; then echo "Aucune Lambda deployee."; exit 1; fi; \
	GROUP="/aws/lambda/$$LAMBDA_NAME"; \
	STREAM=$$(awslocal logs describe-log-streams --log-group-name $$GROUP \
	    --order-by LastEventTime --descending --limit 1 \
	    --query 'logStreams[0].logStreamName' --output text 2>/dev/null); \
	if [ -z "$$STREAM" ] || [ "$$STREAM" = "None" ]; then \
	    echo "Pas encore de logs (la Lambda n'a pas ete invoquee)."; \
	else \
	    awslocal logs get-log-events --log-group-name $$GROUP --log-stream-name $$STREAM \
	        --query 'events[*].message' --output text; \
	fi

ec2-list: ## Liste les instances EC2 dans LocalStack
	@awslocal ec2 describe-instances \
	    --query 'Reservations[*].Instances[*].[InstanceId,State.Name,InstanceType]' \
	    --output table

clean: ## Supprime les artefacts de build (zip, etat local)
	@rm -rf build .state
	@echo "[clean] OK"

.PHONY: help deps check setup teardown reset start stop status info logs ec2-list clean
