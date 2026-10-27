# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # What TaskProgress.broadcast and the `task_progress_tree` helper use when Rails is there and
  # nothing else is given: the record's dom_id, Turbo::StreamsChannel, Rails.cache, and tokens
  # signed with a key the app's secret_key_base derives. Without Rails, nothing - and the caller
  # says what to broadcast to. The record is streamed to as `[record, :task_progress]`
  module RailsDefaults # :nodoc:
    class << self
      # The id the tree's element has, for a record or a string
      #: (untyped) -> String
      def id(target)
        return target.to_s if target.is_a?(String) || target.is_a?(Symbol) || !rails?
        ActionView::RecordIdentifier.dom_id(target, :task_progress) # steep:ignore
      end

      # The store key the latest frame is kept under
      #: (untyped) -> String
      def key(target) = "task_progress/#{id(target)}"

      # The defaults for what is not given, or nothing outside Rails
      #: (untyped) -> Hash[Symbol, untyped]
      def for(target)
        return {} unless rails?
        defaults = {store: ::Rails.cache, tokens:, cancel_url: cancellations_path} # steep:ignore
        return defaults unless defined?(::Turbo::StreamsChannel)
        defaults.merge(to: ->(html) { ::Turbo::StreamsChannel.broadcast_stream_to(target, :task_progress, content: html) }) # steep:ignore
      end

      # Tokens for the cancel buttons, signed with a key derived from the app's secret
      #: () -> CancelToken
      def tokens
        CancelToken.new(::Rails.application.key_generator.generate_key("task_progress cancellations")) # steep:ignore
      end

      # Where the cancel buttons post, or nil when the app has turned that off
      #: () -> String?
      def cancellations_path = (::Rails.application.config.task_progress.cancellations_path if rails?) # steep:ignore

      # Whether this runs in a Rails app
      #: () -> bool
      def rails? = !!(defined?(::Rails.application) && ::Rails.application) # steep:ignore
    end
  end
end
