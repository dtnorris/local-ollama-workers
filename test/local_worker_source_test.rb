# frozen_string_literal: true

require_relative "test_helper"

class LocalWorkerSourceTest < Minitest::Test
  MODEL = "fixture-model:latest"
  DIGEST = "a" * 64

  class Observer
    attr_reader :calls

    def initialize(*values)
      @values = values
      @index = 0
      @calls = 0
    end

    def observe
      value = @values.fetch([@index, @values.length - 1].min)
      @index += 1
      @calls += 1
      value
    end
  end

  class Client
    attr_reader :endpoint

    def initialize(installed:, running:, version: "0.33.0")
      @installed = installed
      @running = running
      @version = version
      @endpoint = "http://127.0.0.1:11434"
    end

    def installed_models = @installed
    def running_models = @running
    def version = @version
  end

  class Store
    def initialize(document, present: true)
      @document = document
      @present = present
    end

    def present? = @present
    def load_for(_identity) = @document
  end

  def test_valid_current_generation_evidence_emits_one_ready_observation
    source = source_with

    workers = source.workers

    assert_equal 1, workers.length
    worker = workers.first
    assert_equal identity, worker.slice("worker_id", "generation_id", "endpoint")
    assert_equal "READY", worker.fetch("state")
    assert_equal %w[inference local ollama], worker.fetch("labels")
    assert_equal "Apple M4 Pro 20-core GPU", worker.dig("capabilities", "gpu_id")
    assert_equal capability_model, worker.dig("capabilities", "ollama", "models").first
  end

  def test_absent_evidence_does_not_probe_or_publish
    observer = Observer.new(identity)
    source = source_with(observer:, store: Store.new(nil, present: false))

    assert_empty source.workers
    assert_equal 0, observer.calls
  end

  def test_generation_change_during_publication_fails_closed
    replacement = identity.merge("generation_id" => "low-macos-#{"b" * 64}")
    source = source_with(observer: Observer.new(identity, replacement))

    assert_empty source.workers
  end

  def test_same_endpoint_and_model_do_not_rescue_stale_generation_evidence
    source = source_with(store: Store.new(nil))

    assert_empty source.workers
  end

  def test_installed_digest_mismatch_fails_closed_without_rewriting_evidence
    client = Client.new(
      installed: [{ "model" => MODEL, "digest" => "b" * 64 }],
      running: []
    )

    assert_empty source_with(client:).workers
    assert_equal DIGEST, evidence.dig("models", 0, "digest")
  end

  def test_changed_loaded_context_or_residency_invalidates_stale_evidence
    changed_context = Client.new(
      installed: [installed_model],
      running: [running_model.merge("context_length" => 65_536)]
    )
    partial = Client.new(
      installed: [installed_model],
      running: [running_model.merge(
        "fully_gpu_resident" => false,
        "runtime_size_vram_bytes" => 20_000
      )]
    )

    assert_empty source_with(client: changed_context).workers
    assert_empty source_with(client: partial).workers
  end

  def test_unloaded_model_retains_same_generation_bootstrap_capability
    client = Client.new(installed: [installed_model], running: [])

    assert_equal 1, source_with(client:).workers.length
  end

  def test_runtime_version_change_invalidates_evidence
    client = Client.new(installed: [installed_model], running: [], version: "0.34.0")

    assert_empty source_with(client:).workers
  end

  private

  def source_with(observer: Observer.new(identity, identity),
                  client: Client.new(installed: [installed_model], running: [running_model]),
                  store: Store.new(evidence))
    LocalOllamaWorkers::LocalWorkerSource.new(
      observer:,
      client:,
      evidence_store: store
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

  def running_model
    capability_model.merge(
      "runtime_size_bytes" => 30_000,
      "runtime_size_vram_bytes" => 30_000
    )
  end

  def capability_model
    {
      "model" => MODEL,
      "digest" => DIGEST,
      "context_length" => 131_072,
      "fully_gpu_resident" => true
    }
  end

  def evidence
    {
      "schema_version" => 1,
      "worker_id" => identity.fetch("worker_id"),
      "generation_id" => identity.fetch("generation_id"),
      "endpoint" => identity.fetch("endpoint"),
      "ollama_version" => "0.33.0",
      "gpu_id" => "Apple M4 Pro 20-core GPU",
      "models" => [capability_model.merge(
        "observed_at" => "2030-01-01T00:01:00Z",
        "runtime_size_bytes" => 30_000,
        "runtime_size_vram_bytes" => 30_000,
        "source" => "ollama-api-ps-size-vram"
      )]
    }
  end
end
