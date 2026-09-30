# frozen_string_literal: true

require "digest"
require "json"
require "uri"

module LocalOllamaWorkers
  class LocalWorkerObserver
    DEFAULT_WORKER_ID = "local-ollama-1"
    DEFAULT_ENDPOINT = "http://127.0.0.1:11434"
    GENERATION_PREFIX = "low-macos-"
    LOOPBACK_HOSTS = %w[127.0.0.1 localhost [::1]].freeze

    def initialize(worker_id: DEFAULT_WORKER_ID, endpoint: DEFAULT_ENDPOINT,
                   listener_probe: nil, process_probe: nil)
      @worker_id = Contract.id!(worker_id, "local worker_id")
      @endpoint = normalize_local_endpoint(endpoint)
      @listener_probe = listener_probe || MacOSListenerProbe.new
      @process_probe = process_probe || MacOSProcessProbe.new
    end

    def observe
      first_owner = @listener_probe.owner(@endpoint)
      return nil unless first_owner

      first_process = process_info!(first_owner)
      second_owner = @listener_probe.owner(@endpoint)
      raise Error, "local Ollama listener disappeared during observation" unless second_owner
      raise Error, "local Ollama listener changed during observation" unless same_owner?(first_owner, second_owner)

      second_process = process_info!(second_owner)
      raise Error, "local Ollama process changed during observation" unless same_process?(first_process, second_process)

      {
        "worker_id" => @worker_id,
        "generation_id" => generation_id(first_process),
        "endpoint" => @endpoint
      }.freeze
    end

    private

    def normalize_local_endpoint(value)
      normalized = Contract.normalized_endpoint(value, "local Ollama endpoint")
      uri = URI.parse(normalized)
      return normalized if LOOPBACK_HOSTS.include?(uri.host)

      raise Error, "local Ollama endpoint must use a loopback host"
    rescue URI::InvalidURIError
      raise Error, "local Ollama endpoint must be a valid loopback HTTP(S) origin"
    end

    def process_info!(owner)
      process = @process_probe.info(owner.pid)
      raise Error, "cannot establish concrete local Ollama process identity" unless process
      unless File.basename(process.executable_path).casecmp?("ollama")
        raise Error, "configured local Ollama endpoint is not owned by an Ollama executable"
      end

      process
    end

    def same_owner?(first, second)
      first.pid == second.pid
    end

    def same_process?(first, second)
      first.pid == second.pid &&
        first.start_time_usec == second.start_time_usec &&
        first.executable_path == second.executable_path
    end

    def generation_id(process)
      payload = JSON.generate(
        "endpoint" => @endpoint,
        "executable_path" => process.executable_path,
        "pid" => process.pid,
        "start_time_usec" => process.start_time_usec,
        "worker_id" => @worker_id
      )
      "#{GENERATION_PREFIX}#{Digest::SHA256.hexdigest(payload)}"
    end
  end
end
