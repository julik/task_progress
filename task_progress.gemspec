# frozen_string_literal: true

require_relative "lib/task_progress/version"

Gem::Specification.new do |s|
  s.name = "task_progress"
  s.version = TaskProgress::VERSION
  s.authors = ["Julik Tarkhanov"]
  s.email = ["me@julik.nl"]
  s.summary = "Hierarchical progress tracking for task trees, in-process and across process boundaries"
  s.license = "MIT"
  s.homepage = "https://github.com/julik/task_progress"
  s.metadata = {
    "source_code_uri" => "https://github.com/julik/task_progress",
    "changelog_uri" => "https://github.com/julik/task_progress/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://github.com/julik/task_progress/blob/main/MANUAL.md",
    "rubygems_mfa_required" => "true"
  }
  s.required_ruby_version = ">= 3.4"

  s.files = Dir["lib/**/*.rb", "sig/generated/**/*.rbs", "js/*.{js,css,d.ts}", "js/package.json", "config/importmap.rb", "exe/*", "README.md", "MANUAL.md", "RECIPES.md", "PORTING.md", "CHANGELOG.md", "LICENSE*"]
  s.require_paths = ["lib"]
  s.bindir = "exe"
  s.executables = ["task_progress"]

  s.add_development_dependency "minitest", "~> 5.25"
  s.add_development_dependency "rake"
end
