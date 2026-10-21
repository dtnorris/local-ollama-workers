# frozen_string_literal: true

require "json"
require "optparse"

module LocalOllamaWorkers
  class CLI
    def self.run(arguments, env: ENV, stdout: $stdout, stderr: $stderr, components: {})
      new(
        env:,
        stdout:,
        stderr:,
        components:
      ).run(arguments)
    end

    def initialize(env:, stdout:, stderr:, components: {})
      @env = env
      @stdout = stdout
      @stderr = stderr
      @observer = components[:observer]
      @client = components[:client]
      @hardware_probe = components[:hardware_probe]
      @evidence_store = components[:evidence_store]
    end

    def run(arguments)
      args = arguments.dup
      command = args.shift
      case command
      when "workers"
        publish_workers(args)
      when "bootstrap"
        bootstrap(args)
      else
        raise OptionParser::InvalidArgument, "expected workers or bootstrap"
      end
      0
    rescue OptionParser::ParseError => e
      @stderr.puts("ERROR: #{e.message}")
      @stderr.puts(usage)
      2
    rescue Error => e
      @stderr.puts("ERROR: #{e.message}")
      1
    end

    private

    def publish_workers(arguments)
      raise OptionParser::InvalidArgument, "expected --json" unless arguments == ["--json"]

      source = LocalWorkerSource.new(
        observer: observer,
        client: client,
        evidence_store: evidence_store
      )
      publisher = RegistryPublisher.new(state_root:, worker_source: source)
      snapshot = publisher.snapshot
      @stdout.write("#{JSON.generate(snapshot)}\n")
      write_empty_diagnostic(snapshot, source.diagnostic) if snapshot.fetch("workers").empty?
    end

    # Writes one separate record after successful stdout publication. Diagnostic
    # IO failure must not turn a valid snapshot into a failed poll. No raw errors,
    # API bodies, environment, prompts, local paths or credentials are included.
    def write_empty_diagnostic(snapshot, diagnostic)
      record = diagnostic.merge(
        "event" => "low_empty_publication",
        "schema_version" => 1,
        "registry_id" => snapshot.fetch("registry_id"),
        "revision" => snapshot.fetch("revision"),
        "published_at" => snapshot.fetch("published_at")
      )
      @stderr.write("#{JSON.generate(record)}\n")
    rescue IOError, SystemCallError
      # This best-effort channel cannot alter registry publication semantics.
      nil
    end

    def bootstrap(arguments)
      options = parse_bootstrap_options(arguments)
      document = CapabilityBootstrapper.new(
        observer: observer,
        client: client,
        hardware_probe: hardware_probe,
        evidence_store:
      ).bootstrap(
        capability_request: OllamaCapabilityRequest.load(options.fetch(:capability_request))
      )
      @stdout.write("#{JSON.generate(document)}\n")
    end

    def parse_bootstrap_options(arguments)
      options = {}
      parser = OptionParser.new
      parser.on("--capability-request PATH", "Exact ollama-capability-request/v0.1 JSON") do |value|
        options[:capability_request] = value
      end
      parser.on("--json") { options[:json] = true }
      remaining = arguments.dup
      parser.parse!(remaining)
      raise OptionParser::InvalidArgument, "unexpected arguments: #{remaining.join(' ')}" unless remaining.empty?

      raise OptionParser::MissingArgument, "--capability-request" unless options[:capability_request]
      raise OptionParser::MissingArgument, "--json" unless options[:json]

      options
    end

    def observer
      @observer ||= LocalWorkerObserver.new(worker_id:, endpoint:)
    end

    def client
      @client ||= OllamaClient.new(endpoint:)
    end

    def hardware_probe
      @hardware_probe ||= MacOSHardwareProbe.new
    end

    def evidence_store
      @evidence_store ||= CapabilityEvidenceStore.new(root: state_root)
    end

    def worker_id
      configured = @env.fetch("LOW_WORKER_ID", "").strip
      configured.empty? ? LocalWorkerObserver::DEFAULT_WORKER_ID : configured
    end

    def endpoint
      configured = @env.fetch("LOW_OLLAMA_ENDPOINT", "").strip
      configured.empty? ? LocalWorkerObserver::DEFAULT_ENDPOINT : configured
    end

    def state_root
      configured = @env.fetch("LOW_STATE_ROOT", "").strip
      return configured unless configured.empty?

      File.join(Dir.home, ".local", "state", "local-ollama-workers")
    end

    def usage
      [
        "Usage: bin/low workers --json",
        "       bin/low bootstrap --capability-request FILE --json"
      ].join("\n")
    end
  end
end
