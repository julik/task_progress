# frozen_string_literal: true

# ActiveJob's own serializers name Duration, DateTime and the rest as they load, and only Rails
# loads those first - so outside Rails all of ActiveSupport has to come along
require "active_support/all"
require "active_job"

class TaskProgress
  # Lets a tree from TaskProgress.handoff go to an ActiveJob as an argument like any other - no
  # ids to pass, nothing to look up:
  #
  #     progress = TaskProgress.handoff("Importing", cancelable: true)
  #     ImportJob.perform_later(csv_import, progress)
  #
  #     class ImportJob < ApplicationJob
  #       def perform(csv_import, progress)
  #         progress.subtask("Rows", total: csv_import.rows.size) { |rows| ... }
  #       end
  #     end
  #
  # It goes into the queue as its key. Out of the queue it comes adopted - see TaskProgress.adopt -
  # and the job's work is the root's: done when `perform` returns, failed when it raises, and a
  # cancel stops it without failing the job. A retry adopts it anew, as attempt 2, and starts
  # it over. The Railtie installs all of this; without Rails, call `install` once ActiveJob loads.
  #
  # Only a root that was handed off can go: a task that lives in this process alone has nowhere
  # for a worker elsewhere to write to
  class JobSerializer < ActiveJob::Serializers::ObjectSerializer
    # Teaches ActiveJob to take trees as arguments, and runs every job that gets one as the tree's work
    def self.install
      ActiveJob::Serializers.add_serializers(self)
      ActiveJob::Base.prepend(Performing)
      ActiveJob::Base.around_perform do |job, perform|
        TaskProgress.working_on(job.arguments) do
          perform.call
          # A `before_perform` that halts stops the chain inside this one: the work never ran
          job.task_progress_halted!
        end
      end
    end

    # Arguments are taken up as they are deserialized, which is before `around_perform` - and a job
    # can stop in between: an argument that cannot be found, a `before_perform` that halts. Every
    # tree taken up for a job is seen to the end once the job is through, whatever became of it,
    # so none of them is left beating for work that is not being done
    module Performing
      # A callback halted the job - ActiveSupport says so through this hook
      def halted_callback_hook(*)
        @task_progress_halted = true
        super
      end

      # Fails the trees the job took up, if a callback halted it before its work
      def task_progress_halted!
        return unless @task_progress_halted
        arguments.flat_map { it.is_a?(Hash) ? it.values : [it] }.grep(TaskProgress).each do |root|
          root.fail!("The job stopped before it began its work") unless root.finished?
        end
      end

      # Runs the job, and ends what it took up and did not end
      def perform_now
        (Thread.current[:task_progress_adopted] ||= []).push([])
        super
      ensure
        adopted = Thread.current[:task_progress_adopted]&.pop || []
        adopted.each do |root|
          root.fail!($! || "The job stopped before it began its work") unless root.finished?
          root.log.close
        end
      end
    end

    # Whether it is a TaskProgress
    def serialize?(argument) = argument.is_a?(TaskProgress)

    # Its key, and nothing else
    def serialize(task)
      key = task.key or raise ActiveJob::SerializationError,
        "#{task.inspect} lives in this process alone - hand a tree to a job with TaskProgress.handoff"
      super("key" => key)
    end

    # The tree at the key, adopted
    def deserialize(hash)
      TaskProgress.adopt(hash.fetch("key")).tap { Thread.current[:task_progress_adopted]&.last&.push(it) }
    end

    # What it serializes
    def klass = TaskProgress
  end
end
