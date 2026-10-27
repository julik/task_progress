# frozen_string_literal: true

# The worker the "handoff" scenario starts: it adopts a tree handed off through Redis, and works
# on it until it is done - or killed, which is the point.
#   ruby examples/stream_worker.rb KEY [--speed 2.0]
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "task_progress"
require "redis-client"

key = ARGV.fetch(0)
speed = ARGV.include?("--speed") ? Float(ARGV[ARGV.index("--speed") + 1]) : 1.0
TaskProgress.stream_store = TaskProgress::RedisStreamStore.new(RedisClient.config(url: ENV.fetch("REDIS_URL", "redis://localhost:6379")).new_pool(size: 2))

TaskProgress.adopt(key, heartbeat: 0.25) do |root|
  root.note("worker pid #{Process.pid}")
  images = root.subtask("Thumbnails", total: 40, cancelable: true)
  40.times { |i| images.tick(message: "image-#{format("%02d", i + 1)}.jpg") && sleep(0.1 / speed) }
end
