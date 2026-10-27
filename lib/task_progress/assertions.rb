# frozen_string_literal: true
# rbs_inline: enabled

require "pp"

class TaskProgress
  # Assertions for Minitest - and ActiveSupport::TestCase, which is Minitest underneath - about
  # what work reported. Each failure shows the whole tree, see TaskProgress#outline.
  #
  #     class ImportTest < Minitest::Test
  #       include TaskProgress::Assertions
  #
  #       def test_import
  #         import = TaskProgress.new("Import")
  #         Importer.new(progress: import).run
  #         assert_task_done import
  #         assert_task_failed import.subtasks.first, with: /row 12/
  #       end
  #     end
  module Assertions
    # @rbs!
    #   def assert: (untyped, ?String) -> void

    # The task is done, and everything under it ended
    #: (TaskProgress, ?String?) -> void
    def assert_task_done(task, message = nil)
      assert task.done?, message || "Expected '#{task.name}' to be done, but it is #{task.status}#{TaskProgress::Assertions.tree(task)}"
    end

    # The task failed - with an error whose message matches `with`, if given
    #: (TaskProgress, ?with: (String | Regexp)?, ?message: String?) -> void
    def assert_task_failed(task, with: nil, message: nil)
      error = task.error
      matched = with.nil? || (with.is_a?(Regexp) ? with.match?(error&.dig(:message).to_s) : error&.dig(:message) == with)
      assert task.failed? && matched,
        message || "Expected '#{task.name}' to have failed#{" with #{with.inspect}" if with}, but it is #{task.status}#{" with #{error[:message].inspect}" if error}#{TaskProgress::Assertions.tree(task)}"
    end

    # The task was canceled
    #: (TaskProgress, ?String?) -> void
    def assert_task_canceled(task, message = nil)
      assert task.canceled?, message || "Expected '#{task.name}' to have been canceled, but it is #{task.status}#{TaskProgress::Assertions.tree(task)}"
    end

    # The tree, as a failure message ends with it
    #: (TaskProgress) -> String
    def self.tree(task) = "\n\n#{PP.pp(task.root.outline, +"", 100)}"
  end
end
