# frozen_string_literal: true

# The "engine" the demos run in a subprocess. It reports through TaskProgress.cli, so run on its
# own it draws in the terminal, and spawned by Mount#spawn it writes batches up the pipe instead.
#   ruby -Ilib examples/child_worker.rb [--fail] [--speed 2.0]
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "task_progress"

speed = ARGV.include?("--speed") ? Float(ARGV[ARGV.index("--speed") + 1]) : 1.0
nap = ->(seconds) { sleep(seconds / speed) }
entries = %w[chapter01.xhtml chapter02.xhtml chapter03.xhtml cover.jpg figure-1.png figure-2.webp nav.xhtml]

TaskProgress.cli("engine (pid #{Process.pid})") do |root|
  unpack = root.subtask("Unpacking", total: 4 * 1024 * 1024, unit: "bytes")
  marks = root.subtask("Watermarking", total: entries.length, weight: 3, cancelable: true) # from the parent too, over the control pipe
  repack = root.subtask("Repacking")

  unpack.run { 16.times { unpack.advance!(256 * 1024) && nap.(0.05) } }
  marks.run do
    entries.each_with_index do |entry, i|
      raise ArgumentError, "Simulated failure on #{entry}" if ARGV.include?("--fail") && i == 4
      marks.tick!(message: "Watermarking #{entry}")
      nap.(0.25)
    end
  end
  repack.run { (0..99).step(5) { repack.update_to(percent: it, message: "Storing") && nap.(0.03) } }
end
