# frozen_string_literal: true

class TaskProgress
  # Loaded only inside a Rails app: trees as job arguments (see JobSerializer), the
  # `task_progress_tree` helper in every view, the browser client at `/task_progress/js` (and on the
  # asset path, pinned in the import map when importmap-rails is in use, and exposed to Assiette as
  # `@task_progress` when that is), a route for the
  # cancel buttons - at `/task_progress/cancellations`, unless `config.task_progress.cancellations_path`
  # says elsewhere, or is nil for none - and `rails task_progress:vendor`
  class Railtie < ::Rails::Railtie
    config.task_progress = ActiveSupport::OrderedOptions.new
    config.task_progress.cancellations_path = "/task_progress/cancellations"
    # The browser client, as it is - an asset pipeline would fingerprint the file you import, and
    # leave the relative imports inside it pointing at names it does not serve
    config.task_progress.js_path = "/task_progress/js"
    # Pins `task_progress`, `task_progress/react` and the rest to it, when importmap-rails is in use
    config.task_progress.importmap = true
    # Exposes it to Assiette as `@task_progress`, when Assiette is in use
    config.task_progress.assiette = true
    # Where `rails task_progress:vendor` copies the client to, for a bundler to take it from
    config.task_progress.vendor_path = "vendor/javascript/task_progress"
    # Where pages get handed-off trees from, by the links TaskProgress.for_page hands out
    config.task_progress.trees_path = "/task_progress/trees"
    # Where handed-off trees are kept - a TaskProgress::RedisStreamStore, say. Unset, see TaskProgress.stream_store
    config.task_progress.stream_store = nil

    initializer "task_progress.config" do |app|
      TaskProgress.stream_store = app.config.task_progress.stream_store if app.config.task_progress.stream_store
      TaskProgress.trees_path = app.config.task_progress.trees_path if app.config.task_progress.trees_path
    end

    config.after_initialize { TaskProgress.tokens = TaskProgress::RailsDefaults.tokens }

    initializer "task_progress.jobs" do
      ActiveSupport.on_load(:active_job) { TaskProgress::JobSerializer.install }
    end

    initializer "task_progress.helper" do
      ActiveSupport.on_load(:action_view) { include TaskProgress::TurboHelper }
    end

    initializer "task_progress.assets" do |app|
      app.config.assets.paths << TaskProgress.js_path if app.config.respond_to?(:assets)
    end

    # Before importmap-rails draws the app's own pins, so that a pin of the same name there wins
    initializer "task_progress.importmap", before: "importmap" do |app|
      options = app.config.task_progress
      if app.config.respond_to?(:importmap) && options.importmap && options.js_path
        app.config.importmap.paths << File.expand_path("../../config/importmap.rb", __dir__)
      end
    end

    # Before the app's own initializers, where Assiette's generated one builds the handler and
    # exposes whatever is in `config.assiette.exposed`
    initializer "task_progress.assiette", before: :load_config_initializers do |app|
      if app.config.respond_to?(:assiette) && app.config.task_progress.assiette
        app.config.assiette.exposed["@task_progress"] = TaskProgress.js_path
      end
    end

    # A vendored copy is not updated with the gem - say so, rather than serve the old one
    config.after_initialize do |app|
      vendored = TaskProgress.vendored_js_version(app.root.join(app.config.task_progress.vendor_path).to_s)
      if vendored && vendored != TaskProgress::VERSION
        Rails.logger&.warn("task_progress #{TaskProgress::VERSION} is installed, but #{app.config.task_progress.vendor_path} has the client from #{vendored} - run `rails task_progress:vendor`")
      end
    end

    rake_tasks do
      namespace :task_progress do
        desc "Copy the browser client into config.task_progress.vendor_path, or DIR"
        task :vendor do
          dir = ENV["DIR"] || Rails.root.join(Rails.application.config.task_progress.vendor_path).to_s
          TaskProgress.vendor_js(dir)
          puts "The task_progress client #{TaskProgress::VERSION} is in #{dir}"
        end
      end
    end

    initializer "task_progress.routes" do |app|
      path = app.config.task_progress.cancellations_path
      if path
        app.routes.append do
          mount TaskProgress::CancellationsApp.new(store: Rails.cache, tokens: TaskProgress::RailsDefaults.tokens) => path
        end
      end
      trees = app.config.task_progress.trees_path
      if trees
        app.routes.append do
          mount TaskProgress::TreesApp.new(tokens: TaskProgress::RailsDefaults.tokens) => trees
        end
      end
      js = app.config.task_progress.js_path
      if js
        app.routes.append do
          mount Rack::Files.new(TaskProgress.js_path, {"cache-control" => "no-cache"}) => js
        end
      end
    end
  end
end
