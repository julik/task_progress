# Porting TaskProgress

How to publish progress to TaskProgress, or read it, from another language. Nothing below needs Ruby on the other side. The format is newline-delimited JSON, and a writer that follows the few rules here can be mounted under a Ruby tree, drawn by the browser client, or relayed over SSE like one written in Ruby. A reader that folds the same way draws the same tree.

At the end are a small publisher and a small consumer in Go and in Crystal, each a single file with only the standard library. All four have been run against this gem: the publishers spawned with `Mount#spawn` (to completion, and canceled from the parent halfway), and the consumers following `TaskProgress::SSE` from the start and joining late.

## The model

Progress is a **tree of tasks**, kept as a **log of changes**. Nothing sends "the tree is now like this" - it sends what changed. Every change is an **op** on one task, and ops travel in **batches**: a batch is applied whole, or not at all.

A task is named by its **path**, the ids from the root down: `[]` is the root, `["x3k0"]` a child of it, `["x3k0", "00af"]` a grandchild. An id is 1 to 16 characters of `[0-9a-z]`. TaskProgress draws four at random for each child, so ids never have to be coordinated - but they must differ among siblings, and an id is never used twice in one log, so a path a reader has seen means one task for ever. Keys for UI rows are the ids joined with `-`: `"x3k0-00af"`, and `""` for the root.

Batches are numbered. `seq` counts from 1, and every batch names the one before it in `prev`. A batch with `prev` 0 **starts over**: whatever a reader held is thrown away, and the tree is rebuilt from that batch alone. The very first batch is one of those. So is a **squash** - the tree as it stands, as a single batch of `put` ops, one per task, parents before children - which is what a reader joining late is given first.

## A batch

One JSON object per line, ending in `\n`:

```json
{"v":1,"log":"k7p2qd9z4m","prev":11,"seq":12,"at":1730000000.123,"ops":[[["x3k0"],"add",5],[["x3k0"],"note","Reading"]]}
```

| Field | |
|---|---|
| `v` | The format's version, 1. A reader drops a batch in any other version, as it drops a garbled one. |
| `log` | Which run of which tree this is: 10 random `[0-9a-z]` characters, made once when the tree is. A reader seeing a new `log` without `prev` 0 treats it as a gap. |
| `prev`, `seq` | Integers, `prev` < `seq`. Each batch's `prev` is the `seq` of the one before. |
| `at` | When it was committed: seconds since the epoch, as a float. For elapsed times only - order is `seq`, never `at`. |
| `ops` | `[path, op]` or `[path, op, value]`, applied in order. |

A path is always an array - `[]` for the root, never `null`.

## The ops

| Op | Value | What it does |
|---|---|---|
| `open` | `{name, total, weight, expect, indeterminate, unit, cancelable, attempt}`, any of them | A new task, `pending`. Its parent must exist, and nothing may exist at its path. |
| `meta` | any of open's, and `stale` | Changes attributes. |
| `set` | 0..100 | The percent of a task that is not counted. |
| `add` | an integer | Adds to the count, which never goes below 0. |
| `note` | text, or nothing | The task's latest message. |
| `done` | - | Finished well. |
| `fail` | `{class, message, backtrace, cause}` | Failed. `cause` is another one of these; `backtrace` an array of lines. |
| `cancel` | text, or nothing | Canceled, with the reason. |
| `prune` | - | Drops everything under the task, keeping the task. |
| `put` | a whole task | Replaces the task - its children stay - or adds it, under a parent that exists. What a squash is made of. |
| `say` | text | A line to print above the tree. Changes nothing in it. |

The attributes:

