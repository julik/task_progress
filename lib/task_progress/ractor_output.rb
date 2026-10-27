# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # Sends each batch to a Ractor::Port, as a deep frozen copy - for a tree built inside a
  # Ractor and mounted outside it: `mount << port.receive`. Ruby 4.0 and up only
  class RactorOutput
    # @rbs @port: untyped - a Ractor::Port, which RBS does not know yet

    # Sends to a `Ractor::Port`. Raises NotImplementedError before Ruby 4.0
    #: (untyped) -> void
    def initialize(port)
      raise NotImplementedError, "TaskProgress supports Ractors from Ruby 4.0 - on #{RUBY_VERSION} they crash the VM" unless RACTORS
      @port = port
    end

    # Sends a deep frozen copy of the batch to the port
    #: (Batch, Log) -> void
    def call(batch, _log)
      @port.send(::Ractor.make_shareable(batch, copy: true))
    end
  end
end
