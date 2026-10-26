# frozen_string_literal: true

require_relative "lib/task_progress/version"

Gem::Specification.new do |s|
  s.name = "task_progress"
  s.version = TaskProgress::VERSION
  s.authors = ["Julik Tarkhanov"]
  s.email = ["me@julik.nl"]
  s.summary = "Hierarchical progress tracking for task trees, in-process and across process boundaries"
  s.license = "MIT"
  s.required_ruby_version = ">= 3.4"

  s.files = Dir["lib/**/*.rb", "README.md", "LICENSE*"]
  s.require_paths = ["lib"]

  s.add_dependency "progressive_io", "~> 2.0"

  s.add_development_dependency "minitest", "~> 5.25"
  s.add_development_dependency "rake"
end
