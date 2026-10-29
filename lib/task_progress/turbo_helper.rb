# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # View helpers, in every view once the gem is in a Rails app
  module TurboHelper
    # The tree a job broadcasts with `TaskProgress.broadcast(record, ...)`, kept up to date: drawn
    # as it stood at its last frame, and subscribed to every frame after that. Needs turbo-rails,
    # and `task_tree.css` on the page - plus `task_progress_clock.js`, for elapsed times to tick
    #
    #     <%= task_progress_tree @csv_import %>
    #: (untyped, ?store: untyped) -> String
    def task_progress_tree(record, store: ::Rails.cache) # steep:ignore
      drawn = store.read(RailsDefaults.key(record)) || %(<div id="#{ERB::Util.html_escape(RailsDefaults.id(record))}" class="tree"></div>)
      safe_join([turbo_stream_from(record, :task_progress), drawn.html_safe]) # steep:ignore
    end
  end
end
