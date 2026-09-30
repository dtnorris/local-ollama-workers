# frozen_string_literal: true

require "English"
require "fileutils"
require "json"
require "securerandom"
require "time"

module LocalOllamaWorkers
  class CapabilityEvidenceStore
    EVIDENCE_FILE = "local-capability-evidence-v1.json"
    LOCK_FILE = ".local-capability-evidence-v1.lock"
    DOCUMENT_KEYS = %w[schema_version worker_id generation_id endpoint ollama_version gpu_id models].freeze
    MODEL_KEYS = %w[
      model digest context_length fully_gpu_resident observed_at runtime_size_bytes
      runtime_size_vram_bytes source
    ].freeze
    SOURCE = "ollama-api-ps-size-vram"

    def initialize(root:, renamer: nil)
      @root = File.expand_path(root)
      @renamer = renamer || ->(source, destination) { File.rename(source, destination) }
    end

    def present? = File.file?(evidence_path)

    def load_for(identity)
      document = load_document
      return nil unless document
      return nil unless same_identity?(document, identity)

      deep_copy(document)
    rescue JSON::ParserError, SystemCallError, KeyError, TypeError, ArgumentError => e
      raise Error, "could not read local capability evidence: #{e.message}"
    end

    def record!(identity:, ollama_version:, gpu_id:, model:)
      FileUtils.mkdir_p(@root)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        current = load_document
        document = updated_document(
          current,
          identity:,
          ollama_version:,
          gpu_id:,
          model:
        )
        validate_document!(document)
        write_atomic(document)
        deep_copy(document)
      end
    rescue JSON::ParserError, SystemCallError, KeyError, TypeError, ArgumentError => e
      raise Error, "could not persist local capability evidence: #{e.message}"
    end

    private

    def evidence_path = File.join(@root, EVIDENCE_FILE)
    def lock_path = File.join(@root, LOCK_FILE)

    def load_document
      return nil unless File.file?(evidence_path)

      document = JSON.parse(File.binread(evidence_path))
      validate_document!(document)
      document
    end

    def updated_document(current, identity:, ollama_version:, gpu_id:, model:)
      validated_identity = validate_identity!(identity)
      version = Contract.nonempty!(ollama_version, "capability evidence Ollama version", max: 128)
      hardware = Contract.nonempty!(gpu_id, "capability evidence gpu_id", max: 256)
      evidence_model = validate_model!(deep_copy(model))
      models = if current && same_identity?(current, validated_identity)
                 same_runtime = current.fetch("ollama_version") == version && current.fetch("gpu_id") == hardware
                 raise Error, "current-generation runtime identity changed" unless same_runtime

                 current.fetch("models").reject { |entry| entry.fetch("model") == evidence_model.fetch("model") }
               else
                 []
               end
      models << evidence_model
      models.sort_by! { |entry| Contract.canonical_model_key(entry) }

      {
        "schema_version" => 1,
        "worker_id" => validated_identity.fetch("worker_id"),
        "generation_id" => validated_identity.fetch("generation_id"),
        "endpoint" => validated_identity.fetch("endpoint"),
        "ollama_version" => version,
        "gpu_id" => hardware,
        "models" => models
      }
    end

    def validate_document!(document)
      Contract.exact_keys!(document, DOCUMENT_KEYS, "capability evidence")
      raise Error, "capability evidence schema is invalid" unless document.fetch("schema_version") == 1

      validate_identity!(document)
      Contract.nonempty!(document.fetch("ollama_version"), "capability evidence Ollama version", max: 128)
      Contract.nonempty!(document.fetch("gpu_id"), "capability evidence gpu_id", max: 256)
      models = document.fetch("models")
      raise Error, "capability evidence models must be a nonempty array" unless models.is_a?(Array) && !models.empty?

      models.each { |model| validate_model!(model) }
      names = models.map { |model| model.fetch("model") }
      raise Error, "capability evidence model identities must be unique" unless names.uniq == names

      sorted = models.sort_by { |model| Contract.canonical_model_key(model) }
      raise Error, "capability evidence models must be sorted" unless sorted == models

      document
    end

    def validate_identity!(identity)
      {
        "worker_id" => Contract.id!(identity.fetch("worker_id"), "capability evidence worker_id"),
        "generation_id" => Contract.nonempty!(
          identity.fetch("generation_id"),
          "capability evidence generation_id",
          max: 256
        ),
        "endpoint" => Contract.normalized_endpoint(
          identity.fetch("endpoint"),
          "capability evidence endpoint"
        )
      }
    end

    def validate_model!(model)
      Contract.exact_keys!(model, MODEL_KEYS, "capability evidence model")
      Contract.nonempty!(model.fetch("model"), "capability evidence model identity", max: 256)
      digest = model.fetch("digest")
      valid_digest = digest.is_a?(String) && Contract::SHA256.match?(digest)
      raise Error, "capability evidence digest must be a lowercase SHA-256" unless valid_digest

      context = model.fetch("context_length")
      valid_context = context.is_a?(Integer) && context.positive?
      raise Error, "capability evidence context_length must be a positive integer" unless valid_context

      residency = model.fetch("fully_gpu_resident")
      raise Error, "capability evidence fully_gpu_resident must be boolean" unless [true, false].include?(residency)

      Contract.timestamp!(model.fetch("observed_at"), "capability evidence observed_at")
      size = nonnegative_integer(model.fetch("runtime_size_bytes"), "capability evidence runtime size")
      size_vram = nonnegative_integer(
        model.fetch("runtime_size_vram_bytes"),
        "capability evidence runtime size_vram"
      )
      raise Error, "capability evidence runtime size must be positive" unless size.positive?
      raise Error, "capability evidence runtime size_vram exceeds size" if size_vram > size

      matches_sizes = residency == (size == size_vram)
      raise Error, "capability evidence residency disagrees with observed runtime sizes" unless matches_sizes
      raise Error, "capability evidence source is unsupported" unless model.fetch("source") == SOURCE

      model
    end

    def nonnegative_integer(value, label)
      raise Error, "#{label} must be a non-negative integer" unless value.is_a?(Integer) && !value.negative?

      value
    end

    def same_identity?(document, identity)
      %w[worker_id generation_id endpoint].all? do |key|
        document.fetch(key) == identity.fetch(key)
      end
    end

    def write_atomic(document)
      temporary = "#{evidence_path}.tmp.#{$PROCESS_ID}.#{Thread.current.object_id}.#{SecureRandom.hex(4)}"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write("#{JSON.generate(document)}\n")
        file.flush
        file.fsync
      end
      @renamer.call(temporary, evidence_path)
      sync_directory
    ensure
      File.delete(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def sync_directory
      File.open(@root, File::RDONLY, &:fsync)
    rescue Errno::EINVAL, Errno::ENOTSUP
      # Some filesystems do not support directory fsync; the atomic rename still holds.
    end

    def deep_copy(value)
      JSON.parse(JSON.generate(value))
    end
  end
end
