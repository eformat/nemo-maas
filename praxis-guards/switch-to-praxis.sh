#!/usr/bin/env bash
#
# Part C step 1 — switch a tenant's dataplane from IPP to PRAXIS.
#
# Sets maas.opendatahub.io/payload-processing-type=praxis on the MaasTenantConfig, then polls the
# race-free handoff (maas-controller deletes the IPP operands and writes payload-processing-status=
# cleanup-complete; ai-gateway-controller CAS-claims it to steady and applies the per-tenant
# praxis-extproc) until the status annotation reads steady and the praxis payload-processing
# Deployment is Ready.
#
# Optionally chains ../praxis-guards/apply-guards.sh to wire the Nemo guardrails (CHAIN_GUARDS=true).
#
# Verified on prelude2 2026-10-26. Rollback: ./switch-to-ipp.sh
#
# Requires: oc (logged in), jq.
set -euo pipefail

MTC_NS="${MTC_NS:-models-as-a-service}"
MTC_NAME="${MTC_NAME:-default-tenant}"
TIMEOUT="${TIMEOUT:-600}"          # seconds to wait for the handshake
POLL="${POLL:-5}"                  # seconds between polls
CHAIN_GUARDS="${CHAIN_GUARDS:-false}"
GUARD_DIR="$(cd "$(dirname "$0")" && pwd)"

for bin in oc jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not found in PATH." >&2; exit 1; }
done

status() {
  timeout 30 oc get maastenantconfig "$MTC_NAME" -n "$MTC_NS" \
    -o jsonpath='{.metadata.annotations.maas\.opendatahub\.io/payload-processing-status}' 2>/dev/null || echo ""
}

echo "==> Annotating $MTC_NS/$MTC_NAME payload-processing-type=praxis"
oc annotate maastenantconfig "$MTC_NAME" -n "$MTC_NS" \
  maas.opendatahub.io/payload-processing-type=praxis --overwrite

echo "==> Polling the handoff (status: absent -> cleanup-complete -> steady) up to ${TIMEOUT}s"
elapsed=0
while (( elapsed < TIMEOUT )); do
  s="$(status)"
  deps_ready="$(timeout 30 oc get deploy payload-processing -n "${PRAXIS_NS:-openshift-ingress}" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")"
  info_line="status=${s:-absent}  payload-processing Available=${deps_ready:-absent}"
  printf '\r  %s' "$info_line"
  if [[ "$s" == "steady" && "$deps_ready" == "True" ]]; then
    echo
    echo "==> Handoff complete: praxis dataplane is live (status=steady)."
    break
  fi
  sleep "$POLL"; elapsed=$((elapsed + POLL))
done

if [[ "$s" != "steady" || "$deps_ready" != "True" ]]; then
  echo
  echo "ERROR: handshake did not reach steady within ${TIMEOUT}s (last: $info_line)." >&2
  echo "  Check: oc logs deploy/maas-controller -n redhat-ods-applications | grep -i payload" >&2
  echo "         oc logs deploy/ai-gateway-controller -n redhat-ods-applications | grep -i praxis" >&2
  exit 1
fi

if [[ "$CHAIN_GUARDS" == "true" ]]; then
  echo "==> Chaining apply-guards.sh (Nemo guardrails)"
  "$GUARD_DIR/apply-guards.sh"
else
  echo "==> Next step: ./apply-guards.sh (or CHAIN_GUARDS=true $0)"
fi
