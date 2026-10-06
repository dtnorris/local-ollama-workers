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
  SIBLING_IMPLEMENTATION_PATTERN =
    /(?:adventure[_-]finder|af[_-]workloads|workload[_-]orchestrator|runpod[_-]ollama[_-]fleet)/i

  def test_loaded_features_contain_no_sibling_implementation
    assert_empty sibling_implementation_features($LOADED_FEATURES)
  end

  def test_loaded_feature_boundary_excludes_own_root_and_rejects_sibling
    Dir.mktmpdir("adventure-finder-components-") do |component_root|
      repo_root = File.join(component_root, "local-ollama-workers")
      own_feature = write_loaded_feature(repo_root, "low_provider_independence_fixture")
      sibling_feature = write_loaded_feature(
        File.join(component_root, "runpod-ollama-fleet"),
        "rpof_provider_independence_fixture"
      )
      require own_feature
      require sibling_feature

      loaded_fixtures = $LOADED_FEATURES.grep(/provider_independence_fixture/)
      assert_equal [sibling_feature],
                   sibling_implementation_features(loaded_fixtures, repo_root: repo_root)
    ensure
      $LOADED_FEATURES.delete_if { |feature| feature.match?(/provider_independence_fixture/) }
    end
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

  private

  def sibling_implementation_features(loaded_features, repo_root: REPO_ROOT)
    resolved_repo_root = File.realpath(repo_root)
    loaded_features.reject { |feature| contained_by?(feature, resolved_repo_root) }
                   .grep(SIBLING_IMPLEMENTATION_PATTERN)
  end

  def contained_by?(feature, resolved_repo_root)
    resolved_feature = File.realpath(feature)
    resolved_feature == resolved_repo_root || resolved_feature.start_with?("#{resolved_repo_root}/")
  rescue Errno::ENOENT, Errno::ENOTDIR
    false
  end

  def write_loaded_feature(root, basename)
    FileUtils.mkdir_p(File.join(root, "lib"))
    path = File.join(root, "lib", "#{basename}.rb")
    File.write(path, "# provider-independence fixture\n")
    path
  end
end
