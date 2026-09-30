# frozen_string_literal: true

require_relative "test_helper"

class MacOSHardwareProbeTest < Minitest::Test
  Status = Struct.new(:exitstatus) do
    def success? = exitstatus.zero?
  end

  def test_builds_provider_neutral_gpu_id_from_observed_hardware
    calls = []
    executor = lambda do |*argv|
      calls << argv
      [
        "Graphics/Displays:\n\n    Apple M4 Pro:\n\n      Chipset Model: Apple M4 Pro\n" \
          "      Total Number of Cores: 20\n      Metal Support: Metal 4\n",
        "",
        Status.new(0)
      ]
    end
    probe = LocalOllamaWorkers::MacOSHardwareProbe.new(
      executor:,
      executable: "/fixture/system_profiler"
    )

    assert_equal "Apple M4 Pro 20-core GPU", probe.gpu_id
    assert_equal [["/fixture/system_profiler", "SPDisplaysDataType"]], calls
  end

  def test_missing_or_ambiguous_hardware_evidence_fails_closed
    executor = ->(*) { ["Chipset Model: Apple M4 Pro\n", "", Status.new(0)] }
    probe = LocalOllamaWorkers::MacOSHardwareProbe.new(executor:)

    assert_raises(LocalOllamaWorkers::Error) { probe.gpu_id }
  end

  def test_system_profiler_failure_is_not_hardware_evidence
    executor = ->(*) { ["", "permission denied\n", Status.new(1)] }
    probe = LocalOllamaWorkers::MacOSHardwareProbe.new(executor:)

    error = assert_raises(LocalOllamaWorkers::Error) { probe.gpu_id }
    assert_includes error.message, "permission denied"
  end
end
