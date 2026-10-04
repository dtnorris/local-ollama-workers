# frozen_string_literal: true

require_relative "test_helper"

class ProviderIndependenceTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)
  RUBY_ROOTS = %w[bin lib test].freeze
  FORBIDDEN_RUNTIME_IMPORTS = [
    /adventure[_-]?finder/i,
    /(?:\A|[\/_-])rpof(?:\z|[\/_-])/i,
    /runpod[_-]ollama[_-]fleet/i,
    /workload[_-]orchestrator/i
  ].freeze

  def test_loaded_features_contain_no_sibling_implementation
    forbidden = $LOADED_FEATURES.grep(/(?:adventure[_-]finder|af[_-]workloads|workload[_-]orchestrator|runpod[_-]ollama[_-]fleet)/i)
    assert_empty forbidden
  end

  def test_ruby_dependency_graph_imports_neither_other_provider_nor_wlo_or_adventurefinder
    imports = RUBY_ROOTS.flat_map do |root|
      Dir[File.join(REPO_ROOT, root, "**", "*")].flat_map do |path|
        next [] unless File.file?(path)

        File.readlines(path, chomp: true).filter_map do |line|
          match = line.match(/^\s*require(?:_relative)?\s+["']([^"']+)["']/)
          [path.delete_prefix("#{REPO_ROOT}/"), match[1]] if match
        end
      end
    end

    violations = imports.select do |_path, required|
      FORBIDDEN_RUNTIME_IMPORTS.any? { |pattern| required.match?(pattern) }
    end
    assert_empty violations
  end
end
