# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/local_ollama_workers/error"
require_relative "../lib/local_ollama_workers/contract"
require_relative "../lib/local_ollama_workers/model_requirement"
require_relative "../lib/local_ollama_workers/capability_evidence_store"
require_relative "../lib/local_ollama_workers/capability_bootstrapper"

class ModelRequirementTest < Minitest::Test
  MODEL = "qwen3.6:27b"
  DIGEST = "a" * 64

  class Observer
    def observe
      {"worker_id" => "local-ollama-1", "generation_id" => "low-macos-#{"b" * 64}",
       "endpoint" => "http://127.0.0.1:11434"}
    end
  end

  class Client
    attr_reader :endpoint, :preloads
    attr_accessor :installed, :running

    def initialize
      @endpoint = "http://127.0.0.1:11434"
      @preloads = []
      @installed = [{"model" => MODEL, "digest" => DIGEST}]
      @running = [{"model" => MODEL, "digest" => DIGEST, "context_length" => 131_072,
                   "fully_gpu_resident" => true, "runtime_size_bytes" => 10, "runtime_size_vram_bytes" => 10}]
    end

    def installed_models = installed
    def running_models = running
    def version = "0.33.0"
    def preload!(model:, context_length:) = preloads << [model, context_length]
  end

  class Hardware
    attr_accessor :gpu_id
    def initialize = @gpu_id = "Apple M4 Pro 20-core GPU"
  end

  class Store
    attr_reader :records
    def initialize = @records = []
    def record!(**record)
      records << record
      record
    end
  end

  def test_exact_requirement_is_accepted_for_explicit_bootstrap
    client = Client.new
    store = Store.new
    result = bootstrapper(client:, store:).bootstrap(requirement: requirement)

    assert_equal [[MODEL, 131_072]], client.preloads
    assert_equal 1, store.records.length
    assert_equal store.records.first, result
  end

  def test_wrong_model_and_digest_fail_before_preload
    {
      "model" => [{"model" => "wrong:model", "digest" => DIGEST}],
      "digest" => [{"model" => MODEL, "digest" => "c" * 64}]
    }.each do |label, installed|
      client = Client.new
      client.installed = installed
      store = Store.new

      assert_raises(LocalOllamaWorkers::Error, label) do
        bootstrapper(client:, store:).bootstrap(requirement: requirement)
      end
      assert_empty client.preloads, label
      assert_empty store.records, label
    end
  end

  def test_wrong_gpu_fails_before_preload
    client = Client.new
    store = Store.new
    hardware = Hardware.new
    hardware.gpu_id = "Some other GPU"

    assert_raises(LocalOllamaWorkers::Error) do
      bootstrapper(client:, store:, hardware:).bootstrap(requirement: requirement)
    end
    assert_empty client.preloads
    assert_empty store.records
  end

  def test_insufficient_context_and_non_full_residency_are_rejected_without_evidence
    [{"context_length" => 65_536}, {"fully_gpu_resident" => false}].each do |change|
      client = Client.new
      client.running = [client.running.first.merge(change)]
      store = Store.new

      assert_raises(LocalOllamaWorkers::Error) do
        bootstrapper(client:, store:).bootstrap(requirement: requirement)
      end
      assert_equal [[MODEL, 131_072]], client.preloads
      assert_empty store.records
    end
  end

  def test_requirement_validation_alone_does_not_observe_or_mutate_ollama
    parsed = LocalOllamaWorkers::ModelRequirement.new(document)
    assert_equal MODEL, parsed.model
    assert_equal 131_072, parsed.required_context_length
  end

  private

  def bootstrapper(client:, store:, hardware: Hardware.new)
    LocalOllamaWorkers::CapabilityBootstrapper.new(
      observer: Observer.new, client:, hardware_probe: hardware, evidence_store: store,
      clock: -> { Time.utc(2030, 1, 1) }
    )
  end

  def requirement = LocalOllamaWorkers::ModelRequirement.new(document)

  def document
    {
      "contract_version" => "adventurefinder-model-requirement/v0.1",
      "batch_handle" => "39", "production_batch_id" => "production-batch-039",
      "plan_id" => "production-batch-039", "plan_sha256" => "d" * 64,
      "alias" => "qwen27", "pool_id" => "qwen27", "required_labels" => ["inference"],
      "ollama" => {"model" => MODEL, "expected_digest" => DIGEST, "required_context_length" => 131_072,
                   "require_fully_gpu_resident" => true, "required_gpu_id" => "Apple M4 Pro 20-core GPU"}
    }
  end
end
