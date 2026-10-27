# frozen_string_literal: true

class TaskProgress
  # Sends each batch to a Ractor::Port, as a deep frozen copy - for a tree built inside a
  # Ractor and mounted outside it: `mount << port.receive`. Ruby 4.0 and up only
  class RactorOutput
    def initialize(port)
      raise NotImplementedError, "TaskProgress supports Ractors from Ruby 4.0 - on #{RUBY_VERSION} they crash the VM" unless RACTORS
      @port = port
    end

    def call(batch, _log)
      @port.send(::Ractor.make_shareable(batch, copy: true))
    end
  end
end
