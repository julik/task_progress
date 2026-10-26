# frozen_string_literal: true

class TaskProgress
  # Where batches go. An output is anything with `call(batch, log)`; it gets every batch the
  # log commits, in order, and may read `log.snapshot` for the tree as it now stands
  module Outputs
  end
end

require_relative "outputs/summary"
require_relative "outputs/ndjson"
require_relative "outputs/publish"
require_relative "outputs/buffered"
require_relative "outputs/ractor"
require_relative "outputs/terminal"
