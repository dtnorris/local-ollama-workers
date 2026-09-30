# frozen_string_literal: true

require "json"

module LocalOllamaWorkers
  class WorkerRecord
    def self.build(observation)
      Contract.exact_keys!(observation, Contract::OBSERVATION_KEYS, "worker observation")
      record = JSON.parse(JSON.generate(observation))
      labels = record.fetch("labels")
      raise Error, "worker observation labels must be unique" unless labels.is_a?(Array) && labels.uniq == labels

      labels.sort!

      models = record.dig("capabilities", "ollama", "models")
      raise Error, "worker observation models must be an array" unless models.is_a?(Array)

      names = models.filter_map { |model| model["model"] if model.is_a?(Hash) }
      unless names.length == models.length && names.uniq == names
        raise Error,
              "worker observation model identifiers must be unique"
      end

      models.sort_by! { |model| Contract.canonical_model_key(model) }

      record["capability_fingerprint"] = Contract.capability_fingerprint(record)
      Contract.validate_worker!(record)
      record
    rescue JSON::GeneratorError, JSON::ParserError, KeyError, TypeError, ArgumentError => e
      raise Error, "invalid worker observation: #{e.message}"
    end
  end
end
