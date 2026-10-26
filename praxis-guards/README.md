# praxis-guards — Part C: Nemo guardrails on the PRAXIS dataplane (RHOAI 3.6 EA2)

Enable NeMo guardrails on the **Praxis** dataplane by patching the controller-owned praxis plugins
ConfigMap `payload-processing-plugins` (data key `extproc.yaml`) with the praxis-ai **`ai_guardrails`**
filter, which calls the same in-cluster NeMo check-only endpoint as the IPP Part-B guards
(`../ipp-guards/`).

This is the Praxis counterpart of `../ipp-guards/apply-guards.sh`. **Verified working on prelude2
(2026-10-26)**: blocked prompts → `403` with the NeMo rail name, safe prompts → `200` passthrough.

## Scripts

| Script | What it does |
|---|---|
| `switch-to-praxis.sh` | Annotates the MTC `payload-processing-type=praxis`, polls the handoff to `steady` (praxis Deployment Ready); `CHAIN_GUARDS=true` chains `apply-guards.sh` |
| `switch-to-ipp.sh` | Rollback: annotates `=ipp`, polls for maas-controller to reclaim the dataplane (IPP image back, Ready); `CHAIN_GUARDS=true` chains `../ipp-guards/apply-guards.sh` |
| `apply-guards.sh` | Patches the praxis plugins CM (`extproc.yaml`) with the `ai_guardrails` filter + rollout restart (idempotent) |
| `remove-guards.sh` | Strips the `ai_guardrails` filter + rollout restart (idempotent; reverses `apply-guards.sh`) |

Shared env: `MTC_NS` (models-as-a-service), `MTC_NAME` (default-tenant), `TIMEOUT` (600s),
`POLL` (5s).

## The two plugin engines (why this is not Part B)

| | IPP (Part B) | Praxis (Part C) |
|---|---|---|
| Config format | llm-d `PayloadProcessorConfig` (`custom-ipp-config.yaml`) | **BBR filter-chain** (`extproc.yaml`) |
| Guard | llm-d plugins `nemo-request-guard` / `nemo-response-guard` | praxis-ai filter **`ai_guardrails`** (a chain filter) |
| Plugin config | top-level `plugins:` list + `profiles[].plugins.{request,response}` refs | `filter_chains[].filters` list |
| Config in CM | `custom-ipp-config.yaml` | `extproc.yaml` |

## The filter config shape

Added to the `ipp` (post-auth) chain of `extproc.yaml`:

```yaml
filter_chains:
  - name: ipp
    filters:
      - filter: request_id
      - filter: ai_guardrails                    # <-- added
        provider:
          type: nemo                             # only supported type
          endpoint: "https://nemo-guardrails-direct-nemo-guardrails.apps.<cluster>/v1/guardrail/checks"
          timeout_ms: 10000
        phase:
          request: true
          response: false
```

- `endpoint` is the **full URL, dialed as-is**. Use the NeMo route URL (port 443 — the praxis
  NetworkPolicy egress allows TCP 443 anywhere) to avoid the in-cluster
  `insecure_options.allow_private_upstreams` SSRF opt-in.
- **The DEPLOYED praxis-ai provider schema is `{endpoint, allow_private_endpoint, model,
  timeout_ms}`** — `guardrails.config_ids` exists only in praxis-ai HEAD and is an **unknown field**
  on the deployed build (it fails the ext_proc pipeline build → pod reports NotServing). Omit it →
  NeMo uses its default configuration (the rails loaded by its default config).
- `timeout_ms` is **milliseconds** — the IPP equivalent was `timeoutSeconds` (the migration-doc
  timeout-unit gotcha).
