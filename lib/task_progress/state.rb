# frozen_string_literal: true
# rbs_inline: enabled

class TaskProgress
  # The tree as it stands after a run of events: what `apply` folds them into. It checks every
  # event before it changes anything, so a bad one raises and leaves the state as it was. Not
  # thread-safe on its own - the Log holds its lock around every apply
  class State
    # What an `open` or a `meta` may set
    ATTRIBUTES = %i[name total weight expect indeterminate unit cancelable].freeze #: Array[Symbol]
    CHILD_IDS = 36**4 #: Integer - four base36 characters
    ENDINGS = {done: :done, fail: :failed, cancel: :canceled}.freeze #: Hash[Symbol, Symbol]
    # What a `put` carries - a Node, less what never goes over the wire
    FIELDS = %i[name total count percent weight expect indeterminate unit cancelable message status error stale
      opened_at started_at finished_at].freeze #: Array[Symbol]
    private_constant :CHILD_IDS, :ENDINGS

    # @rbs @nodes: Hash[path, Node]

    # A new node, opened at `at`, before its attributes are set
    #: (Float) -> Node
    def self.blank_node(at) = Node.new(name: "", count: 0, percent: 0, weight: 1.0, status: :pending, opened_at: at, children: [])

    # Folding the squash of a state gives that state back, which is what makes a squashed log
    # interchangeable with the one it came from
    #: (Array[Event], ?at: Float) -> State
    def self.fold(events, at: 0.0) = new.tap { |state| events.each { state.apply(it, at:) } }

    # An empty tree - or one made of these nodes
    #: (?Hash[path, Node]) -> void
    def initialize(nodes = {})
      @nodes = nodes
    end

    # The node at `path`, or nil
    #: (path) -> Node?
    def [](path) = @nodes[path]

    # Whether there is a node at `path`
    #: (path) -> bool
    def key?(path) = @nodes.key?(path)

    # Whether it has no root yet
    #: () -> bool
    def empty? = @nodes.empty?

    # How many nodes it has
    #: () -> Integer
    def size = @nodes.size

    # The paths of the nodes directly under `path`
    #: (path) -> Array[path]
    def children(path) = @nodes.fetch(path).children.map { [*path, it].freeze }

    # A path for a new child of `path`. A child is named by a random id rather than its position,
    # so a pruned task's path never turns up again on another one - not after a prune here, nor
    # when a restarted remote replaces its tree. Ids only have to differ between siblings, since
    # the path tells cousins apart, and a draw that hits a sibling is drawn again
    #: (path, Random) -> path
    def new_child(path, random)
      @nodes.fetch(path)
      100.times do
        child = [*path, -random.rand(CHILD_IDS).to_s(36).rjust(4, "0")].freeze
        return child unless @nodes.key?(child)
      end
      raise ArgumentError, "No id left for another task under #{path.inspect}"
    end

    # Pre-order, children in the order they opened - the order a renderer wants and the order
    # puts replay in, so a reader rebuilding from a squash ends up with the same order
    #: (?path) { (path, Node) -> void } -> void
    #: (?path) -> Enumerator[[path, Node], void]
    def each(path = [], &block)
      return enum_for(:each, path) unless block
      node = @nodes[path] or return
      yield path, node
      node.children.each { each([*path, it].freeze, &block) }
    end

    # Folds one event in, or raises ArgumentError and leaves the state as it was
    #: (Event, at: Float, ?journal: Journal?) -> self
    def apply(event, at:, journal: nil)
      path, op, value = event.path, event.op, event.value
      node = @nodes[path]
      case op
      when :open
        raise ArgumentError, "A task already exists at #{path.inspect}" if node
        parent = parent_of!(path)
        journal&.touch(path, nil)
        journal&.touch(up(path), parent) if parent
        @nodes[path] = State.blank_node(at).tap { assign(it, value) }
        adopt(parent, path) if parent
      when :meta
        node = existing!(path, node)
        journal&.touch(path, node)
        assign(node, value)
        node.stale = value[:stale] if value.key?(:stale)
      when :set
        node = updatable!(path, node)
        raise ArgumentError, "Percent must be between 0 and 100 inclusive, got #{value.inspect}" unless (value.is_a?(Integer) || value.is_a?(Float)) && (0..100).cover?(value)
        start(path, at, journal)
        node.percent = value
      when :add
        node = updatable!(path, node)
        raise ArgumentError, "Count delta must be an Integer, got #{value.inspect}" unless value.is_a?(Integer)
        start(path, at, journal)
        node.count = [node.count + value, 0].max
      when :note
        node = updatable!(path, node)
        start(path, at, journal)
        node.message = value
      when :done, :fail, :cancel
        node = updatable!(path, node)
        # Calling off what never began does not begin it
        (op == :cancel) ? journal&.touch(path, node) : start(path, at, journal)
        node.finished_at = at
        node.status = ENDINGS.fetch(op)
        node.error = value if op == :fail
        node.message = value if op == :cancel && value
      when :prune
        return self unless node # so a squashed run may carry a prune for a node made within it
        journal&.touch(path, node)
        each(path).drop(1).each do |sub, subnode|
          journal&.touch(sub, subnode)
          @nodes.delete(sub)
        end
        node.children = []
      when :say
        existing!(path, node)
      when :put
        parent = parent_of!(path)
        journal&.touch(path, node)
        journal&.touch(up(path), parent) if parent && node.nil?
        fresh = State.blank_node(at)
        FIELDS.each { fresh[it] = value[it] if value.key?(it) }
        fresh.status = fresh.status.to_sym
        fresh.children = node ? node.children : []
        fresh.sealed = node&.sealed
        fresh.autofinish = node&.autofinish
        @nodes[path] = fresh
        adopt(parent, path) if parent && node.nil?
      else
        raise ArgumentError, "Unknown op #{op.inspect}"
      end
      self
    end

    # The tasks under `path` that have not ended, in pre-order - so reversed, every task comes
    # before the one it is under. A mounted subtree is left out unless `mounts` - a remote that
    # has not finished may yet, so a `done` from here would be a guess, but calling it off is not
    #: (path, ?mounts: bool) -> Array[path]
    def open_under(path, mounts: false)
      open = [] #: Array[path]
      sealed = nil #: path?
      each(path).drop(1).each do |sub, node|
        next if sealed && sub[0, sealed.length] == sealed
        sealed = sub if node.sealed && !mounts
        open << sub unless node.finished? || sealed == sub
      end
      open
    end

    # The state as a list of puts, one per node, in pre-order - or just the subtree at `path`
    #: (?path) -> Array[Event]
    def squash(path = []) = each(path).map { |path, node| Event.new(path:, op: :put, value: node.to_h) }

    # Done, and everything under it ended - each task by a `done`, `fail` or `cancel` of its own.
    # Children that are all through do not finish their parent, which may have more to do after
    # them; a failed or canceled one does not hold back a parent that went on to finish regardless
    #: (?path, ?Node?) -> bool
    def complete?(path = [], node = @nodes[path])
      return false unless node && node.status == :done
      node.children.all? do |id|
        child = @nodes.fetch([*path, id])
        child.status == :failed || child.status == :canceled || complete?([*path, id], child)
      end
    end

    # 0.0..1.0, unrounded. Children decide a parent's progress, by weight, and children it was
    # told to expect but has not got yet count as zero. A leaf goes by its count when it has a
    # total, and by its percent otherwise
    #: (?path, ?Node?) -> Float
    def fraction(path = [], node = @nodes[path])
      return 0.0 unless node
      return 1.0 if node.status == :done
      if node.children.any? || missing(node).positive?
        weights = missing(node).to_f
        sum = 0.0
        node.children.each do |id|
          child_path = [*path, id]
          child = @nodes.fetch(child_path)
          weights += child.weight
          sum += child.weight * fraction(child_path, child)
        end
        weights.zero? ? 0.0 : sum / weights
      elsif (total = node.total)
        total.zero? ? 0.0 : (node.count.to_f / total).clamp(0.0, 1.0)
      elsif node.indeterminate
        0.0
      else
        node.percent / 100.0
      end
    end

    # A whole percent, and 100 only once everything under it is done: 99.5 does not round up
    # into a bar that reads as finished while work is still running
    #: (?path) -> Integer
    def percent(path = [])
      return 100 if complete?(path)
      [(fraction(path) * 100).round, 99].min
    end

    # Every node, as a `put` carries it
    #: () -> Hash[path, Hash[Symbol, untyped]]
    def to_h = @nodes.transform_values(&:to_h)

    # A frozen copy, safe to read from any thread
    #: () -> State
    def snapshot
      State.new(@nodes.to_h { |path, node| [path, node.deep_dup.tap { it.children.freeze }.freeze] }.freeze).freeze
    end

    # A copy that can change without changing this one
    #: () -> State
    def dup = State.new(@nodes.transform_values(&:deep_dup))

    # Undoes what one transaction did
    #: (Journal) -> void
    def rollback(journal) = journal.rollback(@nodes)

    private

    #: (Node) -> Integer
    def missing(node) = [(node.expect || 0) - node.children.length, 0].max

    #: (path) -> Node?
    def parent_of!(path)
      return nil if path.empty?
      @nodes[up(path)] or raise ArgumentError, "No parent task at #{up(path).inspect} for #{path.inspect}"
    end

    #: (path, Node?) -> Node
    def existing!(path, node)
      node or raise ArgumentError, "No task at #{path.inspect}"
    end

    #: (path, Node?) -> Node
    def updatable!(path, node)
      node = existing!(path, node)
      raise ArgumentError, "Cannot update task '#{node.name}' - already in #{node.status} state" if node.finished?
      node
    end

    # Work started anywhere starts everything above it too
    #: (path, Float, Journal?) -> void
    def start(path, at, journal)
      path.length.downto(0) do |length|
        prefix = path[0, length] || []
        node = @nodes.fetch(prefix)
        journal&.touch(prefix, node)
        node.status = :active if node.status == :pending
        node.started_at ||= at
      end
    end

    #: (Node, Hash[Symbol, untyped]) -> void
    def assign(node, value)
      ATTRIBUTES.each { node[it] = value[it] if value.key?(it) }
      node.weight = node.weight.to_f
    end

    #: (path) -> path
    def up(path) = path.take(path.length - 1)

    #: (Node, path) -> void
    def adopt(parent, path) = parent.children << path.fetch(-1)
  end
end
