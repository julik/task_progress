# frozen_string_literal: true

# The bench: bin/dev, or bundle exec rackup examples/web/config.ru
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("..", __dir__)
require_relative "app"

run BenchApp.new
