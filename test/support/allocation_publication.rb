# frozen_string_literal: true

# Offline publisher fixture: only API documents, listener identity and time are
# synthetic. Evidence validation, eligibility, records and persistence are real.
class AllocationPublication
  DIGEST = "f38aa0c53da5f8c49d08c43a99df24ff53167fe68e24664a7777288e7656fdfe"
  SAVED_SIZE = 12_858_100_284
  OBSERVED_SIZE = 13_089_594_408
  MODEL = "qwen3-coder:30b-candidate"

  attr_reader :inputs, :identity, :evidence_path, :source
  attr_accessor :now, :identities

  # Creates qualified synthetic evidence in root, returning a fixture with real
  # publication components. Invalid fixture data raises LocalOllamaWorkers::Error.
  # Partial residency is used only to exercise valid single-field size changes.
  def initialize(root:, fully_gpu_resident: true)
    @now = Time.utc(2030, 1, 1, 0, 1, 0)
    @identity = {
      "worker_id" => "local-ollama-1", "generation_id" => "low-macos-#{'a' * 64}",
      "endpoint" => "http://127.0.0.1:11434"
    }
    @identities = [@identity]
    runtime = {
      "model" => MODEL, "digest" => DIGEST, "context_length" => 131_072,
      "size" => SAVED_SIZE, "size_vram" => fully_gpu_resident ? SAVED_SIZE : SAVED_SIZE / 2
    }
    @inputs = {
      "/api/version" => { "version" => "0.33.0" },
      "/api/tags" => { "models" => [runtime.slice("model", "digest")] },
      "/api/ps" => { "models" => [runtime] }
    }
    requester = lambda do |method, path, payload|
      raise "Unexpected non-observational API call" unless method == :get && payload.nil?

      @inputs.fetch(path)
    end
    client = LocalOllamaWorkers::OllamaClient.new(endpoint: @identity.fetch("endpoint"), requester:)
    store = LocalOllamaWorkers::CapabilityEvidenceStore.new(root:)
    store.record!(
      identity: @identity, ollama_version: "0.33.0", gpu_id: "Apple M4 Pro 20-core GPU",
      model: client.running_models.first.merge(
        "observed_at" => @now.iso8601, "source" => LocalOllamaWorkers::CapabilityEvidenceStore::SOURCE
      )
    )
    @evidence_path = File.join(root, LocalOllamaWorkers::CapabilityEvidenceStore::EVIDENCE_FILE)
    @source = LocalOllamaWorkers::LocalWorkerSource.new(observer: self, client:, evidence_store: store)
    @publisher = LocalOllamaWorkers::RegistryPublisher.new(
      state_root: root, worker_source: @source, clock: -> { @now }, id_generator: -> { "low-bug-08-fixture" }
    )
  end

  # Returns the next synthetic listener identity, repeating the final observation;
  # nil simulates disappearance. No process discovery or mutation occurs.
  def observe
    @identities.length > 1 ? @identities.shift : @identities.first
  end

  # Returns the mutable external /api/ps row; missing fixture rows raise KeyError.
  def running
    @inputs.fetch("/api/ps").fetch("models").first
  end

  # Publishes through real LOW components; returns the snapshot or propagates
  # validation/persistence errors. No qualification writes occur here.
  def snapshot
    @publisher.snapshot
  end
end
