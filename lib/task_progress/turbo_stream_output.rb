# frozen_string_literal: true
# rbs_inline: enabled

require "cgi/escape"

class TaskProgress
  # Draws the whole tree as HTML on every batch, as a Turbo Stream that replaces it in the page by
  # morphing, and hands that to `broadcast` - in Rails, Turbo::StreamsChannel, which reaches every
  # page subscribed with `turbo_stream_from`, whichever process the tree lives in. Put it behind a
  # BufferedOutput, as TaskProgress.broadcast does, and a spammy job is drawn a few times a second.
  #
  # The whole tree, every time: a Turbo Stream has no seq and no gaps to notice, so a page that
  # missed a frame - or joined late - is set right by the next one. Morphing touches only what
  # differs, so a bar's width eases rather than jumps.
  #
  # With a `store`, the latest frame is also written under `key`, for a page to draw the tree
  # before the first broadcast reaches it - see TurboHelper#task_progress_tree
  class TurboStreamOutput
    # @rbs!
    #   interface _Renderer
    #     def render: (State snapshot, ?path from) -> String
    #     def id: () -> String
    #   end
    #
    #   interface _Store
    #     def read: (String key) -> untyped
    #     def write: (String key, untyped value) -> void
    #     def delete: (String key) -> void
    #   end

    # The store key the latest frame is written under
    attr_reader :key #: String

    # @rbs @renderer: _Renderer
    # @rbs @broadcast: ^(String) -> void
    # @rbs @store: _Store?

    # Draws with `renderer`, and hands each frame - a `<turbo-stream>` element - to `broadcast`
    #: (renderer: _Renderer, broadcast: ^(String) -> void, ?store: _Store?, ?key: String) -> void
    def initialize(renderer:, broadcast:, store: nil, key: "task_progress/#{renderer.id}")
      @renderer = renderer
      @broadcast = broadcast
      @store = store
      @key = key
    end

    # Draws the tree as it stands - the batch only says it changed
    #: (Batch, Log) -> void
    def call(_batch, log)
      html = @renderer.render(log.snapshot)
      @store&.write(@key, html)
      @broadcast.call(TurboStreamOutput.frame(@renderer.id, html))
    end

    # A Turbo Stream that replaces the element `target` with `html`, morphing it
    #: (String, String) -> String
    def self.frame(target, html)
      %(<turbo-stream action="replace" method="morph" target="#{CGI.escapeHTML(target)}"><template>#{html}</template></turbo-stream>)
    end
  end
end
