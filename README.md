# local-ollama-workers

`local-ollama-workers` (LOW) publishes operator-owned local Ollama capacity
through AdventureFinder's provider-neutral `dynamic-worker-registry/v0.1`
boundary.

> **AFW defines work. LOW and RPOF expose workers. WLO matches work to workers.**

LOW does not schedule jobs, create WLO attempts, inject attempt endpoints,
manage paid capacity, or execute inference workloads. Ordinary registry
publication is observational: it must not start or restart Ollama, pull or load
models, warm a model, change runtime configuration, or run inference.

The authoritative contract is
`dtnorris/md-specification-files/contracts/dynamic-worker-registry/v0.1`.
Canonical contract fixtures are copied into
`test/fixtures/dynamic-worker-registry-v0.1` and pinned by their authoritative
SHA-256 manifest so the test suite is independent of sibling checkouts.

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

The evidence is stored separately from registry publisher identity/revision
state in `local-capability-evidence-v1.json`. Writes are locked and atomic.
Malformed evidence fails closed.

Evidence is bound to `worker_id`, `generation_id`, and endpoint. Restarting
or replacing Ollama changes the generation and immediately makes prior
evidence ineligible, even when the endpoint, model, and digest are unchanged.
Re-bootstrap the required model after a restart.

Several model records may be retained for one generation without keeping every
model loaded simultaneously. Ordinary publication rechecks the server version
and installed digest. If an evidenced model is currently loaded, its digest,
effective context, residency result, and allocation sizes must still match the
bootstrap observation; a changed runtime configuration cannot remain READY.

## CLI

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

Deliberately establish capability evidence for one already-installed model:

```bash
bin/low bootstrap \
  --model ministral-3:14b-instruct-2512-q4_K_M \
  --context-length 131072 \
  --json
```

When AdventureFinder has already resolved a short alias against a frozen AFW
plan, pass that exact artifact instead:

```bash
bin/low bootstrap --requirement /path/to/model-requirement.json --json
```

The requirement path validates the exact model, full digest, context, residency,
and optional GPU identity. Installed-model and GPU mismatches fail before preload;
observed context or residency mismatches prevent evidence persistence. The alias is
retained only as provenance and is never interpreted by LOW.

The model name and context above are examples, not defaults. Bootstrap records
the context Ollama actually loaded; it never promotes or rounds that value to
the requested one.

Publisher and capability state default to
`~/.local/state/local-ollama-workers`. Set `LOW_STATE_ROOT` to select another
state directory. `LOW_WORKER_ID` and `LOW_OLLAMA_ENDPOINT` may override the
single logical worker ID and loopback endpoint.

LOW supplies a conforming local worker only after the exact production model is
explicitly bootstrapped. It does not choose a pool or model, resolve aliases, or
run the workload itself.

## Development

```bash
bundle install
bundle exec rake
```

`rake` runs the full test suite, production lint, and structural Minitest lint.
No ordinary test or registry publication requires an Ollama server or makes an
inference request.
