# Part B — NeMo guards as inline rails for other MaaS models

This enables `nemo-request-guard` / `nemo-response-guard` on IPP so that **every** request to the
other MaaS models is checked by NeMo (`/v1/guardrail/checks`) before it reaches the backend, and the
response is checked before it returns to the caller.

## Why this is out-of-band (not kustomize)

The plugin list lives in the ConfigMap **`payload-processing-plugins`** (namespace
**`openshift-ingress`**, data key **`custom-ipp-config.yaml`**), which is rendered and owned by
`maas-controller`. It is annotated `opendatahub.io/managed: "false"`, so manual edits are *expected*
to persist — but there is **no supported CR field** to declare these plugins, and the ConfigMap is
not ours to create. So we patch it in place with `apply-guards.sh` instead of putting it in the
kustomize graph.

The guard plugins are already **compiled into the shipped IPP image**, so this is config-only — no
rebuild.

## Usage

```bash
# defaults target ns=openshift-ingress, cm=payload-processing-plugins, deploy=payload-processing
./apply-guards.sh
```

Override via env if your cluster differs:

```bash
NEMO_URL="http://<svc>.<ns>.svc.cluster.local:8000/v1/guardrail/checks" \
IPP_NS=openshift-ingress IPP_DEPLOY=payload-processing \
./apply-guards.sh
```

The script:
1. reads the live `custom-ipp-config.yaml`,
2. removes any prior `nemo-input` / `nemo-output` entries (so re-runs are idempotent),
3. adds the two plugin definitions,
4. prepends `nemo-input` to the default profile's `request` chain (input rails run **before**
   `model-provider-resolver`) and appends `nemo-output` to the `response` chain,
5. applies back **only** that data key (all other keys + annotations preserved),
6. `rollout restart`s the deployment, and
7. asserts the entries survived (guards against operator reversion).

## Response-guard prerequisite (ext_proc)

`nemo-response-guard` only runs if Envoy forwards response bodies to IPP. The ext_proc config needs
`response_body_mode: FULL_DUPLEX_STREAMED` and `response_header_mode: SEND`. On this cluster the
`payload-processing` EnvoyFilter (ns `openshift-ingress`) already contains a patch with that mode.
Verify with:

```bash
oc get envoyfilter payload-processing -n openshift-ingress -o yaml \
  | grep -iE "response_body_mode|response_header_mode"
```

If the effective route only shows `response_body_mode: NONE`, the response guard will silently skip
output checks — reconcile the EnvoyFilter (see `bbr-fixes.yaml` in the payload-processing chart).

## Caveat — not upgrade-safe

A `maas-controller` / RHOAI upgrade may re-template the ConfigMap and drop the guards. Re-run
`apply-guards.sh` to restore. The supported long-term fix is an odh-maas-controller change to
template these plugins.

## Revert

```bash
# remove the guards and restart
oc get configmap payload-processing-plugins -n openshift-ingress -o json \
  | jq --rawfile c <(oc get configmap payload-processing-plugins -n openshift-ingress \
        -o jsonpath='{.data.custom-ipp-config\.yaml}' \
        | yq 'del(.plugins[] | select(.name=="nemo-input" or .name=="nemo-output"))
              | del(.profiles[].plugins.request[]  | select(.pluginRef=="nemo-input"))
              | del(.profiles[].plugins.response[] | select(.pluginRef=="nemo-output"))') \
      '.data["custom-ipp-config.yaml"]=$c' \
  | jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp,.metadata.managedFields,.status)' \
  | oc apply -f -
oc rollout restart deploy/payload-processing -n openshift-ingress
```
