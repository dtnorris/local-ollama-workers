# frozen_string_literal: true

require_relative "test_helper"

class WorkerRecordTest < Minitest::Test
  include LowTestSupport

  def test_builder_canonicalizes_labels_and_models
    source = observation
    source["labels"] = %w[ollama local inference]
    first = source.dig("capabilities", "ollama", "models").first
    source.dig("capabilities", "ollama", "models") << first.merge(
      "model" => "another-model:latest",
      "digest" => "b" * 64
    )

    worker = LocalOllamaWorkers::WorkerRecord.build(source)

    assert_equal %w[inference local ollama], worker.fetch("labels")
    assert_equal %w[another-model:latest qualified-model:latest],
                 worker.dig("capabilities", "ollama", "models").map { |model| model.fetch("model") }
    assert_equal LocalOllamaWorkers::Contract.capability_fingerprint(worker),
                 worker.fetch("capability_fingerprint")
  end

  def test_duplicate_labels_and_model_identities_fail_closed
    duplicate_labels = observation
    duplicate_labels["labels"] << duplicate_labels.fetch("labels").first
    assert_raises(LocalOllamaWorkers::Error) do
      LocalOllamaWorkers::WorkerRecord.build(duplicate_labels)
    end

    duplicate_models = observation
    duplicate_models.dig("capabilities", "ollama", "models") << deep_copy(
      duplicate_models.dig("capabilities", "ollama", "models").first
    )
    assert_raises(LocalOllamaWorkers::Error) do
      LocalOllamaWorkers::WorkerRecord.build(duplicate_models)
    end
  end

  def test_every_fingerprint_input_changes_the_fingerprint
    baseline = LocalOllamaWorkers::WorkerRecord.build(observation)
    mutations = {
      "labels" => ->(worker) { worker["labels"] = %w[inference local ollama remote] },
      "gpu_id" => ->(worker) { worker.fetch("capabilities")["gpu_id"] = "changed" },
      "model" => ->(worker) { model(worker)["model"] = "changed:latest" },
      "digest" => ->(worker) { model(worker)["digest"] = "b" * 64 },
      "context_length" => ->(worker) { model(worker)["context_length"] = 65_536 },
      "fully_gpu_resident" => ->(worker) { model(worker)["fully_gpu_resident"] = false }
    }

    mutations.each do |name, mutate|
      changed = deep_copy(baseline)
      mutate.call(changed)
      refute_equal baseline.fetch("capability_fingerprint"),
                   LocalOllamaWorkers::Contract.capability_fingerprint(changed), name
    end
  end

  def test_non_fingerprint_fields_do_not_change_the_fingerprint
    baseline = LocalOllamaWorkers::WorkerRecord.build(observation)

    %w[worker_id generation_id endpoint state].each do |field|
      changed = deep_copy(baseline)
      changed[field] = field == "state" ? "NOT_READY" : "changed"
      assert_equal baseline.fetch("capability_fingerprint"),
                   LocalOllamaWorkers::Contract.capability_fingerprint(changed), field
    end
  end

  private

  def model(worker)
    worker.dig("capabilities", "ollama", "models").first
  end
end

