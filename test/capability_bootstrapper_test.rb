# frozen_string_literal: true

require_relative "test_helper"

class CapabilityBootstrapperTest < Minitest::Test
  MODEL = "fixture-model:latest"
  DIGEST = "a" * 64

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

    def initialize(installed:, running:, endpoint: "http://127.0.0.1:11434")
      @installed = installed
      @running = running
      @endpoint = endpoint
      @preloads = []
    end

    def installed_models = @installed
    def running_models = @running
    def version = "0.33.0"

    def preload!(model:, context_length:)
      @preloads << [model, context_length]
    end
  end

  class HardwareProbe
    def gpu_id = "Apple M4 Pro 20-core GPU"
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

  def test_bootstrap_records_observed_values_not_requested_or_assumed_values
    client = Client.new(
      installed: [installed_model],
      running: [running_model(context_length: 65_536, fully_gpu_resident: false)]
    )
    store = EvidenceStore.new
    bootstrapper = bootstrapper(client:, store:)

    bootstrapper.bootstrap(model: MODEL, context_length: 131_072)

    assert_equal [[MODEL, 131_072]], client.preloads
    model = store.records.first.fetch(:model)
    assert_equal MODEL, model.fetch("model")
    assert_equal DIGEST, model.fetch("digest")
    assert_equal 65_536, model.fetch("context_length")
    assert_equal false, model.fetch("fully_gpu_resident")
    assert_equal 30_000, model.fetch("runtime_size_bytes")
    assert_equal 20_000, model.fetch("runtime_size_vram_bytes")
    assert_equal "2030-01-01T00:01:00Z", model.fetch("observed_at")
  end

  def test_missing_model_fails_before_preload_without_downloading
    client = Client.new(installed: [], running: [])
    store = EvidenceStore.new
    bootstrapper = bootstrapper(client:, store:)

    error = assert_raises(LocalOllamaWorkers::Error) do
      bootstrapper.bootstrap(model: MODEL, context_length: 131_072)
    end

    assert_includes error.message, "refusing to download"
    assert_empty client.preloads
    assert_empty store.records
  end

  def test_runtime_digest_is_never_rewritten_to_installed_digest
    client = Client.new(
      installed: [installed_model],
      running: [running_model.merge("digest" => "b" * 64)]
    )
    store = EvidenceStore.new

    assert_raises(LocalOllamaWorkers::Error) do
      bootstrapper(client:, store:).bootstrap(model: MODEL, context_length: 131_072)
    end

    assert_empty store.records
  end

  def test_generation_change_during_bootstrap_prevents_persistence
    replacement = identity.merge("generation_id" => "low-macos-#{"b" * 64}")
    observer = Observer.new(identity, replacement)
    client = Client.new(installed: [installed_model], running: [running_model])
    store = EvidenceStore.new

    assert_raises(LocalOllamaWorkers::Error) do
      bootstrapper(client:, store:, observer:).bootstrap(model: MODEL, context_length: 131_072)
    end

    assert_empty store.records
  end

  private

  def bootstrapper(client:, store:, observer: Observer.new(identity, identity))
    LocalOllamaWorkers::CapabilityBootstrapper.new(
      observer:,
      client:,
      hardware_probe: HardwareProbe.new,
      evidence_store: store,
      clock: -> { Time.utc(2030, 1, 1, 0, 1, 0) }
    )
  end

  def identity
    {
      "worker_id" => "local-ollama-1",
      "generation_id" => "low-macos-#{"a" * 64}",
      "endpoint" => "http://127.0.0.1:11434"
    }
  end

  def installed_model
    { "model" => MODEL, "digest" => DIGEST }
  end

  def running_model(context_length: 131_072, fully_gpu_resident: true)
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
