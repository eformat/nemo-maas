#!/usr/bin/env bash
#
# Part C rollback — switch a tenant's dataplane from PRAXIS back to IPP.
#
# Sets maas.opendatahub.io/payload-processing-type=ipp on the MaasTenantConfig, then polls until
# maas-controller has reclaimed the dataplane: ai-gateway-controller cleans up the praxis resources
# and writes payload-processing-status=cleanup-complete; maas-controller CAS-claims it to absent and
# redeploys the legacy IPP operands.
#
# Optionally chains ../ipp-guards/apply-guards.sh to restore the Part-B Nemo wiring on IPP
# (CHAIN_GUARDS=true) — the IPP plugins ConfigMap maas-controller recreates is product-default.
#
# Verified shape on prelude2. Forward: ./switch-to-praxis.sh
#
# Requires: oc (logged in), jq.
set -euo pipefail

MTC_NS="${MTC_NS:-models-as-a-service}"
MTC_NAME="${MTC_NAME:-default-tenant}"
TIMEOUT="${TIMEOUT:-600}"
POLL="${POLL:-5}"
CHAIN_GUARDS="${CHAIN_GUARDS:-false}"
IPP_GUARD_DIR="$(cd "$(dirname "$0")/../ipp-guards" && pwd)"

for bin in oc jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not found in PATH." >&2; exit 1; }
done

status() {
  timeout 30 oc get maastenantconfig "$MTC_NAME" -n "$MTC_NS" \
    -o jsonpath='{.metadata.annotations.maas\.opendatahub\.io/payload-processing-status}' 2>/dev/null || echo ""
}

echo "==> Annotating $MTC_NS/$MTC_NAME payload-processing-type=ipp"
oc annotate maastenantconfig "$MTC_NAME" -n "$MTC_NS" \
  maas.opendatahub.io/payload-processing-type=ipp --overwrite

echo "==> Polling for maas-controller to reclaim the dataplane (IPP Deployment back) up to ${TIMEOUT}s"
elapsed=0
while (( elapsed < TIMEOUT )); do
  s="$(status)"
  dep_image="$(timeout 30 oc get deploy payload-processing -n "${IPP_NS:-openshift-ingress}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")"
  case "$dep_image" in
    *payload-processing*|*"ai-gateway-payload-processing"*)
      # The legacy IPP image is back (praxis-extproc uses odh-praxis-extproc-*).
      deps_ready="$(timeout 30 oc get deploy payload-processing -n "${IPP_NS:-openshift-ingress}" \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")"
      printf '\r  status=%s  image=%s  Available=%s' "${s:-absent}" "${dep_image:0:60}" "${deps_ready:-absent}"
      if [[ "$deps_ready" == "True" && "$s" != "steady" ]]; then
        echo
        echo "==> Rollback complete: legacy IPP dataplane is live."
        break
      fi
      ;;
    *)
      printf '\r  status=%s  image=%s' "${s:-absent}" "${dep_image:0:40}"
      ;;
  esac
  sleep "$POLL"; elapsed=$((elapsed + POLL))
done

s="$(status)"
dep_image="$(timeout 30 oc get deploy payload-processing -n "${IPP_NS:-openshift-ingress}" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")"
if [[ "$dep_image" == *praxis-extproc* || "$s" == "steady" ]]; then
  echo
  echo "ERROR: the Praxis dataplane is still live after ${TIMEOUT}s (image=${dep_image:0:60} status=${s:-absent})." >&2
  echo "  Check: oc logs deploy/ai-gateway-controller -n redhat-ods-applications | grep -i praxis" >&2
  echo "         oc logs deploy/maas-controller -n redhat-ods-applications | grep -i payload" >&2
  exit 1
fi

if [[ "$CHAIN_GUARDS" == "true" ]]; then
  echo "==> Chaining ipp-guards/apply-guards.sh (restore the Part-B Nemo wiring)"
  "$IPP_GUARD_DIR/apply-guards.sh"
else
  echo "==> Next step: ../ipp-guards/apply-guards.sh (or CHAIN_GUARDS=true $0)"
fi