| | |
|---|---|
| `name` | What the row says. |
| `total` | Makes the task **counted**: it reads `count / total`. |
| `weight` | Its share of the parent, 1 if not given. |
| `expect` | How many children it will have. Those not opened yet count as zero, so the parent's bar does not jump backwards as they open. |
| `indeterminate` | No measure of its own: it counts as 0 until it is done, and draws as a spinner. |
| `unit` | `"bytes"` has counts drawn as sizes. |
| `cancelable` | It may be offered for canceling - see [Cancels](#cancels). |
| `attempt` | Which try at the work this is, from 1. |
| `stale` (`meta` only) | The task has stopped hearing from whoever fed it. |

A `put` carries the attributes and also `status` (`pending`, `active`, `done`, `failed`, `canceled`), `count`, `percent`, `message`, `error`, `stale`, `opened_at`, `started_at` and `finished_at`. What it leaves out is at its default: 0, empty, `pending`, `weight` 1.

## Writing

Rules for a writer:

- **Number every batch.** Start at `prev` 0, `seq` 1, and go up by one. Commit from one place, under a lock, so batches leave in the order they are numbered.
- **Open the root first**, at `[]`, in the first batch, and open every task before anything happens to it, parents before children.
- **End every task yourself**, with `done`, `fail` or `cancel`. There is nothing on the wire that finishes a counted task at its total, nor a parent whose children are through. In Ruby, `subtask { }` and `autofinish` do this for you, and send the `done`s you see here.
- **Leave a finished task alone.** Changing one, or opening a task that is already there, is a broken batch, and **a reader drops a broken batch whole** - and treats the next one as a gap.
- **Group what belongs together.** One batch is one transaction: `[[a, "done"], [b, "set", 0]]` is never seen with `a` done and `b` not started.
- **Keep to the limits** a reader holds you to: 100,000 ops in a batch, 32 levels of path, 2,000 characters of text, 4 MB a line. Counts are integers up to 2^53.

A task is `pending` until something happens to it. Any `set`, `add`, `note`, `done` or `fail` makes it `active`, and every task above it with it. A `cancel` does not: calling off what never began does not begin it.

## Reading

Keep the tree as a map from path to task, each task with its children's ids in the order they opened, and the `log` and `seq` of the last batch you applied. For every batch:

1. Another `v` than 1: ignore it.
2. `prev` is 0: empty the tree, and apply it.
3. Same `log`, and `seq` no higher than yours: a **duplicate** - ordinary after a reconnect. Ignore it.
4. Another `log`, or `prev` not your `seq`: a **gap**. Something was missed, and the tree is wrong from here. Mark it stale, and get a fresh squash: reconnect to SSE, poll again.
5. Otherwise apply its ops in order, and keep its `log` and `seq`.

The ops do what the table above says, with the starting rule. Then for drawing:

- **Complete** means `done`, and every child either complete, `failed` or `canceled`. A task whose children are all through is not complete until it is `done` itself - it may have more to do after them.
- The **fraction** of a `done` task is 1. A task with children, or one that `expect`s some, is the weighted mean of its children's fractions; each child it expects but does not have yet adds a weight of 1 at 0. A counted task is `count / total`, at most 1 (0 for a total of 0). An indeterminate one is 0. Anything else is `percent / 100`.
- The **percent** is 100 when the task is complete, and otherwise the fraction rounded, at most 99 - so a task 99.6% of the way never reads as finished while something still runs.

That is the whole fold. TaskProgress's own readers, `TaskProgress::State` and `js/task_tree.js`, do the same, and are held to agree by a test.

A reader taking batches from somewhere it does not trust should check them first, as `TaskProgress::Wire` does - see [The wire format](MANUAL.md#the-wire-format) in the MANUAL for every limit it enforces.

## Getting batches across

### A pipe

`Mount#spawn` runs a program with two pipes:

- `TASK_PROGRESS_FD=3` - write batches to it, one line each. Your root lands on the mount's node in the parent's tree, so your `[]` is the mount and your `["x3k0"]` is a child of it.
- `TASK_PROGRESS_CONTROL_FD=4` - cancel requests come down it, one JSON line each: `{"cancel": ["x3k0"], "reason": "Not needed"}`. `[]` is your root - that one arrives when the parent cancels the mount, and the program gets a TERM if it has not exited some seconds later. Any other path is a task you opened with `cancelable: true`.

Handling a cancel is sending a `cancel` for the task, and everything still open under it, and stopping the work. A program that exits without ending its root fails the mount, and one that exits non-zero fails it with that. Outside `spawn`, write to stdout instead, and the same lines can be read by a Ruby `mount.read(io)` from any IO - a pipe, a socket, a file.

### Server-Sent Events

`TaskProgress::SSE` - and anything that wants to be read like it - sends:

```
retry: 2000

id: 12
event: batch
data: {"v":1,"log":"k7p2qd9z4m","prev":0,"seq":12,...}

: ping

```

First a squash, `prev` 0, then every batch as it commits, each a `batch` event whose `id` is its `seq`. Lines starting with `:` are keep-alives. The stream ends once the root has finished. A client that reconnects gets a fresh squash, so a reader never needs `Last-Event-ID`: start over, and the duplicates sort themselves out.

### Polling

`TaskProgress::Poll` answers each GET with the whole tree, squashed into one batch with `prev` 0, and an `ETag`. Send the ETag back in `If-None-Match` and you get a 304 until something changes. `?wait=N` holds the request up to N seconds for a change.

## The examples

A publisher that resizes photos - five counted downloads, then an indeterminate resize - and a consumer that redraws the tree on a terminal as batches come in. The publisher writes to `TASK_PROGRESS_FD` when it is spawned by a mount, and to stdout otherwise; it honours a cancel of its root. The consumer follows an SSE URL, or reads NDJSON from stdin when given `-`:

```
$ ./publisher | ./consumer -
$ ./consumer http://localhost:9292/jobs/k7p2qd9z4m/events
```

```ruby
root = TaskProgress.new("Photos")
root.mount("Resizing", cancelable: true).spawn("./publisher")
```

They keep to what each language has built in, and leave out what a real one would want: checking what a remote sends, `unit`, `stale`, errors beyond their message, the elapsed times, and canceling tasks below the root.

### Go: a publisher

```go
package main

import (
	"bufio"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"math/big"
	"os"
	"strconv"
	"sync"
	"time"
)

// Op is one event: [path, op] or [path, op, value]
type Op []any

type Batch struct {
	V    int     `json:"v"`
	Log  string  `json:"log"`
	Prev int64   `json:"prev"`
	Seq  int64   `json:"seq"`
	At   float64 `json:"at"`
	Ops  []Op    `json:"ops"`
}

// Publisher numbers batches and writes them out, one JSON line each
type Publisher struct {
	mu  sync.Mutex
	enc *json.Encoder
	log string
	seq int64
}

func NewPublisher(f *os.File) *Publisher {
	return &Publisher{enc: json.NewEncoder(f), log: randomID(10)}
}

// Commit writes the ops as one batch - a reader applies all of them or none
func (p *Publisher) Commit(ops ...Op) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	b := Batch{V: 1, Log: p.log, Prev: p.seq, Seq: p.seq + 1, At: float64(time.Now().UnixNano()) / 1e9, Ops: ops}
	if err := p.enc.Encode(b); err != nil { // Encode ends the line with "\n"
		return err
	}
	p.seq++
	return nil
}

// Path makes a path that is never nil - a nil slice would go out as null rather than []
func Path(ids ...string) []string { return append([]string{}, ids...) }

func Child(parent []string) []string { return append(Path(parent...), randomID(4)) }

func randomID(n int) string {
	const chars = "0123456789abcdefghijklmnopqrstuvwxyz"
	id := make([]byte, n)
	for i := range id {
		k, _ := rand.Int(rand.Reader, big.NewInt(int64(len(chars))))
		id[i] = chars[k.Int64()]
	}
	return string(id)
}

// The pipe a parent TaskProgress hands us with Mount#spawn, or stdout
func output() *os.File {
	if fd, err := strconv.Atoi(os.Getenv("TASK_PROGRESS_FD")); err == nil {
		return os.NewFile(uintptr(fd), "progress")
	}
	return os.Stdout
}

// Cancel requests from the parent, one JSON line each: {"cancel": [path...], "reason": "..."}
func cancelRequests() <-chan string {
	reasons := make(chan string, 1)
	fd, err := strconv.Atoi(os.Getenv("TASK_PROGRESS_CONTROL_FD"))
	if err != nil {
		return reasons
	}
	go func() {
		lines := bufio.NewScanner(os.NewFile(uintptr(fd), "control"))
		for lines.Scan() {
			var req struct {
				Cancel []string `json:"cancel"`
				Reason string   `json:"reason"`
			}
			// Only the root is ours to cancel here: none of the tasks below say they are cancelable
			if json.Unmarshal(lines.Bytes(), &req) == nil && req.Cancel != nil && len(req.Cancel) == 0 {
				reasons <- req.Reason
				return
			}
		}
	}()
	return reasons
}

func main() {
	p := NewPublisher(output())
	canceled := cancelRequests()
	root := Path()
	p.Commit(Op{root, "open", map[string]any{"name": "Resize photos", "expect": 2}})

	download := Child(root)
	p.Commit(Op{download, "open", map[string]any{"name": "Download", "total": 5}})
	for i := 1; i <= 5; i++ {
		select {
		case reason := <-canceled:
			p.Commit(Op{root, "cancel", reason})
			os.Exit(1)
		case <-time.After(200 * time.Millisecond):
		}
		ops := []Op{{download, "add", 1}, {download, "note", fmt.Sprintf("photo-%d.jpg", i)}}
		if i == 5 {
			ops = append(ops, Op{download, "done"}) // a counted task finishes by a done of its own
		}
		p.Commit(ops...)
	}

	resize := Child(root)
	p.Commit(Op{resize, "open", map[string]any{"name": "Resize", "indeterminate": true}})
	time.Sleep(300 * time.Millisecond)
	p.Commit(Op{resize, "done"}, Op{root, "done"})
}
```

### Go: a consumer

```go
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"strings"
	"time"
)

type Batch struct {
	V    int                 `json:"v"`
	Log  string              `json:"log"`
	Prev int64               `json:"prev"`
	Seq  int64               `json:"seq"`
	Ops  [][]json.RawMessage `json:"ops"`
}

type Node struct {
	Name          string
	Total         *int64
	Count         int64
	Percent       float64
	Weight        float64
	Expect        int64
	Indeterminate bool
	Message       string
	Status        string // pending, active, done, failed, canceled
	Children      []string
}

// What an open, a meta or a put may carry - pointers, so that what is absent stays as it was
type fields struct {
	Name          *string  `json:"name"`
	Total         *int64   `json:"total"`
	Weight        *float64 `json:"weight"`
	Expect        *int64   `json:"expect"`
	Indeterminate *bool    `json:"indeterminate"`
	Count         *int64   `json:"count"`
	Percent       *float64 `json:"percent"`
	Message       *string  `json:"message"`
	Status        *string  `json:"status"`
}

func (n *Node) assign(f fields) {
	if f.Name != nil { n.Name = *f.Name }
	if f.Total != nil { n.Total = f.Total }
	if f.Weight != nil { n.Weight = *f.Weight }
	if f.Expect != nil { n.Expect = *f.Expect }
	if f.Indeterminate != nil { n.Indeterminate = *f.Indeterminate }
	if f.Count != nil { n.Count = *f.Count }
	if f.Percent != nil { n.Percent = *f.Percent }
	if f.Message != nil { n.Message = *f.Message }
	if f.Status != nil { n.Status = *f.Status }
}

func blank() *Node { return &Node{Weight: 1, Status: "pending"} }

// Tree folds batches the way TaskProgress::State does, keyed by the path's ids joined with "-"
type Tree struct {
	nodes map[string]*Node
	log   string
	seq   int64
}

func key(path []string) string { return strings.Join(path, "-") }

// Apply returns "applied", "duplicate", "gap" - start over from a fresh squash - or "unsupported"
func (t *Tree) Apply(b Batch) string {
	switch {
	case b.V != 1:
		return "unsupported"
	case b.Prev == 0:
		t.nodes = map[string]*Node{}
	case b.Log == t.log && b.Seq <= t.seq:
		return "duplicate"
	case b.Log != t.log || b.Prev != t.seq:
		return "gap"
	}
	for _, op := range b.Ops {
		t.applyOp(op)
	}
	t.log, t.seq = b.Log, b.Seq
	return "applied"
}

func (t *Tree) applyOp(raw []json.RawMessage) {
	var path []string
	var op string
	json.Unmarshal(raw[0], &path)
	json.Unmarshal(raw[1], &op)
	var value json.RawMessage
	if len(raw) > 2 {
		value = raw[2]
	}
	node := t.nodes[key(path)]
	if node == nil && op != "open" && op != "put" {
		return
	}
	switch op {
	case "open", "put":
		fresh := blank()
		var f fields
		json.Unmarshal(value, &f)
		fresh.assign(f) // an open carries only attributes; a put carries status, count and the rest too
		if node != nil {
			fresh.Children = node.Children // a put replaces a node, never its children
		} else if len(path) > 0 {
			parent := t.nodes[key(path[:len(path)-1])]
			parent.Children = append(parent.Children, path[len(path)-1])
		}
		t.nodes[key(path)] = fresh
	case "meta":
		var f fields
		json.Unmarshal(value, &f)
		node.assign(f)
	case "set":
		t.start(path)
		json.Unmarshal(value, &node.Percent)
	case "add":
		var n int64
		json.Unmarshal(value, &n)
		t.start(path)
		node.Count = max(node.Count+n, 0)
	case "note":
		t.start(path)
		node.Message = ""
		json.Unmarshal(value, &node.Message)
	case "done":
		t.start(path)
		node.Status = "done"
	case "fail":
		t.start(path)
		node.Status = "failed"
		var e struct{ Message string }
		json.Unmarshal(value, &e)
		node.Message = e.Message
	case "cancel": // calling off what never began does not begin it
		node.Status = "canceled"
		json.Unmarshal(value, &node.Message)
	case "prune":
		prefix := key(path)
		for k := range t.nodes {
			if k != prefix && (prefix == "" || strings.HasPrefix(k, prefix+"-")) {
				delete(t.nodes, k)
			}
		}
		node.Children = nil
	} // "say" is a line to print, and changes nothing in the tree
}

// Anything that happens to a task starts it, and every task above it
func (t *Tree) start(path []string) {
	for i := len(path); i >= 0; i-- {
		if n := t.nodes[key(path[:i])]; n.Status == "pending" {
			n.Status = "active"
		}
	}
}

func child(path []string, id string) []string { return append(append([]string{}, path...), id) }

// Done, and everything under it ended
func (t *Tree) complete(path []string) bool {
	n := t.nodes[key(path)]
	if n.Status != "done" {
		return false
	}
	for _, id := range n.Children {
		c := t.nodes[key(child(path, id))]
		if c.Status != "failed" && c.Status != "canceled" && !t.complete(child(path, id)) {
			return false
		}
	}
	return true
}

func (t *Tree) fraction(path []string) float64 {
	n := t.nodes[key(path)]
	if n.Status == "done" {
		return 1
	}
	missing := max(n.Expect-int64(len(n.Children)), 0) // expected, not opened yet: zero each
	switch {
	case len(n.Children) > 0 || missing > 0:
		weights, sum := float64(missing), 0.0
		for _, id := range n.Children {
			c := t.nodes[key(child(path, id))]
			weights += c.Weight
			sum += c.Weight * t.fraction(child(path, id))
		}
		if weights == 0 {
			return 0
		}
		return sum / weights
	case n.Total != nil:
		if *n.Total == 0 {
			return 0
		}
		return math.Min(float64(n.Count)/float64(*n.Total), 1)
	case n.Indeterminate:
		return 0
	default:
		return n.Percent / 100
	}
}

// Held at 99 until the task is complete, so 99.6% never reads as finished
func (t *Tree) PercentAt(path []string) int {
	if t.complete(path) {
		return 100
	}
	return min(int(math.Round(t.fraction(path)*100)), 99)
}

func (t *Tree) Draw(w io.Writer, path []string, depth int) {
	n := t.nodes[key(path)]
	line := fmt.Sprintf("%s%-*s %3d%% %s", strings.Repeat("  ", depth), 24-2*depth, n.Name, t.PercentAt(path), n.Status)
	if n.Total != nil {
		line += fmt.Sprintf(" %d/%d", n.Count, *n.Total)
	}
	if n.Message != "" {
		line += "  " + n.Message
	}
	fmt.Fprintln(w, line)
	for _, id := range n.Children {
		t.Draw(w, child(path, id), depth+1)
	}
}

func (t *Tree) Finished() bool {
	root := t.nodes[""]
	return root != nil && root.Status != "pending" && root.Status != "active"
}

// Reads a TaskProgress::SSE stream: a "batch" event per batch, its JSON in the data line.
// Returns at the end of the stream, or on a gap - either way, connecting again starts over
// from a fresh squash
func follow(url string, t *Tree) error {
	resp, err := http.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("%s: %s", url, resp.Status)
	}
	lines := bufio.NewReader(resp.Body)
	event, data := "", ""
	for {
		line, err := lines.ReadString('\n')
		if err != nil {
			return nil
		}
		line = strings.TrimRight(line, "\r\n")
		switch {
		case line == "": // the end of an event
			if event == "batch" && handle(t, data) == "gap" {
				return nil
			}
			event, data = "", ""
		case strings.HasPrefix(line, "event:"):
			event = strings.TrimSpace(line[6:])
		case strings.HasPrefix(line, "data:"):
			data += strings.TrimPrefix(line[5:], " ")
		} // "id:", "retry:" and ": ping" lines need nothing here
	}
}

func handle(t *Tree, data string) string {
	var b Batch
	if json.Unmarshal([]byte(data), &b) != nil {
		return "garbled"
	}
	outcome := t.Apply(b)
	if outcome == "applied" {
		fmt.Print("\033[H\033[2J") // clear the terminal, and draw it all again
		t.Draw(os.Stdout, []string{}, 0)
	}
	return outcome
}

func main() {
	t := &Tree{}
	if len(os.Args) < 2 || os.Args[1] == "-" { // NDJSON on stdin: `publisher | consumer`
		lines := bufio.NewScanner(os.Stdin)
		lines.Buffer(nil, 4<<20)
		for lines.Scan() {
			handle(t, lines.Text())
		}
		return
	}
	for !t.Finished() {
		if err := follow(os.Args[1], t); err != nil {
			fmt.Fprintln(os.Stderr, err)
		}
		if !t.Finished() {
			time.Sleep(2 * time.Second)
		}
	}
}
```

### Crystal: a publisher

```crystal
require "json"
require "random/secure"

# Numbers batches and writes them out, one JSON line each
class Publisher
  alias Path = Array(String)

  def initialize(@io : IO)
    @log = Publisher.random_id(10)
    @seq = 0_i64
    @lock = Mutex.new
  end

  def self.random_id(size)
    chars = "0123456789abcdefghijklmnopqrstuvwxyz"
    String.build { |s| size.times { s << chars[Random::Secure.rand(chars.size)] } }
  end

  def self.child(parent : Path) : Path
    parent + [random_id(4)]
  end

  # Writes the ops as one batch - a reader applies all of them or none. An op is
  # {path, op} or {path, op, value}
  def commit(*ops)
    @lock.synchronize do
      line = JSON.build do |json|
        json.object do
          json.field "v", 1
          json.field "log", @log
          json.field "prev", @seq
          json.field "seq", @seq + 1
          json.field "at", Time.utc.to_unix_f
          json.field "ops" { json.array { ops.each &.to_json(json) } }
        end
      end
      @io << line << '\n'
      @io.flush
      @seq += 1
    end
  end
end

# The pipe a parent TaskProgress hands us with Mount#spawn, or stdout
output = if fd = ENV["TASK_PROGRESS_FD"]?
           IO::FileDescriptor.new(fd.to_i)
         else
           STDOUT
         end

# Cancel requests from the parent, one JSON line each: {"cancel": [path...], "reason": "..."}.
# Only the root is ours to cancel here: none of the tasks below say they are cancelable
canceled = Channel(String?).new(1)
if fd = ENV["TASK_PROGRESS_CONTROL_FD"]?
  spawn do
    IO::FileDescriptor.new(fd.to_i).each_line do |line|
      request = JSON.parse(line) rescue next
      if request["cancel"]?.try(&.as_a?.try(&.empty?))
        canceled.send(request["reason"]?.try(&.as_s?))
        break
      end
    end
  end
end

p = Publisher.new(output)
root = [] of String
p.commit({root, "open", {name: "Resize photos", expect: 2}})

download = Publisher.child(root)
p.commit({download, "open", {name: "Download", total: 5}})
(1..5).each do |i|
  select
  when reason = canceled.receive
    p.commit({root, "cancel", reason})
    exit 1
  when timeout(200.milliseconds)
  end
  if i == 5 # a counted task finishes by a done of its own
    p.commit({download, "add", 1}, {download, "note", "photo-#{i}.jpg"}, {download, "done"})
  else
    p.commit({download, "add", 1}, {download, "note", "photo-#{i}.jpg"})
  end
end

resize = Publisher.child(root)
p.commit({resize, "open", {name: "Resize", indeterminate: true}})
sleep 300.milliseconds
p.commit({resize, "done"}, {root, "done"})
```

### Crystal: a consumer

```crystal
require "json"
require "http/client"

class Node
  property name = ""
  property total : Int64? = nil
  property count = 0_i64
  property percent = 0.0
  property weight = 1.0
  property expect = 0_i64
  property indeterminate = false
  property message : String? = nil
  property status = "pending" # pending, active, done, failed, canceled
  property children = [] of String

  # What an open, a meta or a put carries - only what is in it changes
  def assign(fields : JSON::Any)
    h = fields.as_h? || return
    h["name"]?.try { |v| @name = v.as_s }
    h["total"]?.try { |v| @total = v.as_i64? }
    h["weight"]?.try { |v| @weight = v.as_f? || v.as_i64.to_f }
    h["expect"]?.try { |v| @expect = v.as_i64? || 0_i64 }
    h["indeterminate"]?.try { |v| @indeterminate = v.as_bool? || false }
    h["count"]?.try { |v| @count = v.as_i64 }
    h["percent"]?.try { |v| @percent = v.as_f? || v.as_i64.to_f }
    h["message"]?.try { |v| @message = v.as_s? }
    h["status"]?.try { |v| @status = v.as_s }
  end
end

# Folds batches the way TaskProgress::State does, keyed by the path's ids joined with "-"
class Tree
  alias Path = Array(String)
  @nodes = {} of String => Node
  @log : String? = nil
  @seq = 0_i64

  # "applied", "duplicate", "gap" - start over from a fresh squash - or "unsupported"
  def apply(batch : JSON::Any) : String
    return "unsupported" unless batch["v"]? == 1
    log, prev, seq = batch["log"].as_s?, batch["prev"].as_i64, batch["seq"].as_i64
    if prev == 0
      @nodes = {} of String => Node
    elsif log == @log && seq <= @seq
      return "duplicate"
    elsif log != @log || prev != @seq
      return "gap"
    end
    batch["ops"].as_a.each { |op| apply_op(op.as_a) }
    @log, @seq = log, seq
    "applied"
  end

  private def key(path : Path)
    path.join('-')
  end

  private def apply_op(op : Array(JSON::Any))
    path = op[0].as_a.map(&.as_s)
    name = op[1].as_s
    value = op[2]? || JSON::Any.new(nil)
    node = @nodes[key(path)]?
    return if node.nil? && !{"open", "put"}.includes?(name)
    case name
    when "open", "put" # an open carries only attributes; a put carries status, count and the rest too
      fresh = Node.new
      fresh.assign(value)
      if node
        fresh.children = node.children # a put replaces a node, never its children
      elsif !path.empty?
        @nodes[key(path[0...-1])].children << path.last
      end
      @nodes[key(path)] = fresh
    when "meta" then node.not_nil!.assign(value)
    when "set"
      start(path)
      node.not_nil!.percent = value.as_f? || value.as_i64.to_f
    when "add"
      start(path)
      node.not_nil!.count = {node.not_nil!.count + value.as_i64, 0_i64}.max
    when "note"
      start(path)
      node.not_nil!.message = value.as_s?
    when "done"
      start(path)
      node.not_nil!.status = "done"
    when "fail"
      start(path)
      node.not_nil!.status = "failed"
      node.not_nil!.message = value["message"]?.try(&.as_s?)
    when "cancel" # calling off what never began does not begin it
      node.not_nil!.status = "canceled"
      value.as_s?.try { |reason| node.not_nil!.message = reason }
    when "prune"
      prefix = key(path)
      @nodes.reject! { |k, _| k != prefix && (prefix.empty? || k.starts_with?("#{prefix}-")) }
      node.not_nil!.children.clear
    end # "say" is a line to print, and changes nothing in the tree
  end

  # Anything that happens to a task starts it, and every task above it
  private def start(path : Path)
    path.size.downto(0) do |i|
      n = @nodes[key(path[0, i])]
      n.status = "active" if n.status == "pending"
    end
  end

  # Done, and everything under it ended
  def complete?(path : Path) : Bool
    node = @nodes[key(path)]
    return false unless node.status == "done"
    node.children.all? do |id|
      {"failed", "canceled"}.includes?(@nodes[key(path + [id])].status) || complete?(path + [id])
    end
  end

  def fraction(path : Path) : Float64
    node = @nodes[key(path)]
    return 1.0 if node.status == "done"
    missing = {node.expect - node.children.size, 0_i64}.max # expected, not opened yet: zero each
    if !node.children.empty? || missing > 0
      weights, sum = missing.to_f, 0.0
      node.children.each do |id|
        child = @nodes[key(path + [id])]
        weights += child.weight
        sum += child.weight * fraction(path + [id])
      end
      weights.zero? ? 0.0 : sum / weights
    elsif total = node.total
      total.zero? ? 0.0 : {node.count / total, 1.0}.min
    elsif node.indeterminate
      0.0
    else
      node.percent / 100
    end
  end

  # Held at 99 until the task is complete, so 99.6% never reads as finished
  def percent(path : Path = [] of String) : Int32
    return 100 if complete?(path)
    {(fraction(path) * 100).round.to_i, 99}.min
  end

  def finished? : Bool
    {"done", "failed", "canceled"}.includes?(@nodes[""]?.try(&.status))
  end

  def draw(io : IO, path : Path = [] of String, depth = 0)
    node = @nodes[key(path)]
    io << "  " * depth << node.name.ljust(24 - 2 * depth) << " " << percent(path).to_s.rjust(3) << "% " << node.status
    node.total.try { |total| io << " " << node.count << "/" << total }
    node.message.try { |message| io << "  " << message }
    io << '\n'
    node.children.each { |id| draw(io, path + [id], depth + 1) }
  end
end

def handle(tree : Tree, data : String) : String
  batch = JSON.parse(data) rescue return "garbled"
  outcome = tree.apply(batch)
  if outcome == "applied"
    print "\e[H\e[2J" # clear the terminal, and draw it all again
    tree.draw(STDOUT)
  end
  outcome
end

# Reads a TaskProgress::SSE stream: a "batch" event per batch, its JSON in the data line.
# Returns at the end of the stream, or on a gap - either way, connecting again starts over
# from a fresh squash
def follow(url : String, tree : Tree)
  HTTP::Client.get(url) do |response|
    raise "#{url}: #{response.status_code}" unless response.status_code == 200
    event, data = "", ""
    response.body_io.each_line(chomp: true) do |line|
      line = line.rchop('\r')
      if line.empty? # the end of an event
        return if event == "batch" && handle(tree, data) == "gap"
        event, data = "", ""
      elsif line.starts_with?("event:")
        event = line[6..].strip
      elsif line.starts_with?("data:")
        data += line[5..].lchop(' ')
      end # "id:", "retry:" and ": ping" lines need nothing here
    end
  end
end

tree = Tree.new
if ARGV.empty? || ARGV[0] == "-" # NDJSON on stdin: `publisher | consumer`
  STDIN.each_line { |line| handle(tree, line) }
else
  until tree.finished?
    begin
      follow(ARGV[0], tree)
    rescue e
      STDERR.puts e.message
    end
    sleep 2.seconds unless tree.finished?
  end
end
```
