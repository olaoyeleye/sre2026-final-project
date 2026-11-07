#!/usr/bin/env bash
# =====================================================================
# Creates the Kubernetes Secrets the banking stack needs.
# Secrets are kept OUT of Git; Argo CD does not manage them.
#
# Safe to re-run: any value that already exists in the cluster is KEPT
# (important - Postgres only reads its password when the volume is first
# initialised, so changing it later would lock the apps out).
#
# Usage:
#   export OPENAI_API_KEY=sk-...                # finance-agent chat
#   export CLOUDFLARE_API_TOKEN=...             # cert-manager DNS-01
#   ./scripts/create-secrets.sh
#
# Optional overrides (otherwise existing or random values are used):
#   KEYCLOAK_DB_PASSWORD, BANKING_DB_PASSWORD, KC_ADMIN_USER,
#   KC_ADMIN_PASSWORD, KEYCLOAK_ADMIN_CLIENT_SECRET, OPENAI_MODEL
# =====================================================================
set -euo pipefail

NS=banking

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# existing <secret> <key> [namespace] -> prints the current value, or nothing
existing() {
  kubectl -n "${3:-$NS}" get secret "$1" -o "jsonpath={.data.$2}" 2>/dev/null | base64 -d 2>/dev/null || true
}

# pick <secret> <key> <override> <fallback> -> existing value > override > fallback
pick() {
  local cur; cur="$(existing "$1" "$2")"
  if [ -n "$cur" ]; then printf '%s' "$cur"
  elif [ -n "$3" ]; then printf '%s' "$3"
  else printf '%s' "$4"; fi
}

rand() { openssl rand -hex 24; }   # hex = URL-safe, needed inside DATABASE_URL

apply_secret() {   # apply_secret <namespace> <name> --from-literal=... ...
  local ns="$1" name="$2"; shift 2
  kubectl -n "$ns" create secret generic "$name" "$@" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "  ok  $ns/$name"
}

echo "Creating secrets in namespace '$NS'..."

apply_secret "$NS" keycloak-postgres-secret \
  --from-literal=POSTGRES_USER="$(pick keycloak-postgres-secret POSTGRES_USER "" keycloak)" \
  --from-literal=POSTGRES_PASSWORD="$(pick keycloak-postgres-secret POSTGRES_PASSWORD "${KEYCLOAK_DB_PASSWORD:-}" "$(rand)")"

apply_secret "$NS" banking-postgres-secret \
  --from-literal=POSTGRES_USER="$(pick banking-postgres-secret POSTGRES_USER "" bankuser)" \
  --from-literal=POSTGRES_PASSWORD="$(pick banking-postgres-secret POSTGRES_PASSWORD "${BANKING_DB_PASSWORD:-}" "$(rand)")"

apply_secret "$NS" keycloak-admin-secret \
  --from-literal=KC_BOOTSTRAP_ADMIN_USERNAME="$(pick keycloak-admin-secret KC_BOOTSTRAP_ADMIN_USERNAME "${KC_ADMIN_USER:-}" admin)" \
  --from-literal=KC_BOOTSTRAP_ADMIN_PASSWORD="$(pick keycloak-admin-secret KC_BOOTSTRAP_ADMIN_PASSWORD "${KC_ADMIN_PASSWORD:-}" "$(rand)")"

# Shared by user-service and Keycloak's realm import (banking-provisioner client)
apply_secret "$NS" user-service-secret \
  --from-literal=KEYCLOAK_ADMIN_CLIENT_SECRET="$(pick user-service-secret KEYCLOAK_ADMIN_CLIENT_SECRET "${KEYCLOAK_ADMIN_CLIENT_SECRET:-}" "$(rand)")"

OPENAI_KEY="$(pick finance-agent-secret OPENAI_API_KEY "${OPENAI_API_KEY:-}" "")"
[ -z "$OPENAI_KEY" ] && echo "  !!  OPENAI_API_KEY not set - the AI assistant will not answer until you set it and re-run"
apply_secret "$NS" finance-agent-secret \
  --from-literal=OPENAI_API_KEY="$OPENAI_KEY" \
  --from-literal=OPENAI_MODEL="$(pick finance-agent-secret OPENAI_MODEL "${OPENAI_MODEL:-}" gpt-4.1-mini)"

CF_TOKEN="$(existing cloudflare-api-token api-token cert-manager)"
CF_TOKEN="${CF_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
if [ -n "$CF_TOKEN" ]; then
  apply_secret cert-manager cloudflare-api-token --from-literal=api-token="$CF_TOKEN"
else
  echo "  !!  CLOUDFLARE_API_TOKEN not set - the TLS certificate cannot be issued until you set it and re-run"
fi

echo
echo "Keycloak admin login:"
echo "  user:     $(existing keycloak-admin-secret KC_BOOTSTRAP_ADMIN_USERNAME)"
echo "  password: kubectl -n $NS get secret keycloak-admin-secret -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d; echo"
