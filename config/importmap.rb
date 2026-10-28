# Drawn into the app's import map by the Railtie when importmap-rails is in use, before the app's
# own config/importmap.rb - so a pin of the same name there wins. The files are pinned where the
# Railtie serves them as they are: through the asset pipeline they would be fingerprinted, and
# the relative imports between them would point at names it does not serve
js = Rails.application.config.task_progress.js_path

{
  "task_progress" => "task_tree.js",
  "task_progress/react" => "react_task_tree.js",
  "task_progress/stimulus" => "stimulus_controller.js",
  "task_progress/local_tasks" => "local_tasks.js",
  "task_progress/row_view" => "row_view.js",
  "task_progress/clock" => "task_progress_clock.js"
}.each do |name, file|
  # Not preloaded: the React and Stimulus parts import what only some pages have
  pin name, to: "#{js}/#{file}", preload: false, integrity: false
end