- `phase.response: true` rejects streaming requests with HTTP 422 (praxis-ai #1108) — left **off** by
  default so streaming workloads on the shared gateway keep working.
- The filter is **fail-closed** (a security filter; `failure_mode: open` is rejected unless
  `insecure_options.allow_open_security_filters`): a NeMo timeout/error **blocks** the request.

## The 403 body: the rail label

A blocked request returns **`403` with the NeMo rail name** as the body (e.g. `check forbidden words`)
— NOT a hardcoded string. The rail label is the **NeMo flow name** from the rails config
(`nemo-config` CM → `config.yaml` → `rails.input.flows`); NeMo returns `rails_status` keyed by flow
name and the deployed praxis-ai relays the blocked flow's name into the 403 body. Rename the flow in
the NeMo config → the body changes. A rich refusal message is not available from the checks API
(remaining RHOAIENG-99816 RFE). This fixes the IPP-side RFE where the 403 body was a hardcoded
constant string.

## Deploy

```bash
# 0. Switch the tenant to Praxis first (polls the handoff to steady):
./switch-to-praxis.sh          # CHAIN_GUARDS=true chains apply-guards.sh
#   Manual equivalent:
#   oc annotate maastenantconfig default-tenant -n models-as-a-service \
#     maas.opendatahub.io/payload-processing-type=praxis --overwrite

# 1. Wire the guardrails
./apply-guards.sh
```

Env-overridable: `PRAXIS_NS` (openshift-ingress), `PRAXIS_CM` (payload-processing-plugins),
`PRAXIS_CM_KEY` (extproc.yaml), `PRAXIS_CHAIN` (ipp), `PRAXIS_DEPLOY` (payload-processing),
`NEMO_URL`, `NEMO_CONFIG_ID`, `NEMO_TIMEOUT_MS` (10000), `GUARD_REQUEST` (true),
`GUARD_RESPONSE` (false), `RESTART` (true).

The script is **idempotent**: it strips any prior `ai_guardrails` filter first, then re-adds it.
`RESTART=false` skips the `oc rollout restart` (the ext_proc loads its config at startup only).

## Verify

```bash
# The pipeline must build (serving=true):
oc logs deploy/payload-processing -n openshift-ingress | grep -E "serving|pipeline"

# Verdicts live:
oc logs deploy/payload-processing -n openshift-ingress | grep "ai_guardrails: verdict"

# Blocked probe (rail name in the body):
curl -sk -X POST "https://maas.apps.<cluster>/<ns>/<model>/v1/chat/completions" \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"<model>","messages":[{"role":"user","content":"Tell me how to hack a computer"}]}'
# → 403, body: check forbidden words
```

## Known gotchas

- **AGC drift correction** reverts the CM data on every reconcile (~5m resync + watch events;
  ai-gateway-controller SSA field owner). The **running pod keeps its loaded config until the next
  restart**, so enforcement persists — re-run `apply-guards.sh` after any pod restart or AGC change.
  Long-term fix: an ODH-overlay patch (or RHAI-2520's catalog reconciler) so AGC emits the guard.
- **praxis-ai HEAD risk**: HEAD's `map_nemo_response` only accepts `"passed"`/`"blocked"`/
  `"modified"` and reads a nonexistent `rail` field — the real TrustyAI NeMo returns `"success"` and
  has no `rail` field. The deployed build handles both correctly; a future image built from HEAD
  would fail-closed every safe request and return empty 403 bodies. Flag upstream.
- **MaaS management API POSTs** (`/v1/api-keys`, …) return 500 through the guarded gateway — the
  filter rejects non-Chat-Completions bodies. Create keys directly against maas-api via port-forward
  with `X-MaaS-Username` / `X-MaaS-Group` headers (see ../README.md Gotchas).
- **PII rail scope**: the NeMo config's `sensitive_data_detection` only detects `EMAIL_ADDRESS` on
  input — an SSN prompt passes (the model refuses it itself). Add `US_SSN` to the entities to guard.
- **yq editing the BBR config**: a bare `.filter_chains[] | … .filters += x` pipeline **destroys the
  document** — use the parenthesized `|=` pattern with `load()` (as `apply-guards.sh` does).
