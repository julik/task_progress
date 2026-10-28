# To do

After 1.0.

## One follower per tree, per process

`TaskProgress.follow` starts a thread, and holds a Redis connection, for every caller - so every
browser tab that streams a handed-off tree costs one of each. A registry of followers by key,
shared by everyone in the process who follows that tree and stopped when the last one lets go,
would make it one per tree instead.

## Share browser tasks with the server

Tasks a browser runs can be grafted onto the tree it shows (`LocalTasks`, `TaskTree#graft`), but only that page sees them. Sharing them - posting the browser's batches to the server, which mounts them under the task they were grafted to - would let every viewer, the terminal and the server's own percent see the browser's work. The batches are ordinary batches and a Mount already distrusts what it is fed, but a server that accepts batches from browsers is a denial-of-service engine unless it answers these first:

- **Rate limits.** Per job, per session and per address: batches a second, ops a batch, bytes a second. The browser should send at most every few hundred milliseconds, squashed, the way BufferedOutput does - and the server must enforce that rather than trust it.
- **Size limits.** Tasks per graft, depth, name and message lengths - tighter than what Wire accepts from a trusted child process.
- **Who may graft, and where.** A signed token like Token's, and a task the server opened as `graftable: true`; nothing grafts anywhere else.
- **Abandoned grafts.** A tab that closes leaves a mount nobody feeds. It needs a heartbeat, and a timeout after which the server cancels the graft.
- **Memory.** Every graft is a Mount and a subtree held by the server for the life of the job; there has to be a cap on how many a job takes.
