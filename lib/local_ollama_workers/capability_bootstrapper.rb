# frozen_string_literal: true

require "time"

module LocalOllamaWorkers
  class CapabilityBootstrapper
    def initialize(observer:, client:, hardware_probe:, evidence_store:, clock: nil)
      @observer = observer
      @client = client
      @hardware_probe = hardware_probe
      @evidence_store = evidence_store
      @clock = clock || -> { Time.now.utc }
    end

    def bootstrap(capability_request:)
      unless capability_request.is_a?(OllamaCapabilityRequest)
        raise Error, "bootstrap requires an ollama-capability-request/v0.1 document"
      end

      model = capability_request.model
      context_length = capability_request.required_context_length
      first_identity = current_identity!
      ensure_endpoint!(first_identity)
      installed = installed_model!(model)
      ollama_version = @client.version
      gpu_id = @hardware_probe.gpu_id
      capability_request.validate_preload!(installed:, gpu_id:)
      @client.preload!(model: installed.fetch("model"), context_length:)
      running = running_model!(installed.fetch("model"))
      same_digest = running.fetch("digest") == installed.fetch("digest")
      raise Error, "loaded model digest does not match the installed model digest" unless same_digest

      capability_request.validate_observed!(running:, gpu_id:)

      second_identity = current_identity!
      same_generation = first_identity == second_identity
      raise Error, "local Ollama generation changed during capability bootstrap" unless same_generation

      @evidence_store.record!(
        identity: first_identity,
        ollama_version:,
        gpu_id:,
        model: evidence_model(running)
      )
    end

    private

    def current_identity!
      identity = @observer.observe
      raise Error, "no concrete local Ollama generation is currently observable" unless identity

      identity
    end

    def ensure_endpoint!(identity)
      return if identity.fetch("endpoint") == @client.endpoint

      raise Error, "Ollama client endpoint does not match the observed local generation"
    end

    def installed_model!(model)
      model_id = Contract.nonempty!(model, "bootstrap model", max: 256)
      installed = @client.installed_models.find { |entry| entry.fetch("model") == model_id }
      return installed if installed

      raise Error, "model #{model_id.inspect} is not installed; refusing to download it"
    end

    def running_model!(model)
      running = @client.running_models.select { |entry| entry.fetch("model") == model }
      raise Error, "bootstrap did not produce one observable loaded model" unless running.length == 1

      running.first
    end

    def evidence_model(running)
      {
        "model" => running.fetch("model"),
        "digest" => running.fetch("digest"),
        "context_length" => running.fetch("context_length"),
        "fully_gpu_resident" => running.fetch("fully_gpu_resident"),
        "observed_at" => observed_at,
        "runtime_size_bytes" => running.fetch("runtime_size_bytes"),
        "runtime_size_vram_bytes" => running.fetch("runtime_size_vram_bytes"),
        "source" => CapabilityEvidenceStore::SOURCE
      }
    end

    def observed_at
      value = @clock.call
      raise Error, "bootstrap clock must return a Time" unless value.is_a?(Time)

      value.utc.iso8601(0)
    end
  end
end
