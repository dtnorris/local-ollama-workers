# frozen_string_literal: true

require "open3"

module LocalOllamaWorkers
  class MacOSHardwareProbe
    SYSTEM_PROFILER = "/usr/sbin/system_profiler"

    def initialize(executor: Open3.method(:capture3), executable: SYSTEM_PROFILER)
      @executor = executor
      @executable = executable
    end

    def gpu_id
      stdout, stderr, status = @executor.call(@executable, "SPDisplaysDataType")
      unless status.success?
        detail = stderr.to_s.strip
        message = "cannot inspect local accelerator identity"
        message = "#{message}: #{detail}" unless detail.empty?
        raise Error, message
      end

      models = stdout.scan(/^\s*Chipset Model:\s*(.+?)\s*$/).flatten
      core_counts = stdout.scan(/^\s*Total Number of Cores:\s*(\d+)\s*$/).flatten
      unique = models.length == 1 && core_counts.length == 1
      raise Error, "cannot establish one concrete local accelerator identity" unless unique

      model = Contract.nonempty!(models.first, "local accelerator model", max: 192)
      cores = Integer(core_counts.first, 10)
      raise Error, "local accelerator core count must be positive" unless cores.positive?

      Contract.nonempty!("#{model} #{cores}-core GPU", "local gpu_id", max: 256)
    rescue SystemCallError => e
      raise Error, "cannot execute accelerator inspection #{@executable.inspect}: #{e.message}"
    rescue ArgumentError
      raise Error, "local accelerator core count must be a positive integer"
    end
  end
end
