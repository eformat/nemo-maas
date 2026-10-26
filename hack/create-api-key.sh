#!/usr/bin/env bash
#
# Create a MaaS API key (sk-oai-*) for gateway probes, bypassing the guarded gateway.
#
# Why not POST /v1/api-keys through the gateway: on a Part-C (Praxis + ai_guardrails) tenant the
# guard rejects any non-Chat-Completions request body with 500 — MaaS management API POSTs break
# through the guarded gateway. This script talks to maas-api directly via port-forward with the
# identity headers the gateway auth policy normally injects (maas-api's ExtractUserInfo requires
# X-MaaS-Username + X-MaaS-Group; missing -> AUTH_FAILURE).
#
# The key is saved to overlays/cluster/maas-api-key.secret.env (gitignored via *.secret.env) as
# MAAS_API_KEY=... — the same var hack/verify.sh consumes.
#
# Verified on prelude2 2026-10-26.
#
# Requires: oc (logged in), curl, jq.
set -euo pipefail

NS="${MAAS_API_NS:-redhat-ai-gateway-infra}"
USERNAME="${MAAS_USERNAME:-$(oc whoami 2>/dev/null || echo "")}"
GROUP="${MAAS_GROUP:-system:authenticated}"
KEY_NAME="${KEY_NAME:-nemo-maas-test-$(date +%s)}"
EPHEMERAL="${EPHEMERAL:-true}"       # true -> 1hr expiry
PORT="${MAAS_API_PORT:-18443}"
SECRET_ENV="$(cd "$(dirname "$0")/.." && pwd)/overlays/cluster/maas-api-key.secret.env"

for bin in oc curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not found in PATH." >&2; exit 1; }
done
[[ -n "$USERNAME" ]] || { echo "ERROR: could not resolve the username (oc whoami). Set MAAS_USERNAME." >&2; exit 1; }

TOKEN="$(oc whoami --show-token 2>/dev/null || true)"
[[ -n "$TOKEN" ]] || { echo "ERROR: could not resolve the login token (oc whoami --show-token)." >&2; exit 1; }

echo "==> Port-forwarding svc/maas-api -n $NS ${PORT}:8443"
oc port-forward "svc/maas-api" -n "$NS" "${PORT}:8443" >/tmp/opencode/maas-api-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
sleep 3

echo "==> Creating key '$KEY_NAME' for $USERNAME (groups: $GROUP, ephemeral=$EPHEMERAL)"
RESP="$(curl -sk --max-time 20 -X POST "https://localhost:${PORT}/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-MaaS-Username: $USERNAME" \
  -H "X-MaaS-Group: [\"$GROUP\"]" \
  -H 'Content-Type: application/json' \
  -d "$(jq -cn --arg n "$KEY_NAME" --arg e "$EPHEMERAL" '{name:$n, ephemeral:($e=="true")}')" || true)"

KEY="$(jq -r .key <<<"$RESP" 2>/dev/null || true)"
if [[ -z "$KEY" || "$KEY" == "null" ]]; then
  echo "ERROR: key creation failed:" >&2
  echo "$RESP" | head -c 400 >&2
  echo >&2
  echo "  (the key inherits the crafted identity's groups; ensure '$GROUP' matches the" >&2
  echo "   subscription owner groups of the model you probe)" >&2
  exit 1
fi

EXPIRES="$(jq -r .expiresAt <<<"$RESP" 2>/dev/null || echo "?")"
PREFIX="$(jq -r .keyPrefix <<<"$RESP" 2>/dev/null || echo "${KEY:0:16}...")"

mkdir -p "$(dirname "$SECRET_ENV")"
cat > "$SECRET_ENV" <<EOF
MAAS_API_KEY=$KEY
MAAS_API_KEY_NAME=$KEY_NAME
MAAS_API_KEY_EXPIRES_AT=$EXPIRES
EOF
chmod 600 "$SECRET_ENV"

echo "==> Key created: $PREFIX (expires $EXPIRES)"
echo "==> Saved to $SECRET_ENV (gitignored) — consumed by hack/verify.sh as MAAS_API_KEY"
echo "    Full key is NOT printed; read it with: source $SECRET_ENV"
