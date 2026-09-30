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

LOW-03 established the frozen registry publisher foundation. LOW-04 adds a
read-only macOS identity seam for one locally observable Ollama daemon:

- the logical worker ID remains stable across daemon restarts;
- the concrete `generation_id` is an opaque digest of process-incarnation
  evidence, including the kernel-reported microsecond process start time;
- listener ownership is observed independently from process identity and is
  checked twice so a replacement during observation fails closed; and
- endpoint equality never proves worker continuity.

LOW-04 deliberately does not feed this identity into registry publication yet.
The registry contract requires truthful generation-bound model capability
evidence as well as identity, and LOW-05 owns that evidence. Until LOW-05 is
complete, `workers --json` continues to publish an empty worker array rather
than manufacturing a READY or capability-bearing local worker.

## CLI

```bash
bin/low workers --json
```

The command emits exactly one JSON snapshot to stdout. It currently publishes
an empty `workers` array. Publisher state defaults to
`~/.local/state/local-ollama-workers`; set `LOW_STATE_ROOT` to select another
state directory.

## Development

```bash
bundle install
bundle exec rake
```

`rake` runs the full test suite, production lint, and structural Minitest lint.
No ordinary test or registry publication requires an Ollama server or makes an
inference request.

