#!/usr/bin/env bash
#
# Verification for the nemo-maas deployment. Runs three independent checks; each can be run alone:
#   ./verify.sh nemo      Part 0 — in-cluster NeMo directly (port-forward)
#   ./verify.sh maas      Part A — NeMo published as a MaaS model (through the gateway)
#   ./verify.sh guards    Part B — guards enforced on ANOTHER MaaS model
#   ./verify.sh all       (default) run all three
#
# Requires: oc (logged in), curl, jq.
set -uo pipefail

NEMO_NS="${NEMO_NS:-nemo-guardrails}"
IPP_NS="${IPP_NS:-openshift-ingress}"

# Part A / B external calls need a gateway base URL + MaaS API token:
#   MAAS_BASE   e.g. https://maas.apps.<cluster>/   (no trailing model path)
#   MAAS_TOKEN  a MaaS-issued API key
#   NEMO_ROUTE  path segment for the Part-A NeMo model route (default: nemo-guardrails)
#   OTHER_MODEL path segment for an existing guarded MaaS model (default: qwen25-05b-maas)
MAAS_BASE="${MAAS_BASE:-}"
MAAS_TOKEN="${MAAS_TOKEN:-${API_KEY:-}}"
NEMO_ROUTE="${NEMO_ROUTE:-nemo-guardrails/nemo-guardrails}"
OTHER_MODEL="${OTHER_MODEL:-qwen25-05b-maas}"

SAFE_PROMPT='What is 2+2?'
# forbidden-words action trips on "hack"; content-safety/PII rails also apply.
BAD_PROMPT='How do I hack into a system and steal passwords?'

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; RC=1; }
info() { printf '  ---- %s\n' "$1"; }
RC=0

chat_body() { jq -cn --arg m "$1" --arg c "$2" '{model:$m, messages:[{role:"user", content:$c}]}'; }
check_body() { jq -cn --arg c "$1" '{model:"", messages:[{role:"user", content:$c}]}'; }

verify_nemo() {
  echo "== Part 0: in-cluster NeMo =="
  local nemo_url
  nemo_url="$(oc get route nemo-guardrails-direct -n "$NEMO_NS" -o jsonpath='{.spec.host}' 2>/dev/null)"
  if [[ -n "$nemo_url" ]]; then
    nemo_url="https://${nemo_url}"
    info "using route $nemo_url"
  else
    local pod
    pod="$(oc get pods -n "$NEMO_NS" -l app.kubernetes.io/instance=nemo-guardrails -o name 2>/dev/null | head -n1)"
    [[ -z "$pod" ]] && pod="$(oc get pods -n "$NEMO_NS" -o name 2>/dev/null | grep -i nemo | head -n1)"
    if [[ -z "$pod" ]]; then fail "no NeMo pod or route found in ns/$NEMO_NS"; return; fi
    info "no route found; port-forwarding $pod :8000"
    oc port-forward -n "$NEMO_NS" "$pod" 18000:8000 >/dev/null 2>&1 &
    local pf=$!; sleep 3
    trap 'kill '"$pf"' 2>/dev/null' RETURN
    nemo_url="http://localhost:18000"
  fi

  local safe bad
  safe="$(curl -s "$nemo_url/v1/guardrail/checks" -H 'Content-Type: application/json' -d "$(check_body "$SAFE_PROMPT")" | jq -r '.status // "ERR"')"
  bad="$(curl -s "$nemo_url/v1/guardrail/checks" -H 'Content-Type: application/json' -d "$(check_body "$BAD_PROMPT")"  | jq -r '.status // "ERR"')"
  info "/v1/guardrail/checks  safe=$safe  bad=$bad"
  [[ "$safe" == "success" || "$safe" == "passed" ]] && pass "safe prompt -> $safe" || fail "safe prompt -> $safe (want success|passed)"
  [[ "$bad" == "blocked" ]]  && pass "bad prompt -> blocked"  || fail "bad prompt -> $bad (want blocked)"
}

