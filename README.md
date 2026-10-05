# local-ollama-workers

`local-ollama-workers` (LOW) publishes operator-owned local Ollama capacity
through WLO's provider-neutral `dynamic-worker-registry/v0.1` provider API.

> **Capability requests define exact runtime needs. LOW observes and publishes local workers.**

LOW does not schedule jobs, create WLO attempts, inject attempt endpoints,
manage paid capacity, or execute inference workloads. Ordinary registry
publication is observational: it must not start or restart Ollama, pull or load
models, warm a model, change runtime configuration, or run inference.

The authoritative contract and standalone conformance implementation are
WLO-owned at `contracts/dynamic-worker-registry/v0.1`. LOW retains a
byte-identical, explicitly non-authoritative copy under
`test/fixtures/dynamic-worker-registry-v0.1`, including WLO's SHA-256
manifest. Its ordinary tests run from a LOW checkout alone and load no WLO
runtime code. Optionally compare or refresh the copy from a sibling WLO
checkout with:

```bash
script/sync-dynamic-worker-registry-contract --check
script/sync-dynamic-worker-registry-contract --refresh
```

LOW is an independent publisher of the WLO API. It has no other provider,
AdventureFinder, or WLO runtime dependency. Ordinary publication requires no
external provenance or orchestration state.

## Current scope

LOW publishes one configured loopback Ollama worker only after an explicit
operator bootstrap has established every advertised capability for the current
concrete daemon generation.

- The logical worker ID remains stable across daemon restarts.
- The concrete `generation_id` is an opaque digest of kernel process
  incarnation evidence.
- Bootstrap first proves that the named model is already installed, then sends
  an empty-prompt, zero-token load request with the requested context. It never
  pulls a missing model.
- The loaded model identity, full digest, effective context, allocation size,
  and accelerator allocation size come from the machine-readable Ollama
  `/api/ps` response.
- `fully_gpu_resident` is true only when Ollama reports a positive runtime
  `size` and `size_vram == size`. Partial placement is recorded as false.
- `gpu_id` is the provider-neutral accelerator model and core count reported
  by macOS, such as `Apple M4 Pro 20-core GPU`. Serial numbers and local paths
  are neither read into evidence nor published.

Capability evidence is retained separately from registry publisher identity and
revision state. Use the public bootstrap/publication results to inspect it;
malformed evidence fails closed.

Evidence is bound to `worker_id`, `generation_id`, and endpoint. Restarting
or replacing Ollama changes the generation and immediately makes prior
evidence ineligible, even when the endpoint, model, and digest are unchanged.
Re-bootstrap the required model after a restart.

Several model records may be retained for one generation without keeping every
model loaded simultaneously. Ordinary publication rechecks the server version
and installed digest. If an evidenced model is currently loaded, its digest,
effective context, residency result, and allocation sizes must still match the
bootstrap observation; a changed runtime configuration cannot remain READY.

## Operator runbook

Run from the selected LOW checkout with its installed Ruby bundle. Use a
generic `ollama-capability-request/v0.1` document from the workload's approved
runtime requirements; do not send workload provenance or model aliases.
WLO owns the public [capability contract](https://github.com/dtnorris/workload-orchestrator/blob/main/contracts/ollama-capability-request/v0.1/README.md)
and [registry contract](https://github.com/dtnorris/workload-orchestrator/blob/main/contracts/dynamic-worker-registry/v0.1/README.md).
LOW needs neither WLO's runtime nor another provider's implementation to operate.

| Surface | Mutation classification |
| --- | --- |
| `ollama list`, `ollama ps`, API tags/ps | Read-only inspection |
| `low workers --json` | Observational publication; may retain local registry identity/revision, but changes no model or capacity |
| `low bootstrap --capability-request FILE --json` | Explicit local model load and capability-evidence preparation; no model pull or paid provider mutation |

LOW has no successful top-level `--help` mode: its usage is printed with exit 2
on an invalid command. Use the exact two public command forms below.

```bash
bin/low workers --json
```

The command emits exactly one JSON snapshot to stdout. It is observational: it
does not load or warm a model, run inference, pull a model, or change Ollama
configuration. With no eligible current-generation evidence it publishes an
empty `workers` array.

Inspect installed and loaded models without changing runtime state:

```bash
ollama list
ollama ps
curl --fail --silent --show-error http://127.0.0.1:11434/api/tags
curl --fail --silent --show-error http://127.0.0.1:11434/api/ps
```

Deliberately establish capability evidence for one already-installed model by
passing WLO's provider-neutral `ollama-capability-request/v0.1` document:

Set `CAPABILITY` to the exact approved generic request file.

```bash
bin/low bootstrap --capability-request "$CAPABILITY" --json
```

The request contains only exact Ollama runtime requirements: model identity,
full digest, context length, GPU residency, and optional GPU identity. Unknown
fields and legacy AdventureFinder envelopes are rejected. Installed-model and
GPU mismatches fail before preload; observed model, digest, context, residency,
or GPU mismatches prevent evidence persistence. LOW neither infers missing
provenance nor accepts aliases or digest prefixes.

Bootstrap records the context Ollama actually loaded and requires exact equality;
it never promotes, rounds, or substitutes a higher context.

Publisher and capability state default to
`~/.local/state/local-ollama-workers`. Set `LOW_STATE_ROOT` to select another
state directory. `LOW_WORKER_ID` and `LOW_OLLAMA_ENDPOINT` may override the
single logical worker ID and loopback endpoint.

LOW supplies a conforming local worker only after the exact requested model is
explicitly bootstrapped. It does not select or reinterpret requirements, schedule
work, or run the workload itself.

### Troubleshooting and lifecycle

An empty `workers` snapshot means no currently eligible evidenced generation,
not permission to infer readiness from an installed model. Inspect `ollama list`
and `ollama ps`, then run explicit bootstrap with the same exact request when
current-generation evidence is missing. After an Ollama restart, bootstrap again;
an old endpoint/model match does not establish the new generation.

Digest, context, residency or GPU mismatch belongs to LOW readiness validation.
Stop on its bootstrap diagnostic rather than editing evidence or relaxing the
request. Missing models require a separate deliberate installation; LOW never
pulls them. WLO placement/execution failures belong to the consumer's public
status/doctor surfaces. Stopping a publisher view does not stop Ollama; LOW has
no provider teardown or workload-cancellation command. Manage the local daemon
separately after reviewing ongoing consumer work.

## Development

```bash
bundle install
bundle exec rake
```

`rake` runs the full test suite, production lint, and structural Minitest lint.
No ordinary test or registry publication requires an Ollama server or makes an
inference request.
