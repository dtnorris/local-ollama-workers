# frozen_string_literal: true

module LocalOllamaWorkers
  class LocalWorkerSource
    LABELS = %w[inference local ollama].freeze

    def initialize(observer:, client:, evidence_store:)
      @observer = observer
      @client = client
      @evidence_store = evidence_store
    end

    def workers
      return [] unless @evidence_store.present?

      first_identity = @observer.observe
      return [] unless first_identity
      return [] unless first_identity.fetch("endpoint") == @client.endpoint

      evidence = @evidence_store.load_for(first_identity)
      return [] unless evidence
      return [] unless current_evidence?(evidence)

      second_identity = @observer.observe
      return [] unless second_identity == first_identity

      [worker_observation(first_identity, evidence)]
    end

    private

    def current_evidence?(evidence)
      return false unless evidence.fetch("ollama_version") == @client.version

      installed = @client.installed_models.to_h { |model| [model.fetch("model"), model] }
      running = @client.running_models.to_h { |model| [model.fetch("model"), model] }
      evidence.fetch("models").all? do |model|
        installed_model_matches?(model, installed[model.fetch("model")]) &&
          running_model_matches?(model, running[model.fetch("model")])
      end
    end

    def installed_model_matches?(evidence, installed)
      installed && installed.fetch("digest") == evidence.fetch("digest")
    end

    def running_model_matches?(evidence, running)
      return true unless running

      %w[
        digest context_length fully_gpu_resident runtime_size_bytes runtime_size_vram_bytes
      ].all? { |key| running.fetch(key) == evidence.fetch(key) }
    end

    def worker_observation(identity, evidence)
      {
        "worker_id" => identity.fetch("worker_id"),
        "generation_id" => identity.fetch("generation_id"),
        "endpoint" => identity.fetch("endpoint"),
        "state" => "READY",
        "labels" => LABELS.dup,
        "capabilities" => {
          "gpu_id" => evidence.fetch("gpu_id"),
          "ollama" => {
            "models" => evidence.fetch("models").map { |model| capability_model(model) }
          }
        }
      }
    end

    def capability_model(model)
      {
        "model" => model.fetch("model"),
        "digest" => model.fetch("digest"),
        "context_length" => model.fetch("context_length"),
        "fully_gpu_resident" => model.fetch("fully_gpu_resident")
      }
    end
  end
end
