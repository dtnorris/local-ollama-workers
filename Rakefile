# frozen_string_literal: true

require "minitest/test_task"

Minitest::TestTask.create do |task|
  task.test_globs = ["test/**/*_test.rb"]
end

desc "Lint production Ruby"
task :lint do
  sh "bundle", "exec", "rubocop", "--config", ".rubocop.yml", "Rakefile", "bin", "lib"
end

desc "Check structural Minitest quality"
task "test:lint" do
  sh "bundle", "exec", "rubocop", "--config", ".rubocop-test.yml", "test"
end

desc "Run tests and lint checks"
task "test:contract" => ["test", "test:lint"] do
  Rake::Task["lint"].invoke
end

task default: "test:contract"
