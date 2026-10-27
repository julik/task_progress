# frozen_string_literal: true

class TaskProgress
  # Loaded only inside a Rails app: trees as job arguments (see JobSerializer), the
  # `task_progress_tree` helper in every view, the browser client at `/task_progress/js` (and on the
  # asset path), and a route for the cancel buttons - at `/task_progress/cancellations`, unless
  # `config.task_progress.cancellations_path` says elsewhere, or is nil for none
  class Railtie < ::Rails::Railtie
    config.task_progress = ActiveSupport::OrderedOptions.new
    config.task_progress.cancellations_path = "/task_progress/cancellations"
    # The browser client, as it is - an asset pipeline would fingerprint the file you import, and
    # leave the relative imports inside it pointing at names it does not serve
    config.task_progress.js_path = "/task_progress/js"

    initializer "task_progress.jobs" do
      ActiveSupport.on_load(:active_job) { TaskProgress::JobSerializer.install }
    end

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
      js = app.config.task_progress.js_path
      app.routes.append do
        mount Rack::Files.new(TaskProgress.js_path, {"cache-control" => "no-cache"}) => js
      end if js
    end
  end
end
