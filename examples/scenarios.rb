# frozen_string_literal: true

require "task_progress"
require_relative "demo_job"

# Jobs for the bench (bin/dev), each made to put one part of TaskProgress under a light. A
# scenario starts its work in the background and returns the root to serve; `speed` scales
# every sleep, so the tests can run them all in a blink
module Scenarios
  Scenario = Data.define(:id, :title, :description, :start)

  ALL = []

  def self.define(id, title, description, &start)
    ALL << Scenario.new(id:, title:, description:, start:)
  end

  def self.find(id) = ALL.find { it.id == id }

  # Runs the root's work on a thread of its own, and hands back the root and the thread - the
  # bench cancels a job by raising Interrupt into that thread
  def self.background(root)
    thread = Thread.new do
      root.run { yield root }
    rescue Exception # rubocop:disable Lint/RescueException
      nil # the tree has the failure
    end
    [root, thread]
  end

  def self.napper(speed) = ->(seconds) { sleep(seconds / speed) }

  define "import", "Import (passes)", "The demo job: a counted download, worker threads, a task with no measure, an engine in a subprocess mounted under its own node." do |speed:|
    background(TaskProgress.new("Import catalogue", cancelable: true)) { DemoJob.run(it, speed:) }
  end

  define "import_fails", "Import (engine fails)", "The same job, but the engine subprocess raises halfway. Its error crosses the pipe, fails the mount and then the job." do |speed:|
    background(TaskProgress.new("Import catalogue", cancelable: true)) { DemoJob.run(it, speed:, fail: true) }
  end

  define "workers", "16 threads, one tree", "Sixteen threads tick their own counters as fast as they like. Thousands of batches - watch the stream inspector keep up, with no gaps." do |speed:|
    nap = napper(speed)
    background(TaskProgress.new("Crunch", cancelable: true)) do |root|
      workers = 16.times.map { root.subtask("worker #{it + 1}", total: 300, cancelable: true) }
      workers.map do |worker|
        Thread.new { worker.run { 300.times { |i| worker.tick!(message: "item #{i + 1}") && nap.(rand(0.002..0.02)) } } }
      end.each(&:join)
    end
  end

  define "wide", "120 tasks in random order", "A wide tree, filled in by eight threads picking tasks at random. Tests rendering many rows and the terminal's trimming." do |speed:|
    nap = napper(speed)
    background(TaskProgress.new("Wide")) do |root|
      queue = Queue.new
      120.times { queue << root.subtask("file-#{format("%03d", it)}.dat", total: rand(3..12)) }
      queue.close
      8.times.map do
        Thread.new do
          while (task = queue.pop)
            task.run { task.total.times { task.tick! && nap.(0.02) } }
          end
        end
      end.each(&:join)
    end
  end

  define "deep", "Six levels deep", "A deeply nested tree; every leaf counts, every parent is a weighted mean of its children." do |speed:|
    nap = napper(speed)
    build = lambda do |task, depth|
      if depth == 6
        task.run { 5.times { task.tick! && nap.(0.04) } }
      else
        children = rand(1..2).times.map { task.subtask("level #{depth + 1}.#{it + 1}", **(depth == 5 ? {total: 5} : {})) }
        task.run { children.each { build.(it, depth + 1) } }
      end
    end
    background(TaskProgress.new("Deep")) { |root| root.subtask("level 1") { build.(it, 1) } }
  end

  define "waiting", "Nothing to count", "Only indeterminate tasks: spinners, elapsed time and the latest note. A task with no measure counts for nothing until it is done." do |speed:|
    nap = napper(speed)
    background(TaskProgress.new("Waiting game")) do |root|
      steps = ["Polling the API", "Waiting for a lock", "Asking nicely"].map { root.subtask(it, indeterminate: true) }
      steps.map do |step|
        Thread.new { step.run { rand(3..6).times { |i| step.note("attempt #{i + 1}") && nap.(rand(0.3..0.8)) } } }
      end.each(&:join)
    end
  end

  define "transaction", "Transactions", "Every step hands over to the next in one transaction: the old one finishes and the new one starts in the same batch, so no frame ever shows two running, or none." do |speed:|
    nap = napper(speed)
    background(TaskProgress.new("Relay race")) do |root|
      legs = 8.times.map { root.subtask("leg #{it + 1}", total: 10) }
      root.transaction { legs.first.advance!(0) }
      legs.each_with_index do |leg, i|
        9.times { leg.tick! && nap.(0.05) }
        root.transaction do
          leg.tick!
          leg.done!("handed over")
          legs[i + 1]&.note("taking over")
        end
      end
    end
  end

  define "relay", "Squashed relay", "A tree in the background is relayed through BufferedOutput (0.5s windows) and PublishingOutput into a mount - like a job publishing to a Sossego stream. Each window arrives as one squashed batch of puts." do |speed:|
    nap = napper(speed)
    served = TaskProgress.new("Relayed")
    mount = served.mount("Background job (relayed)")
    stream = Struct.new(:mount) { def publish(_name, payload) = mount << payload }.new(mount)
    buffered = TaskProgress::BufferedOutput.new(TaskProgress::PublishingOutput.new(stream), interval: 0.5 / speed)
    source = TaskProgress.new("source", outputs: [buffered])
    background(served) do
      source.run do
        workers = 6.times.map { source.subtask("worker #{it + 1}", total: 60) }
        workers.map { |w| Thread.new { w.run { 60.times { w.tick! && nap.(rand(0.01..0.05)) } } } }.each(&:join)
      end
      nap.(0.6) until mount.finished?
    ensure
      buffered.close
    end
  end

  define "stale", "Gap, stale, recover", "A mount loses one batch on the way. It marks itself stale and ignores the rest until a fresh squash of the source arrives, and then it is whole again." do |speed:|
    nap = napper(speed)
    served = TaskProgress.new("Lossy link")
    mount = served.mount("Mirror of a remote tree")
    queue = Queue.new
    source = TaskProgress.new("remote", outputs: [->(batch, _) { queue << batch }])
    background(served) do
      feeder = Thread.new do
        while (batch = queue.pop)
          next if batch.seq == 25 # lost on the way
          mount << batch
          if mount.stale?
            nap.(2.0)
            mount << source.log.squashed
          end
        end
      end
      source.run do
        tasks = 3.times.map { source.subtask("stream #{it + 1}", total: 40) }
        40.times { tasks.each(&:tick!) && nap.(0.05) }
        tasks.each(&:done!)
      end
      nap.(0.3) until mount.finished?
      queue.close
      feeder.join
    end
  end

if TaskProgress::RACTORS
  define "ractors", "Ractors", "Four Ractors each build a tree of their own and send their batches out through a Ractor::Port as frozen copies; each is mounted here. Ruby 4.0 and up." do |speed:|
    Warning[:experimental] = false
    served = TaskProgress.new("Ractor pool")
    mounts = 4.times.map { served.mount("ractor #{it + 1}") }
    background(served) do
      port = Ractor::Port.new
      ractors = mounts.each_index.map do |n|
        Ractor.new(port, n, speed) do |port, n, speed|
          root = TaskProgress.new("worker #{n}", outputs: [TaskProgress::RactorOutput.new(port)])
          root.run do
            root.subtask("Crunch", total: 40) { |t| 40.times { t.tick! && sleep(rand(0.01..0.06) / speed) } }
          end
          port.send(:finished)
        end
      end
      by_log = {}
      finished = 0
      while finished < ractors.length
        message = port.receive
        next finished += 1 if message == :finished
        (by_log[message.log] ||= mounts[by_log.size]) << message
      end
      ractors.each(&:join)
    end
  end
end
end
