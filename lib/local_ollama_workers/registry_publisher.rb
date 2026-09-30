# frozen_string_literal: true

require "json"
require "time"

module LocalOllamaWorkers
  class RegistryPublisher
    DEFAULT_TTL_SECONDS = 30

    def initialize(state_root:, worker_source: nil, clock: nil, ttl_seconds: DEFAULT_TTL_SECONDS,
                   id_generator: nil)
      @worker_source = worker_source || -> { [] }
      @clock = clock || -> { Time.now.utc }
      @ttl_seconds = positive_integer(ttl_seconds, "registry TTL seconds")
      @state = PublisherState.new(root: state_root, id_generator: id_generator)
    end

    def snapshot
      workers = observed_workers.map do |observation|
        observation.key?("capability_fingerprint") ? validated_copy(observation) : WorkerRecord.build(observation)
      end
      workers.sort_by! { |worker| worker.fetch("worker_id") }
      now = current_time
      Contract.validate_snapshot!(snapshot_document("low-preflight", 0, now, workers), now: now)
      registry_id, revision = @state.advance!
      document = snapshot_document(registry_id, revision, now, workers)
      Contract.validate_snapshot!(document, now: now)
      document
    end

    private

    def snapshot_document(registry_id, revision, now, workers)
      {
        "contract_version" => Contract::VERSION,
        "registry_id" => registry_id,
        "revision" => revision,
        "published_at" => now.iso8601(0),
        "expires_at" => (now + @ttl_seconds).iso8601(0),
        "workers" => workers
      }
    end

    def observed_workers
      value = @worker_source.respond_to?(:call) ? @worker_source.call : @worker_source.workers
      raise Error, "worker source must return an array" unless value.is_a?(Array)

      value
    end

    def validated_copy(worker)
      copy = JSON.parse(JSON.generate(worker))
      Contract.validate_worker!(copy)
      copy
    rescue JSON::GeneratorError, JSON::ParserError => e
      raise Error, "invalid worker record: #{e.message}"
    end

    def current_time
      value = @clock.call
      raise Error, "registry clock must return a Time" unless value.is_a?(Time)

      Time.at(value.to_i).utc
    end

    def positive_integer(value, label)
      number = Integer(value)
      raise Error, "#{label} must be positive" unless number.positive?

      number
    rescue ArgumentError, TypeError
      raise Error, "#{label} must be a positive integer"
    end
  end
end
