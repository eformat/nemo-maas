#!/usr/bin/env bash
#
# praxis-guards — enable NeMo guardrails on the PRAXIS dataplane by patching the
# controller-owned praxis plugins ConfigMap `payload-processing-plugins` (data key
# extproc.yaml) with the `ai_guardrails` filter (praxis-ai promotion layer).
#
# This is the Praxis counterpart of ../ipp-guards/apply-guards.sh (IPP's
# nemo-request-guard / nemo-response-guard llm-d plugins). Praxis uses the BBR
# filter-chain format, so the guard is a chain filter, not a plugin/profile entry:
#
#     filter_chains:
#       - name: ipp
#         filters:
#           - filter: request_id
#           - filter: ai_guardrails          <-- added
#             provider:
#               type: nemo
#               endpoint: <NeMo /v1/guardrail/checks URL>
#               guardrails: {config_ids: [...]}
#               timeout_ms: 10000
#             phase: {request: true, response: false}
#
# Idempotent: removes any prior ai_guardrails filter first, then re-adds it, so
# re-running restores the guard after AGC's drift correction reverts the ConfigMap
# (AGC SSA-applies this CM with its own field owner on every reconcile — the
# ~5m resync reverts the DATA, but the running extproc keeps its loaded config
# until the next pod restart).
#
# KNOWN LIMIT (see README): the deployed praxis-ai maps NeMo's /v1/checks status
# "passed" only; the real TrustyAI NeMo returns "success" for pass, so safe
# requests fail closed until the praxis-ai verdict-mapping fix lands
# (upstream equivalent: ai-gateway-payload-processing#434).
#
# Requires: oc (logged in), yq (v4), jq.
set -euo pipefail

NS="${PRAXIS_NS:-openshift-ingress}"
CM="${PRAXIS_CM:-payload-processing-plugins}"
KEY="${PRAXIS_CM_KEY:-extproc.yaml}"
CHAIN="${PRAXIS_CHAIN:-ipp}"
DEPLOY="${PRAXIS_DEPLOY:-payload-processing}"
export NEMO_URL="${NEMO_URL:-https://nemo-guardrails-direct-nemo-guardrails.apps.prelude-m6wl4-bx7rc.sandbox1832.opentlc.com/v1/guardrail/checks}"
export NEMO_CONFIG_ID="${NEMO_CONFIG_ID:-llama-4-scout-17b-16e-w4a16}"
export TIMEOUT_MS="${NEMO_TIMEOUT_MS:-10000}"
export GUARD_REQUEST="${GUARD_REQUEST:-true}"
export GUARD_RESPONSE="${GUARD_RESPONSE:-false}"
RESTART="${RESTART:-true}"

for bin in oc yq jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not found in PATH." >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CFG="$WORK/extproc.yaml"

echo "==> Reading $CM/$KEY (ns=$NS)"
oc get configmap "$CM" -n "$NS" -o jsonpath="{.data.$(echo "$KEY" | sed 's/\./\\./g')}" > "$CFG"
if [[ ! -s "$CFG" ]]; then
  echo "ERROR: data key '$KEY' in ConfigMap '$CM' is empty or missing." >&2
  exit 1
fi

echo "==> Adding ai_guardrails filter to chain '$CHAIN' (idempotent)"
# 1) strip any prior ai_guardrails filter so the script is safe to re-run
yq -i 'del(.filter_chains[] | select(.name == strenv(CHAIN)).filters[] | select(.filter == "ai_guardrails"))' "$CFG"

# 2) build the filter block as a file (shell substitution keeps timeout_ms a number and
#    request/response booleans), then append with the parenthesized |= pattern, which
#    mutates in place WITHOUT destroying the rest of the document (a bare
#    `.filter_chains[] | ... .filters += x` pipeline would rewrite the file to just the chain).
#
# NOTE: the DEPLOYED praxis-ai (v0.8.0) nemo provider schema is
#   {endpoint, allow_private_endpoint, model, timeout_ms}
# — `guardrails.config_ids` exists only in praxis-ai HEAD (f60e31ce). Omitting config_ids
# makes NeMo use its default configuration (the rails loaded by its default config).
cat > "$WORK/guard-filter.yaml" <<EOF
filter: ai_guardrails
provider:
  type: nemo
  endpoint: ${NEMO_URL}
  timeout_ms: ${TIMEOUT_MS}
phase:
  request: ${GUARD_REQUEST}
  response: ${GUARD_RESPONSE}
EOF
FILTER_FILE="$WORK/guard-filter.yaml" CHAIN="$CHAIN" yq -i '(.filter_chains[] | select(.name == strenv(CHAIN)).filters) |= (. + (load(strenv(FILTER_FILE))))' "$CFG"

echo "==> Resulting chain '$CHAIN':"
yq '.filter_chains[] | select(.name == strenv(CHAIN))' "$CFG" | sed 's/^/    /'

echo "==> Applying back to $CM (preserving all other keys + annotations)"
oc get configmap "$CM" -n "$NS" -o json \
  | jq --arg key "$KEY" --rawfile newcfg "$CFG" '.data[$key] = $newcfg' \
  | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .status)' \
  | oc apply -f -

if [[ "$RESTART" == "true" ]]; then
  echo "==> Restarting deploy/$DEPLOY (extproc loads its config at startup)"
  oc rollout restart "deploy/$DEPLOY" -n "$NS"
  oc rollout status  "deploy/$DEPLOY" -n "$NS" --timeout=180s
fi

echo "==> Verifying the ai_guardrails filter survived"
POST="$(timeout 30 oc get configmap "$CM" -n "$NS" -o jsonpath="{.data.$(echo "$KEY" | sed 's/\./\\./g')}" 2>/dev/null)"
ok=1
grep -q "filter: ai_guardrails" <<<"$POST" || { echo "  MISSING: ai_guardrails filter" >&2; ok=0; }
grep -q "type: nemo"            <<<"$POST" || { echo "  MISSING: nemo provider"      >&2; ok=0; }
if [[ "$ok" == 1 ]]; then
  echo "==> Done. ai_guardrails is wired into chain '$CHAIN'."
else
  echo "ERROR: post-apply verification failed (AGC may have reverted the ConfigMap — re-run)." >&2
  exit 1
fi
