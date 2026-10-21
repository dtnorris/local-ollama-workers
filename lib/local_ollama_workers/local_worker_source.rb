# frozen_string_literal: true

require "digest"
require "json"
require "time"

module LocalOllamaWorkers
  class LocalWorkerSource
    LABELS = %w[inference local ollama].freeze
    IDENTITY_FIELDS = %w[worker_id generation_id endpoint].freeze
    RUNTIME_FIELDS = %w[
      digest context_length fully_gpu_resident runtime_size_bytes runtime_size_vram_bytes
    ].freeze

    attr_reader :diagnostic

    def initialize(observer:, client:, evidence_store:)
      @observer = observer
      @client = client
      @evidence_store = evidence_store
    end

    # Returns existing eligibility observations, recording only the first
    # rejecting predicate. Errors propagate unchanged; they are not omissions.
    def workers
      @diagnostic = {
        "observed_at" => Time.now.utc.iso8601(6),
        "evidence_identity" => nil, "evidence_sha256" => nil,
        "first_identity" => nil, "second_identity" => nil
      }
      return omitted("evidence_absent") unless @evidence_store.present?

      first_identity = @observer.observe
      @diagnostic["first_identity"] = first_identity
      return omitted("listener_absent") unless first_identity
      unless first_identity.fetch("endpoint") == @client.endpoint
        return omitted("endpoint_mismatch", { "endpoint" => @client.endpoint }, first_identity)
      end

      evidence = @evidence_store.load_for(first_identity) { |document| record_evidence(document) }
      return omitted("evidence_identity_unavailable", @diagnostic["evidence_identity"], first_identity) unless evidence
      return [] unless current_evidence?(evidence)

      second_identity = @observer.observe
      @diagnostic["second_identity"] = second_identity
      return omitted("identity_changed", first_identity, second_identity) unless second_identity == first_identity

      [worker_observation(first_identity, evidence)]
    rescue Error
      @diagnostic = nil
      raise
    end

    private

    def current_evidence?(evidence)
      version = @client.version
      unless evidence.fetch("ollama_version") == version
        omitted("version_mismatch", evidence.slice("ollama_version"), { "ollama_version" => version })
        return false
      end

      installed = @client.installed_models.to_h { |model| [model.fetch("model"), model] }
      running = @client.running_models.to_h { |model| [model.fetch("model"), model] }
      evidence.fetch("models").all? do |model|
        installed_model_matches?(model, installed[model.fetch("model")]) &&
          running_model_matches?(model, running[model.fetch("model")])
      end
    end

    def installed_model_matches?(evidence, installed)
      return true if installed && installed.fetch("digest") == evidence.fetch("digest")

      omitted("installed_model_mismatch", evidence.slice("model", *RUNTIME_FIELDS), installed)
      false
    end

    def running_model_matches?(evidence, running)
      return true unless running

      return true if RUNTIME_FIELDS.all? { |key| running.fetch(key) == evidence.fetch(key) }

      omitted("running_model_mismatch", evidence.slice("model", *RUNTIME_FIELDS), running)
      false
    end

    # Records the identity and JSON.generate SHA-256 of the validated document that
    # was actually read, without rereading mutable evidence or exposing paths.
    def record_evidence(document)
      @diagnostic["evidence_identity"] = document.slice(*IDENTITY_FIELDS)
      @diagnostic["evidence_sha256"] = Digest::SHA256.hexdigest(JSON.generate(document))
    end

    # Returns an empty observation with bounded comparison fields. Null means
    # absent/unobserved; only one rejecting model is retained, never API bodies.
    def omitted(reason, expected = nil, observed = nil)
      @diagnostic.merge!("reason" => reason, "expected" => expected, "observed" => observed)
      []
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
