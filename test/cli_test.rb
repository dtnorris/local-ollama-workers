# frozen_string_literal: true

require_relative "test_helper"

class CLITest < Minitest::Test
  include LowTestSupport

  REPO_ROOT = File.expand_path("..", __dir__)
  MODEL = "fixture-model:latest"
  DIGEST = "a" * 64

  class Observer
    def initialize(identity)
      @identity = identity
    end

    def observe = @identity
  end

  class Client
    attr_reader :endpoint, :preloads, :pulls, :configuration_changes
    attr_accessor :installed, :running

    def initialize
      @endpoint = "http://127.0.0.1:11434"
      @preloads = []
      @pulls = []
      @configuration_changes = []
      @installed = [{ "model" => MODEL, "digest" => DIGEST }]
      @running = [running_model]
    end

    def version = "0.33.0"
    def installed_models = installed
    def running_models = running

    def preload!(model:, context_length:)
      @preloads << [model, context_length]
    end

    def pull!(model)
      @pulls << model
    end

    def configure!(configuration)
      @configuration_changes << configuration
    end

    private

    def running_model
      {
        "model" => MODEL,
        "digest" => DIGEST,
        "context_length" => 131_072,
        "fully_gpu_resident" => true,
        "runtime_size_bytes" => 30_000,
        "runtime_size_vram_bytes" => 30_000
      }
    end
  end

  class HardwareProbe
    def gpu_id = "Apple M4 Pro 20-core GPU"
  end

  def test_workers_json_emits_only_one_complete_snapshot_and_advances_revision
    with_tmpdir do |root|
      first_stdout, first_stderr, first_status = run_cli(root, "workers", "--json")
      second_stdout, second_stderr, second_status = run_cli(root, "workers", "--json")
      first = JSON.parse(first_stdout)
      second = JSON.parse(second_stdout)

      assert first_status.success?, first_stderr
      assert second_status.success?, second_stderr
      assert_empty first_stderr
      assert_empty second_stderr
      assert_equal 1, first_stdout.lines.length
      assert_equal 1, second_stdout.lines.length
      assert_equal LocalOllamaWorkers::Contract::VERSION, first.fetch("contract_version")
      assert_empty first.fetch("workers")
      assert_equal first.fetch("registry_id"), second.fetch("registry_id")
      assert_equal first.fetch("revision") + 1, second.fetch("revision")
    end
  end

  def test_invalid_arguments_fail_with_stderr_and_no_stdout
    with_tmpdir do |root|
      stdout, stderr, status = run_cli(root, "workers")

      refute status.success?
      assert_equal 2, status.exitstatus
      assert_empty stdout
      assert_includes stderr, "Usage: bin/low workers --json"
    end
  end

  def test_malformed_publisher_state_fails_with_nonzero_status
    with_tmpdir do |root|
      File.write(File.join(root, LocalOllamaWorkers::PublisherState::STATE_FILE), "{bad\n")
      stdout, stderr, status = run_cli(root, "workers", "--json")

      refute status.success?
      assert_equal 1, status.exitstatus
      assert_empty stdout
      assert_includes stderr, "ERROR: could not advance registry publication"
    end
  end

  def test_bootstrap_requires_only_the_generic_capability_request_option
    with_tmpdir do |root|
      client = Client.new
      legacy_path = File.join(root, "legacy.json")
      File.write(legacy_path, JSON.generate(legacy_requirement_document))

      [
        ["bootstrap", "--model", MODEL, "--context-length", "131072", "--json"],
        ["bootstrap", "--requirement", legacy_path, "--json"]
      ].each do |arguments|
        stdout = StringIO.new
        stderr = StringIO.new
        status = LocalOllamaWorkers::CLI.run(
          arguments,
          env: {"LOW_STATE_ROOT" => root},
          stdout:,
          stderr:,
          components: {client:}
        )

        assert_equal 2, status, arguments.join(" ")
        assert_empty stdout.string, arguments.join(" ")
        assert_includes stderr.string, "--capability-request", arguments.join(" ")
      end
      assert_empty client.preloads
    end
  end

  def test_generic_bootstrap_path_rejects_legacy_adventurefinder_input
    with_tmpdir do |root|
      path = File.join(root, "legacy.json")
      File.write(path, JSON.generate(legacy_requirement_document))
      client = Client.new
      stdout = StringIO.new
      stderr = StringIO.new

      status = LocalOllamaWorkers::CLI.run(
        ["bootstrap", "--capability-request", path, "--json"],
        env: {"LOW_STATE_ROOT" => root},
        stdout:,
        stderr:,
        components: {client:}
      )

      assert_equal 1, status
      assert_empty stdout.string
      assert_includes stderr.string, "Ollama capability request unknown fields"
      assert_empty client.preloads
    end
  end

  def test_bootstrap_then_workers_publishes_one_contract_valid_worker
    with_tmpdir do |root|
      identity = local_identity
      observer = Observer.new(identity)
      client = Client.new
      store = LocalOllamaWorkers::CapabilityEvidenceStore.new(root:)
      bootstrap_stdout = StringIO.new
      request_path = File.join(root, "capability-request.json")
      File.write(request_path, JSON.generate(capability_request_document))

      bootstrap_status = LocalOllamaWorkers::CLI.run(
        ["bootstrap", "--capability-request", request_path, "--json"],
        env: { "LOW_STATE_ROOT" => root },
        stdout: bootstrap_stdout,
        stderr: StringIO.new,
        components: {
          observer:,
          client:,
          hardware_probe: HardwareProbe.new,
          evidence_store: store
        }
      )
      workers_stdout = StringIO.new
      preloads_before_publication = client.preloads.dup
      evidence_before_publication = File.binread(
        File.join(root, LocalOllamaWorkers::CapabilityEvidenceStore::EVIDENCE_FILE)
      )
      workers_status = LocalOllamaWorkers::CLI.run(
        ["workers", "--json"],
        env: { "LOW_STATE_ROOT" => root },
        stdout: workers_stdout,
        stderr: StringIO.new,
        components: {
          observer:,
          client:,
          evidence_store: store
        }
      )
      evidence = JSON.parse(bootstrap_stdout.string)
      snapshot = JSON.parse(workers_stdout.string)
      worker = snapshot.fetch("workers").first

      assert_equal 0, bootstrap_status
      assert_equal 0, workers_status
      assert_equal [[MODEL, 131_072]], client.preloads
      assert_equal preloads_before_publication, client.preloads
      assert_empty client.pulls
      assert_empty client.configuration_changes
      assert_equal evidence_before_publication,
                   File.binread(File.join(root, LocalOllamaWorkers::CapabilityEvidenceStore::EVIDENCE_FILE))
      assert_equal identity.fetch("generation_id"), evidence.fetch("generation_id")
      assert_equal %w[inference local ollama], worker.fetch("labels")
      assert_equal "Apple M4 Pro 20-core GPU", worker.dig("capabilities", "gpu_id")
      assert_equal 131_072, worker.dig("capabilities", "ollama", "models", 0, "context_length")
      assert_equal true, worker.dig("capabilities", "ollama", "models", 0, "fully_gpu_resident")
      assert_equal LocalOllamaWorkers::Contract.capability_fingerprint(worker),
                   worker.fetch("capability_fingerprint")
      assert_equal snapshot, LocalOllamaWorkers::Contract.validate_snapshot!(snapshot)
    end
  end

  def test_malformed_capability_evidence_cannot_publish_false_ready
    with_tmpdir do |root|
      path = File.join(root, LocalOllamaWorkers::CapabilityEvidenceStore::EVIDENCE_FILE)
      File.binwrite(path, "{not-json\n")
      stdout = StringIO.new
      stderr = StringIO.new

      status = LocalOllamaWorkers::CLI.run(
        ["workers", "--json"],
        env: { "LOW_STATE_ROOT" => root },
        stdout:,
        stderr:,
        components: {
          observer: Observer.new(local_identity),
          client: Client.new,
          evidence_store: LocalOllamaWorkers::CapabilityEvidenceStore.new(root:)
        }
      )

      assert_equal 1, status
      assert_empty stdout.string
      assert_includes stderr.string, "could not read local capability evidence"
      refute File.exist?(File.join(root, LocalOllamaWorkers::PublisherState::STATE_FILE))
    end
  end

  private

  def run_cli(state_root, *arguments)
    Open3.capture3(
      { "LOW_STATE_ROOT" => state_root },
      RbConfig.ruby,
      File.join(REPO_ROOT, "bin", "low"),
      *arguments,
      chdir: REPO_ROOT
    )
  end

  def local_identity
    {
      "worker_id" => "local-ollama-1",
      "generation_id" => "low-macos-#{"a" * 64}",
      "endpoint" => "http://127.0.0.1:11434"
    }
  end

  def capability_request_document
    {
      "contract_version" => "ollama-capability-request/v0.1",
      "ollama" => {
        "model" => MODEL,
        "expected_digest" => DIGEST,
        "required_context_length" => 131_072,
        "require_fully_gpu_resident" => true,
        "required_gpu_id" => "Apple M4 Pro 20-core GPU"
      }
    }
  end

  def legacy_requirement_document
    capability_request_document.merge(
      "contract_version" => "adventurefinder-model-requirement/v0.1",
      "batch_handle" => "39",
      "production_batch_id" => "production-batch-039",
      "plan_id" => "production-batch-039",
      "plan_sha256" => "d" * 64,
      "alias" => "qwen27",
      "pool_id" => "qwen27",
      "required_labels" => ["inference"]
    )
  end
end
