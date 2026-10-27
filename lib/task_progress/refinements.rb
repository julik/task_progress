# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # `rows.each.with_progress("Importing") { }`, for the files that ask for it with
  # `using TaskProgress::Refinements` - a refinement rather than a patch, so nobody else's
  # Enumerable changes. See TaskProgress.iterate
  module Refinements
    refine Enumerable do
      #: (?String, **untyped) ?{ (untyped) -> untyped } -> untyped
      def with_progress(name = File.basename($PROGRAM_NAME), **, &) = TaskProgress.iterate(_ = self, name, **, &)
    end
  end
end
