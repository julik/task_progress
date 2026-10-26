# frozen_string_literal: true

# The demo job in a terminal: a redrawn tree on a TTY, plain lines when piped.
#   ruby -Ilib examples/cli_demo.rb [--fail] [--speed 2.0]
#   ruby -Ilib examples/cli_demo.rb | cat
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "task_progress"
require_relative "demo_job"

speed = ARGV.include?("--speed") ? Float(ARGV[ARGV.index("--speed") + 1]) : 1.0
TaskProgress.cli("Import catalogue") do |root|
  DemoJob.run(root, fail: ARGV.include?("--fail"), speed:)
end
