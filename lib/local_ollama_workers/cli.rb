# frozen_string_literal: true

require "json"
require "optparse"

module LocalOllamaWorkers
  class CLI
    def self.run(arguments, env: ENV, stdout: $stdout, stderr: $stderr)
      new(env:, stdout:, stderr:).run(arguments)
    end

    def initialize(env:, stdout:, stderr:)
      @env = env
      @stdout = stdout
      @stderr = stderr
    end

    def run(arguments)
      args = arguments.dup
      command = args.shift
      raise OptionParser::InvalidArgument, "expected workers" unless command == "workers"
      raise OptionParser::InvalidArgument, "expected --json" unless args == ["--json"]

      publisher = RegistryPublisher.new(state_root: state_root)
      @stdout.write("#{JSON.generate(publisher.snapshot)}\n")
      0
    rescue OptionParser::ParseError => e
      @stderr.puts("ERROR: #{e.message}")
      @stderr.puts("Usage: bin/low workers --json")
      2
    rescue Error => e
      @stderr.puts("ERROR: #{e.message}")
      1
    end

    private

    def state_root
      configured = @env.fetch("LOW_STATE_ROOT", "").strip
      return configured unless configured.empty?

      File.join(Dir.home, ".local", "state", "local-ollama-workers")
    end
  end
end
