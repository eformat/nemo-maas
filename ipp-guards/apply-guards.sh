#!/usr/bin/env bash
#
# Part B — enable NeMo guard plugins for the OTHER MaaS models by patching the operator-owned
# IPP ConfigMap `payload-processing-plugins` (data key custom-ipp-config.yaml).
#
# Idempotent: removes any prior nemo-input/nemo-output entries first, then re-adds them, so
# re-running restores the guards after an operator re-template. Only the custom-ipp-config.yaml
# key is touched; all other keys/annotations (incl. opendatahub.io/managed:"false") are preserved.
#
# Requires: oc (logged in), yq (v4), jq.
set -euo pipefail

NS="${IPP_NS:-openshift-ingress}"
CM="${IPP_CM:-payload-processing-plugins}"
KEY="${IPP_CM_KEY:-custom-ipp-config.yaml}"
DEPLOY="${IPP_DEPLOY:-payload-processing}"
PROFILE="${IPP_PROFILE:-default}"
export NEMO_URL="${NEMO_URL:-http://nemo-guardrails-direct.nemo-guardrails.svc.cluster.local:443/v1/guardrail/checks}"
export TIMEOUT_SECONDS="${NEMO_TIMEOUT_SECONDS:-10}"

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

echo "==> Merging nemo-input / nemo-output (idempotent)"
# 1) strip any prior nemo entries (defs + refs) so the script is safe to re-run
yq -i 'del(.plugins[] | select(.name == "nemo-input" or .name == "nemo-output"))' "$CFG"
yq -i 'del(.profiles[].plugins.request[]  | select(.pluginRef == "nemo-input"))'  "$CFG"
yq -i 'del(.profiles[].plugins.response[] | select(.pluginRef == "nemo-output"))' "$CFG"

# 2) append the two plugin definitions
yq -i '
  .plugins += [
    {"type": "nemo-request-guard",  "name": "nemo-input",  "parameters": {"nemoURL": strenv(NEMO_URL), "timeoutSeconds": env(TIMEOUT_SECONDS)}},
    {"type": "nemo-response-guard", "name": "nemo-output", "parameters": {"nemoURL": strenv(NEMO_URL), "timeoutSeconds": env(TIMEOUT_SECONDS)}}
  ]
' "$CFG"

# 3) wire refs into the default profile: input rails first, output rail on the response chain
PROFILE="$PROFILE" yq -i '
  (.profiles[] | select(.name == strenv(PROFILE)).plugins.request)  |= ([{"pluginRef": "nemo-input"}] + .)
' "$CFG"
PROFILE="$PROFILE" yq -i '
  (.profiles[] | select(.name == strenv(PROFILE)).plugins.response) |= ((. // []) + [{"pluginRef": "nemo-output"}])
' "$CFG"

echo "==> Resulting default profile:"
yq '.profiles[] | select(.name == strenv(PROFILE))' "$CFG" | sed 's/^/    /'

echo "==> Applying back to $CM (preserving all other keys + annotations)"
oc get configmap "$CM" -n "$NS" -o json \
  | jq --arg key "$KEY" --rawfile newcfg "$CFG" '.data[$key] = $newcfg' \
  | jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields, .status)' \
  | oc apply -f -

NEMO_NS="${NEMO_NS:-nemo-guardrails}"
echo "==> Patching DestinationRule TLS mode to DISABLE (NeMo serves plain HTTP)"
DR="$(oc get destinationrule -n "$NEMO_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [[ -n "$DR" ]]; then
  oc patch destinationrule "$DR" -n "$NEMO_NS" --type=merge \
    -p '{"spec":{"trafficPolicy":{"tls":{"mode":"DISABLE"}}}}' 2>&1
else
  echo "  WARNING: no DestinationRule found in $NEMO_NS — skip TLS patch"
fi

echo "==> Restarting deploy/$DEPLOY"
oc rollout restart "deploy/$DEPLOY" -n "$NS"
oc rollout status  "deploy/$DEPLOY" -n "$NS" --timeout=180s

echo "==> Verifying the nemo entries survived"
POST="$(oc get configmap "$CM" -n "$NS" -o jsonpath="{.data.$(echo "$KEY" | sed 's/\./\\./g')}")"
ok=1
grep -q "name: nemo-input"  <<<"$POST" || { echo "  MISSING: nemo-input plugin def"  >&2; ok=0; }
grep -q "name: nemo-output" <<<"$POST" || { echo "  MISSING: nemo-output plugin def" >&2; ok=0; }
grep -q "pluginRef: nemo-input"  <<<"$POST" || { echo "  MISSING: nemo-input ref"  >&2; ok=0; }
grep -q "pluginRef: nemo-output" <<<"$POST" || { echo "  MISSING: nemo-output ref" >&2; ok=0; }
if [[ "$ok" == 1 ]]; then
  echo "==> Done. NeMo guards are wired into the '$PROFILE' profile."
else
  echo "ERROR: post-apply verification failed (operator may have reverted the ConfigMap)." >&2
  exit 1
fi
