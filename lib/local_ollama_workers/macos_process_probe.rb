# frozen_string_literal: true

require "fiddle"

module LocalOllamaWorkers
  class MacOSProcessProbe
    ProcessInfo = Struct.new(:pid, :start_time_usec, :executable_path, keyword_init: true)

    def initialize(backend: nil, platform: RUBY_PLATFORM)
      @backend = backend || LibprocBackend.new(platform:)
    end

    def info(pid)
      raw = @backend.info(Integer(pid))
      return nil unless raw

      observed_pid = Integer(raw.fetch(:pid))
      start_time_usec = Integer(raw.fetch(:start_time_usec))
      executable_path = raw.fetch(:executable_path).to_s
      return nil unless observed_pid == Integer(pid)
      return nil unless start_time_usec.positive? && !executable_path.empty?

      ProcessInfo.new(pid: observed_pid, start_time_usec:, executable_path:)
    rescue ArgumentError, TypeError, KeyError
      nil
    end

    class LibprocBackend
      PROC_PIDTBSDINFO = 3
      BSD_INFO_SIZE = 136
      PID_OFFSET = 12
      START_TIME_OFFSET = 120
      PID_PATH_BUFFER_SIZE = 4096
      LIBPROC = "/usr/lib/libproc.dylib"

      def initialize(platform: RUBY_PLATFORM)
        raise Error, "local Ollama process observation requires macOS" unless platform.include?("darwin")

        library = Fiddle.dlopen(LIBPROC)
        @proc_pidinfo = Fiddle::Function.new(
          library["proc_pidinfo"],
          [Fiddle::TYPE_INT, Fiddle::TYPE_INT, Fiddle::TYPE_LONG_LONG, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
          Fiddle::TYPE_INT
        )
        @proc_pidpath = Fiddle::Function.new(
          library["proc_pidpath"],
          [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
          Fiddle::TYPE_INT
        )
      rescue Fiddle::DLError => e
        raise Error, "cannot load macOS process inspection API: #{e.message}"
      end

      def info(pid)
        buffer = Fiddle::Pointer.malloc(BSD_INFO_SIZE)
        bytes = @proc_pidinfo.call(pid, PROC_PIDTBSDINFO, 0, buffer, BSD_INFO_SIZE)
        return nil unless bytes == BSD_INFO_SIZE

        observed_pid = buffer[PID_OFFSET, 4].unpack1("L")
        start_sec, start_usec = buffer[START_TIME_OFFSET, 16].unpack("Q2")
        path = process_path(pid)
        return nil unless path

        {
          pid: observed_pid,
          start_time_usec: (start_sec * 1_000_000) + start_usec,
          executable_path: path
        }
      end

      private

      def process_path(pid)
        buffer = Fiddle::Pointer.malloc(PID_PATH_BUFFER_SIZE)
        bytes = @proc_pidpath.call(pid, buffer, PID_PATH_BUFFER_SIZE)
        return nil unless bytes.positive?

        buffer.to_s(bytes).split("\0", 2).first
      end
    end
  end
end
