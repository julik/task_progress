# frozen_string_literal: true

class TaskProgress
  # Ractors on Ruby 3.4 corrupt the VM's table of call sites: a `super` from Ruby into a C
  # constructor (Data#initialize, say) while Ractors run brings the process down, sometimes
  # minutes later and in unrelated code. Ruby 4.0 has it fixed, and the Ractor::Port API with it
  RACTORS = RUBY_VERSION.split(".").first.to_i >= 4

  module Outputs
    # Sends each batch to a Ractor::Port, as a deep frozen copy - for a tree built inside a
    # Ractor and mounted outside it: `mount << port.receive`. Ruby 4.0 and up only
    class Ractor
      def initialize(port)
        raise NotImplementedError, "TaskProgress supports Ractors from Ruby 4.0 - on #{RUBY_VERSION} they crash the VM" unless RACTORS
        @port = port
      end

      def call(batch, _log)
        @port.send(::Ractor.make_shareable(batch, copy: true))
      end
    end
  end
end
