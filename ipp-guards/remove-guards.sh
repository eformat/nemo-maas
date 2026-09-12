#!/usr/bin/env bash
#
# Deactivate Part B — remove NeMo guard plugins from the IPP ConfigMap.
# Reverses what apply-guards.sh does. Idempotent: safe to re-run.
#
# Requires: oc (logged in), yq (v4), jq.
set -euo pipefail

NS="${IPP_NS:-openshift-ingress}"
CM="${IPP_CM:-payload-processing-plugins}"
KEY="${IPP_CM_KEY:-custom-ipp-config.yaml}"
DEPLOY="${IPP_DEPLOY:-payload-processing}"

for bin in oc yq jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not found in PATH." >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CFG="$WORK/custom-ipp-config.yaml"

echo "==> Reading $CM/$KEY (ns=$NS)"
oc get configmap "$CM" -n "$NS" -o jsonpath="{.data.$(echo "$KEY" | sed 's/\./\\./g')}" > "$CFG"
if [[ ! -s "$CFG" ]]; then
  echo "ERROR: data key '$KEY' in ConfigMap '$CM' is empty or missing." >&2
  exit 1
fi

# Check if guards are present
if ! grep -q 'nemo-input\|nemo-output' "$CFG"; then
  echo "==> No nemo guards found in $CM/$KEY — nothing to remove."
  exit 0
fi

echo "==> Removing nemo-input / nemo-output plugin definitions and refs"
yq -i 'del(.plugins[] | select(.name == "nemo-input" or .name == "nemo-output"))' "$CFG"
yq -i 'del(.profiles[].plugins.request[]  | select(.pluginRef == "nemo-input"))'  "$CFG"
yq -i 'del(.profiles[].plugins.response[] | select(.pluginRef == "nemo-output"))' "$CFG"

echo "==> Applying back to $CM"
oc get configmap "$CM" -n "$NS" -o json \
  | jq --arg key "$KEY" --rawfile newcfg "$CFG" '.data[$key] = $newcfg' \
  | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .status)' \
  | oc apply -f -

echo "==> Restarting deploy/$DEPLOY"
oc rollout restart "deploy/$DEPLOY" -n "$NS"
oc rollout status  "deploy/$DEPLOY" -n "$NS" --timeout=180s

echo "==> Verifying removal"
POST="$(oc get configmap "$CM" -n "$NS" -o jsonpath="{.data.$(echo "$KEY" | sed 's/\./\\./g')}")"
ok=1
grep -q "nemo-input"  <<<"$POST" && { echo "  STILL PRESENT: nemo-input"  >&2; ok=0; } || true
grep -q "nemo-output" <<<"$POST" && { echo "  STILL PRESENT: nemo-output" >&2; ok=0; } || true
if [[ "$ok" == 1 ]]; then
  echo "==> Done. NeMo guards removed. All models should pass through without guardrail checks."
else
  echo "ERROR: removal verification failed." >&2
  exit 1
fi
