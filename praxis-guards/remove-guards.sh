#!/usr/bin/env bash
#
# Deactivate Part C — remove the ai_guardrails filter from the Praxis plugins ConfigMap.
# Reverses what apply-guards.sh does. Idempotent: safe to re-run.
#
# Requires: oc (logged in), yq (v4), jq.
set -euo pipefail

NS="${PRAXIS_NS:-openshift-ingress}"
CM="${PRAXIS_CM:-payload-processing-plugins}"
KEY="${PRAXIS_CM_KEY:-extproc.yaml}"
CHAIN="${PRAXIS_CHAIN:-ipp}"
DEPLOY="${PRAXIS_DEPLOY:-payload-processing}"

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

# Check if the guard is present
if ! grep -q 'ai_guardrails' "$CFG"; then
  echo "==> ai_guardrails not present in $CM/$KEY — nothing to do."
  exit 0
fi

echo "==> Removing the ai_guardrails filter from chain '$CHAIN'"
yq -i 'del(.filter_chains[] | select(.name == strenv(CHAIN)).filters[] | select(.filter == "ai_guardrails"))' "$CFG"

echo "==> Applying back to $CM (preserving all other keys + annotations)"
oc get configmap "$CM" -n "$NS" -o json \
  | jq --arg key "$KEY" --rawfile newcfg "$CFG" '.data[$key] = $newcfg' \
  | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .status)' \
  | oc apply -f -

echo "==> Restarting deploy/$DEPLOY (ext_proc loads its config at startup)"
oc rollout restart "deploy/$DEPLOY" -n "$NS"
oc rollout status  "deploy/$DEPLOY" -n "$NS" --timeout=180s

echo "==> Verifying the ai_guardrails filter is gone"
POST="$(timeout 30 oc get configmap "$CM" -n "$NS" -o jsonpath="{.data.$(echo "$KEY" | sed 's/\./\\./g')}" 2>/dev/null)"
if grep -q 'ai_guardrails' <<<"$POST"; then
  echo "ERROR: ai_guardrails still present (AGC may have re-applied a stale copy — re-run)." >&2
  exit 1
fi
echo "==> Done. Guardrails are unwired from chain '$CHAIN'."
