# Async Python guidelines

Async code works best when it is treated as a way to coordinate waiting, not
as a way to make every function concurrent. Keep synchronous, deterministic
domain logic synchronous. Use async at boundaries that wait on the network,
the filesystem, subprocesses, timers, or other concurrent work.

## Ownership of the event loop

The process entry point owns the event loop. Libraries, request handlers, and
background jobs must not create or nest one with `asyncio.run()`.

Prefer a single async call chain from the framework boundary to each I/O
operation. Avoid APIs that sometimes return a value and sometimes return an
awaitable. A function's interface should make its concurrency model obvious.

Resources such as HTTP clients, SDK sessions, and connection pools should
usually live for the application lifespan. Create them during startup, pass
them explicitly to the code that uses them, and close them during shutdown.
Do not hide resource creation in imports or mutable module globals.

## Keep the event loop responsive

An async function can still block the entire process. Do not perform blocking
I/O, long computations, large serialization operations, compression, or
similar work on an event-loop thread.

When a dependency only offers a synchronous API, call it through the shared
bounded sync-offload helper. The bound matters: an unbounded stream of thread
work merely moves overload somewhere less visible. Preserve context variables
when crossing the boundary and assume that cancellation of the awaiter may not
stop work already running in a thread.

Use a bounded process pool for CPU-bound work when ordinary CPython needs true
parallelism. A thread pool is appropriate for blocking I/O and may be useful
for CPU work on a free-threaded interpreter, but that choice must be supported
by correctness and workload measurements. The GIL is neither a synchronization
primitive nor a substitute for documenting thread safety.

## Concurrency is always bounded

Never create one task per item from untrusted or potentially large input
without a concurrency limit. Put the bound near the fan-out so it remains
visible during review. The limit should reflect the downstream service,
connection pool, memory budget, and failure behavior rather than an arbitrary
large number.

Prefer structured concurrency with `asyncio.TaskGroup`. Choose and document the
failure semantics at the call site:

- Fail-fast work treats the children as one operation. A failure cancels the
  remaining children and the caller handles the resulting exception group.
- Collect-all work treats children independently. Each child converts its own
  failure into a typed result so one failure does not cancel unrelated work.

Do not use fire-and-forget tasks. Every task needs an owner that awaits it,
tracks its result, or cancels and drains it during shutdown. If a long-lived
supervisor is genuinely required, keep strong references to its tasks and
surface their failures.

## Cancellation, timeouts, and cleanup

Cancellation is normal control flow. Do not swallow `CancelledError`. Use
`try/finally` or async context managers to release resources, and re-raise
cancellation after necessary cleanup.

A claim or lease taken before cancellable work must be released on
`BaseException`, not only `Exception`: a task timeout or worker shutdown
raises `CancelledError`, and a claim left held blocks redeliveries until its
TTL. Taskiq enforces task timeouts with an AnyIO cancel scope, which cancels
every further await inside it, so the release itself must be shielded. Use
`release_shielded` (`src/pos_api/jobs/leases.py`), which also bounds the write
and logs a failed or timed-out release instead of raising it, so the release
never replaces the cancellation or error that triggered it.

Every remote operation needs a timeout derived from an end-to-end budget.
Layered timeouts should leave time for cleanup and for the caller to translate
the failure. Retries must also fit inside the budget; a timeout followed by
unbounded retries is not bounded behavior.

Async context managers and iterators should be preferred for resources and
streams because they make acquisition, backpressure, and cleanup explicit.
Avoid reading an unbounded response or file fully into memory when it can be
streamed.

## Background work and delivery semantics

Durable background jobs should use the same async resource-lifecycle rules as
request handlers. Job payloads should be small, versioned, strictly validated,
and contain identifiers or immutable references rather than credentials,
secrets, or large documents.

Assume a durable broker can deliver a message more than once. A job must have
an idempotency strategy, explicit state transitions, and a clear point after
which it is acknowledged. Retry only failures classified as transient, use
bounded attempts with backoff and jitter, and preserve enough error context to
diagnose the terminal failure.

For replaceable work, distinguish cancellation from supersession. A stale job
must verify that it still owns the result immediately before making that result
visible. Status reads and polling endpoints must be free of write side effects.

## Shared state

Prefer immutable registries and configuration after startup. For mutable
caches, document their lifetime, owner, invalidation behavior, and concurrency
model. State accessed by multiple threads must use an appropriate lock or be
restructured around message passing or isolated process-local ownership.

Use `ContextVar` for request- or job-scoped context that must follow an async
call chain. Do not use `threading.local()` for async request state, and always
reset context-variable tokens when leaving the scope that set them.

## Runtime variants

Runtime features such as a JIT or free-threaded execution change performance
characteristics; they do not change these design rules. Detect runtime state
with the interpreter's own APIs at startup and fail clearly when the deployed
configuration does not match the requested mode. Do not infer the state from
an environment variable alone.

JIT-enabled and free-threaded builds are distinct runtime choices. Native
extensions may be incompatible with free-threaded execution or may cause the
GIL to be enabled, so validate the effective state after imports and after
exercising extension-backed code. Never force the GIL off merely to make a
test appear successful.

Select a runtime using representative, long-lived workload measurements and
identical correctness outputs. Import success and short microbenchmarks are
useful diagnostics, not evidence that a runtime improves the application.

## Testing and review

Run async tests with debug mode enabled in CI so slow callbacks, leaked tasks,
and incorrect loop usage are visible. Keep static checks for known blocking
calls in async paths, and test cancellation, timeout, retry, duplicate delivery,
shutdown, and partial-failure behavior explicitly.

Tests involving concurrency should assert invariants and externally observable
results rather than relying on sleeps or task scheduling order. Use events,
barriers, and controlled fakes to make races reproducible. Performance tests
must use production-shaped inputs, record interpreter and dependency identity,
and verify that outputs remain identical.
