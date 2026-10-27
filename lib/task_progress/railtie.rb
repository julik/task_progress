# frozen_string_literal: true

class TaskProgress
  # Loaded only inside a Rails app: the `task_progress_tree` helper in every view, `js/` on the
  # asset path, and a route for the cancel buttons - at `/task_progress/cancellations`, unless
  # `config.task_progress.cancellations_path` says elsewhere, or is nil for none
  class Railtie < ::Rails::Railtie
    config.task_progress = ActiveSupport::OrderedOptions.new
    config.task_progress.cancellations_path = "/task_progress/cancellations"

    initializer "task_progress.helper" do
      ActiveSupport.on_load(:action_view) { include TaskProgress::TurboHelper }
    end

    initializer "task_progress.assets" do |app|
      app.config.assets.paths << TaskProgress.js_path if app.config.respond_to?(:assets)
    end

    initializer "task_progress.routes" do |app|
      path = app.config.task_progress.cancellations_path
      app.routes.append do
        mount TaskProgress::CancellationsApp.new(store: Rails.cache, tokens: TaskProgress::RailsDefaults.tokens) => path
      end if path
    end
  end
end
