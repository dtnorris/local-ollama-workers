# frozen_string_literal: true

require_relative "test_helper"

class CapabilityBootstrapperTest < Minitest::Test
  MODEL = "fixture-model:latest"
  DIGEST = "a" * 64
  GPU_ID = "Apple M4 Pro 20-core GPU"

  class Observer
    def initialize(*identities)
      @identities = identities
      @index = 0
    end

    def observe
      value = @identities.fetch([@index, @identities.length - 1].min)
      @index += 1
      value
    end
  end

  class Client
    attr_reader :endpoint, :preloads
    attr_accessor :installed, :running

    def initialize(installed:, running:, endpoint: "http://127.0.0.1:11434")
      @installed = installed
      @running = running
      @endpoint = endpoint
      @preloads = []
    end

    def installed_models = installed
    def running_models = running
    def version = "0.33.0"

    def preload!(model:, context_length:)
      @preloads << [model, context_length]
    end
  end

  class HardwareProbe
    attr_accessor :gpu_id

    def initialize
      @gpu_id = GPU_ID
    end
  end

  class EvidenceStore
    attr_reader :records

    def initialize
      @records = []
    end

    def record!(**record)
      @records << record
      record
    end
  end

  def test_exact_runtime_match_preloads_and_records_observed_evidence
    client = default_client
    store = EvidenceStore.new
    result = bootstrapper(client:, store:).bootstrap(capability_request: request)

    assert_equal [[MODEL, 131_072]], client.preloads
    assert_equal store.records.first, result
    model = result.fetch(:model)
    assert_equal MODEL, model.fetch("model")
    assert_equal DIGEST, model.fetch("digest")
    assert_equal 131_072, model.fetch("context_length")
    assert_equal true, model.fetch("fully_gpu_resident")
  end

  def test_bootstrap_requires_parsed_generic_request
    error = assert_raises(LocalOllamaWorkers::Error) do
      bootstrapper(client: default_client, store: EvidenceStore.new).bootstrap(capability_request: {})
    end

    assert_includes error.message, "ollama-capability-request/v0.1"
  end

  def test_installed_model_and_digest_mismatches_fail_before_preload
    {
      "model" => [{"model" => "other-model:latest", "digest" => DIGEST}],
      "digest" => [installed_model.merge("digest" => "b" * 64)]
    }.each do |label, installed|
      client = Client.new(installed:, running: [running_model])
      store = EvidenceStore.new

      assert_raises(LocalOllamaWorkers::Error, label) do
        bootstrapper(client:, store:).bootstrap(capability_request: request)
      end
      assert_empty client.preloads, label
      assert_empty store.records, label
    end
  end

  def test_optional_gpu_id_mismatch_fails_before_preload
    client = default_client
    store = EvidenceStore.new
    hardware = HardwareProbe.new
    hardware.gpu_id = "Different GPU"

    assert_raises(LocalOllamaWorkers::Error) do
      bootstrapper(client:, store:, hardware:).bootstrap(capability_request: request)
    end
    assert_empty client.preloads
    assert_empty store.records
  end

  def test_runtime_model_digest_context_and_residency_mismatches_fail_closed
    mismatches = {
      "model" => [running_model.merge("model" => "other-model:latest")],
      "digest" => [running_model.merge("digest" => "b" * 64)],
      "lower context" => [running_model.merge("context_length" => 65_536)],
      "higher context" => [running_model.merge("context_length" => 262_144)],
      "residency" => [running_model(fully_gpu_resident: false)]
    }

    mismatches.each do |label, running|
      client = Client.new(installed: [installed_model], running:)
      store = EvidenceStore.new

      assert_raises(LocalOllamaWorkers::Error, label) do
        bootstrapper(client:, store:).bootstrap(capability_request: request)
      end
      assert_equal [[MODEL, 131_072]], client.preloads, label
      assert_empty store.records, label
    end
  end

  def test_false_residency_requirement_is_also_matched_exactly
    client = default_client
    store = EvidenceStore.new

    assert_raises(LocalOllamaWorkers::Error) do
      bootstrapper(client:, store:).bootstrap(
        capability_request: request(require_fully_gpu_resident: false)
      )
    end
    assert_empty store.records
  end

  def test_exact_false_residency_match_succeeds
    client = Client.new(
      installed: [installed_model],
      running: [running_model(fully_gpu_resident: false)]
    )
    store = EvidenceStore.new

    bootstrapper(client:, store:).bootstrap(
      capability_request: request(require_fully_gpu_resident: false)
    )

    assert_equal false, store.records.first.fetch(:model).fetch("fully_gpu_resident")
  end

  def test_absent_gpu_requirement_does_not_reinterpret_observed_gpu
    client = default_client
    store = EvidenceStore.new
    hardware = HardwareProbe.new
    hardware.gpu_id = "Any exact observed GPU"

    bootstrapper(client:, store:, hardware:).bootstrap(
      capability_request: request(required_gpu_id: nil)
    )

    assert_equal "Any exact observed GPU", store.records.first.fetch(:gpu_id)
  end

  def test_missing_model_fails_before_preload_without_downloading
    client = Client.new(installed: [], running: [])
    store = EvidenceStore.new

    error = assert_raises(LocalOllamaWorkers::Error) do
      bootstrapper(client:, store:).bootstrap(capability_request: request)
    end

    assert_includes error.message, "refusing to download"
    assert_empty client.preloads
    assert_empty store.records
  end

  def test_generation_change_during_bootstrap_prevents_persistence
    replacement = identity.merge("generation_id" => "low-macos-#{'b' * 64}")
    observer = Observer.new(identity, replacement)
    client = default_client
    store = EvidenceStore.new

    assert_raises(LocalOllamaWorkers::Error) do
      bootstrapper(client:, store:, observer:).bootstrap(capability_request: request)
    end

    assert_empty store.records
  end

  def test_repeated_exact_bootstrap_reloads_and_refreshes_one_model_evidence
    Dir.mktmpdir("low-repeat-bootstrap-") do |root|
      client = default_client
      store = LocalOllamaWorkers::CapabilityEvidenceStore.new(root:)

      bootstrapper(
        client:,
        store:,
        clock: -> { Time.utc(2030, 1, 1, 0, 1, 0) }
      ).bootstrap(capability_request: request)
      bootstrapper(
        client:,
        store:,
        clock: -> { Time.utc(2030, 1, 1, 0, 2, 0) }
      ).bootstrap(capability_request: request)

      evidence = store.load_for(identity)
      assert_equal [[MODEL, 131_072], [MODEL, 131_072]], client.preloads
      assert_equal 1, evidence.fetch("models").length
      assert_equal "2030-01-01T00:02:00Z", evidence.dig("models", 0, "observed_at")
    end
  end

  def test_same_model_context_transition_replaces_old_capability_and_failure_preserves_it
    Dir.mktmpdir("low-context-transition-") do |root|
      client = default_client
      store = LocalOllamaWorkers::CapabilityEvidenceStore.new(root:)
      bootstrapper(client:, store:).bootstrap(capability_request: request)
      client.running = [running_model(context_length: 65_536)]

      bootstrapper(client:, store:).bootstrap(
        capability_request: request(context_length: 65_536)
      )
      transitioned = store.load_for(identity)

      assert_equal [65_536], transitioned.fetch("models").map { |model| model.fetch("context_length") }

      client.running = [running_model(context_length: 32_768)]
      assert_raises(LocalOllamaWorkers::Error) do
        bootstrapper(client:, store:).bootstrap(
          capability_request: request(context_length: 16_384)
        )
      end
      assert_equal transitioned, store.load_for(identity)
    end
  end

  private

  def bootstrapper(client:, store:, hardware: HardwareProbe.new,
                   observer: Observer.new(identity, identity),
                   clock: -> { Time.utc(2030, 1, 1, 0, 1, 0) })
    LocalOllamaWorkers::CapabilityBootstrapper.new(
      observer:,
      client:,
      hardware_probe: hardware,
      evidence_store: store,
      clock:
    )
  end

  def request(require_fully_gpu_resident: true, required_gpu_id: GPU_ID,
              context_length: 131_072)
    ollama = {
      "model" => MODEL,
      "expected_digest" => DIGEST,
      "required_context_length" => context_length,
      "require_fully_gpu_resident" => require_fully_gpu_resident
    }
    ollama["required_gpu_id"] = required_gpu_id unless required_gpu_id.nil?
    LocalOllamaWorkers::OllamaCapabilityRequest.new(
      JSON.generate("contract_version" => "ollama-capability-request/v0.1", "ollama" => ollama)
    )
  end

  def default_client
    Client.new(installed: [installed_model], running: [running_model])
  end

  def identity
    {
      "worker_id" => "local-ollama-1",
      "generation_id" => "low-macos-#{'a' * 64}",
      "endpoint" => "http://127.0.0.1:11434"
    }
  end

  def installed_model
    {"model" => MODEL, "digest" => DIGEST}
  end

  def running_model(fully_gpu_resident: true, context_length: 131_072)
    {
      "model" => MODEL,
      "digest" => DIGEST,
      "context_length" => context_length,
      "fully_gpu_resident" => fully_gpu_resident,
      "runtime_size_bytes" => 30_000,
      "runtime_size_vram_bytes" => fully_gpu_resident ? 30_000 : 20_000
    }
  end
end