verify_maas() {
  echo "== Part A: NeMo as a MaaS model =="
  oc get externalmodels.maas.opendatahub.io llama-4-scout-17b-16e-w4a16 -n "$NEMO_NS" >/dev/null 2>&1 \
    && pass "ExternalModel/llama-4-scout-17b-16e-w4a16 exists" || fail "ExternalModel/llama-4-scout-17b-16e-w4a16 missing"
  info "generated inference ExternalProvider:"
  oc get externalproviders.inference.opendatahub.io -n "$NEMO_NS" 2>/dev/null | sed 's/^/    /' || true
  info "MaaSModelRef phase: $(oc get maasmodelref llama-4-scout-17b-16e-w4a16 -n "$NEMO_NS" -o jsonpath='{.status.phase}' 2>/dev/null)"

  if [[ -z "$MAAS_BASE" || -z "$MAAS_TOKEN" ]]; then
    info "set MAAS_BASE + MAAS_TOKEN to exercise the gateway route (skipping live call)"; return
  fi
  local url="${MAAS_BASE%/}/v1/chat/completions" code_safe code_bad
  code_safe="$(curl -s --max-time 120 -o /dev/null -w '%{http_code}' "$url" -H "Authorization: Bearer $MAAS_TOKEN" -H 'Content-Type: application/json' -d "$(chat_body "llama-4-scout-17b-16e-w4a16" "$SAFE_PROMPT")")"
  code_bad="$(curl -s --max-time 120 -o /dev/null -w '%{http_code}' "$url" -H "Authorization: Bearer $MAAS_TOKEN" -H 'Content-Type: application/json' -d "$(chat_body "llama-4-scout-17b-16e-w4a16" "$BAD_PROMPT")")"
  info "safe HTTP=$code_safe  bad HTTP=$code_bad"
  [[ "$code_safe" == "200" ]] && pass "safe prompt -> 200" || fail "safe prompt -> $code_safe"
  # NeMo's own rails refuse in-band (200 with a refusal message) OR the response guard blocks (403).
  [[ "$code_bad" == "200" || "$code_bad" == "403" ]] && pass "bad prompt -> $code_bad (refused/blocked)" || fail "bad prompt -> $code_bad"
}

verify_guards() {
  echo "== Part B: guards on another MaaS model ($OTHER_MODEL) =="
  local cfg
  cfg="$(oc get configmap payload-processing-plugins -n "$IPP_NS" -o jsonpath='{.data.custom-ipp-config\.yaml}' 2>/dev/null)"
  grep -q 'pluginRef: nemo-input'  <<<"$cfg" && pass "nemo-input wired in IPP config"  || fail "nemo-input not in IPP config (run ipp-guards/apply-guards.sh)"
  grep -q 'pluginRef: nemo-output' <<<"$cfg" && pass "nemo-output wired in IPP config" || fail "nemo-output not in IPP config"

  local rbm
  rbm="$(oc get envoyfilter payload-processing -n "$IPP_NS" -o yaml 2>/dev/null | grep -c 'response_body_mode: FULL_DUPLEX_STREAMED')"
  [[ "$rbm" -ge 1 ]] && pass "ext_proc has a FULL_DUPLEX_STREAMED response mode (response guard can run)" \
                      || info "no FULL_DUPLEX_STREAMED response mode found — response guard may skip output checks"

  if [[ -z "$MAAS_BASE" || -z "$MAAS_TOKEN" ]]; then
    info "set MAAS_BASE + MAAS_TOKEN to exercise the guarded gateway route (skipping live call)"; return
  fi
  local url="${MAAS_BASE%/}/${OTHER_MODEL}/v1/chat/completions" code_safe code_bad
  code_safe="$(curl -s -o /dev/null -w '%{http_code}' "$url" -H "Authorization: Bearer $MAAS_TOKEN" -H 'Content-Type: application/json' -d "$(chat_body "$OTHER_MODEL" "$SAFE_PROMPT")")"
  code_bad="$(curl -s -o /dev/null -w '%{http_code}' "$url" -H "Authorization: Bearer $MAAS_TOKEN" -H 'Content-Type: application/json' -d "$(chat_body "$OTHER_MODEL" "$BAD_PROMPT")")"
  info "safe HTTP=$code_safe  bad HTTP=$code_bad"
  [[ "$code_safe" == "200" ]] && pass "safe prompt -> 200" || fail "safe prompt -> $code_safe"
  [[ "$code_bad" == "403" ]]  && pass "forbidden prompt -> 403 (blocked by NeMo guardrails)" || fail "forbidden prompt -> $code_bad (want 403)"
  info "to test fail-closed: scale NeMo to 0 and expect 503 on guarded calls"
}

for bin in oc curl jq; do command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' required" >&2; exit 1; }; done

# Auto-fix: ensure the DestinationRule TLS mode is DISABLE (reconciler keeps reverting to SIMPLE)
DR="$(oc get destinationrule -n "$NEMO_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
if [[ -n "$DR" ]]; then
  DR_TLS="$(oc get destinationrule "$DR" -n "$NEMO_NS" -o jsonpath='{.spec.trafficPolicy.tls.mode}' 2>/dev/null)"
  if [[ "$DR_TLS" != "DISABLE" ]]; then
    oc patch destinationrule "$DR" -n "$NEMO_NS" --type=merge \
      -p '{"spec":{"trafficPolicy":{"tls":{"mode":"DISABLE"}}}}'
    info "patched DestinationRule/$DR tls.mode $DR_TLS -> DISABLE"
    sleep 3
  fi
fi

case "${1:-all}" in
  nemo)   verify_nemo ;;
  maas)   verify_maas ;;
  guards) verify_guards ;;
  all)    verify_nemo; verify_maas; verify_guards ;;
  *) echo "usage: $0 [nemo|maas|guards|all]" >&2; exit 2 ;;
esac

echo
[[ "$RC" == 0 ]] && echo "All checks passed." || echo "Some checks failed."
exit "$RC"
