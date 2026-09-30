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

## LOW-03 scope

LOW-03 provides:

- durable publisher identity and monotonically advancing revision state;
- atomic publication-state updates protected by an exclusive file lock;
- strict registry, worker, capability, and fingerprint validation;
- deterministic construction from already-proven worker observations; and
- an empty observational publisher suitable for wiring into WLO.

It does **not** yet discover a real local Ollama generation or produce real
generation-bound model context/residency evidence. LOW-04 will establish local
worker generation semantics. LOW-05 will establish real capability evidence.
Until those steps are complete, LOW must not claim production-ready local
workers merely because an Ollama endpoint responds.

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

