# frozen_string_literal: true

require "open3"
require "uri"

module LocalOllamaWorkers
  class MacOSListenerProbe
    Owner = Struct.new(:pid, :command, keyword_init: true)
    LSOF = "/usr/sbin/lsof"

    def initialize(executor: Open3.method(:capture3), executable: LSOF)
      @executor = executor
      @executable = executable
    end

    def owner(endpoint)
      port = URI.parse(endpoint).port
      stdout, stderr, status = @executor.call(
        @executable, "-nP", "-a", "-iTCP:#{port}", "-sTCP:LISTEN", "-Fpcn"
      )
      return nil if no_listener?(stdout, stderr, status)

      unless status.success?
        detail = stderr.to_s.strip
        message = "cannot inspect local Ollama listener"
        message = "#{message}: #{detail}" unless detail.empty?
        raise Error, message
      end

      parse_owner(stdout)
    rescue URI::InvalidURIError
      raise Error, "local Ollama endpoint is invalid"
    rescue SystemCallError => e
      raise Error, "cannot execute listener inspection #{@executable.inspect}: #{e.message}"
    end

    private

    def no_listener?(stdout, stderr, status)
      stdout.to_s.empty? && stderr.to_s.empty? && status.respond_to?(:exitstatus) && status.exitstatus == 1
    end

    def parse_owner(output)
      owners = []
      current = nil
      output.each_line do |line|
        field = line.chomp
        case field[0]
        when "p"
          current = { pid: integer_pid(field[1..]), command: nil }
          owners << current
        when "c"
          current[:command] = field[1..] if current
        end
      end
      owners.uniq! { |row| row.fetch(:pid) }
      return nil if owners.empty?
      raise Error, "local Ollama endpoint has multiple listening process owners" unless owners.length == 1

      row = owners.first
      Owner.new(pid: row.fetch(:pid), command: row.fetch(:command))
    end

    def integer_pid(value)
      pid = Integer(value, 10)
      raise Error, "listener inspection returned an invalid PID" unless pid.positive?

      pid
    rescue ArgumentError, TypeError
      raise Error, "listener inspection returned an invalid PID"
    end
  end
end
