## HAL-C2 orchestration

The `hal-c2` MCP server provides app-owned orchestration. Treat these concepts distinctly:

- A delegated task/subagent is child work owned by the current thread. Prefer the current provider's native subagent tools for same-provider parallel work when available. Use `delegate_task` for cross-provider work, when native delegation is unavailable, or when the user explicitly requests HAL-C2-owned child tasks. Use `orchestrator_capabilities` to discover provider/model IDs, retain each returned `taskId`, and use `task_status` or `task_cancel` to manage it. The returned `childThreadId` is backing storage for the subagent; do not replace delegation with ordinary thread creation.
- `hal_c2_thread_launch` and `create_threads` create ordinary top-level HAL-C2 conversations. Use them only when the user explicitly asks for separate/new/top-level threads or conversations. Never use them merely because the user said "subagent" or requested parallel delegated work.
- `schedule_task` creates persistent recurring work in the app scheduler. Pass `schedule` as a structured object, never as JSON text: `{"type":"interval","everyMs":3600000}` for an interval, or `{"type":"fixed_time","timeOfDay":"09:00","weekdays":[1,2,3,4,5]}` for a wall-clock schedule. By default runs return to the current thread; set `bindToCurrentThread=false` only when the user wants a fresh thread for every run. After scheduling, report the returned cadence and next run time.

### Choose the workspace before starting a new thread

For independent implementation or a PR stack in its own worktree, use `hal_c2_thread_launch` with an explicit `workspaceStrategy`. It creates or selects the workspace, binds the new thread to it, and prepares it before the agent starts. Put the task in `message`, not `prompt`:

- New worktree: `{"title":"UI cleanup","workspaceStrategy":{"type":"worktree","baseRef":"feature/base","branch":"feature/ui-cleanup","startFromOrigin":false},"message":"Implement the cleanup and open a PR against feature/base."}`
- Existing worktree: `{"title":"Continue cleanup","workspaceStrategy":{"type":"existing_worktree","worktreePath":"/absolute/path/to/worktree","branch":"feature/ui-cleanup"},"message":"Continue the cleanup."}`
- Project's main checkout: `workspaceStrategy:{"type":"root"}`. Omitting workspaceStrategy also selects root; it does not inherit the caller's worktree.

For stacked work, set `baseRef` to the intended parent branch and `startFromOrigin:false` to use its local commits. Use `startFromOrigin:true` when you intend to fetch and start from origin. Uncommitted edits are not copied. Use `hal_c2_worktree_list` to discover existing checkout paths. Project, model selection, and modes inherit unless supplied; launch requires a full-access/default caller.

`hal_c2_thread_launch` is the single-thread launch tool. Use `create_threads` only for a batch of threads intentionally sharing the caller's checkout: it always inherits the caller's project, branch, and worktree and has no workspace override. Asking an agent to run `git worktree add` or `cd` in its prompt does not update HAL-C2's thread binding. Select the workspace in the launch call instead. `hal_c2_worktree_handoff` moves the calling thread, not another thread, and cannot move a thread already attached to a worktree.

`hal_c2_thread_launch` has no idempotency key. Retain its returned threadId and inspect it with `hal_c2_thread_read` / `hal_c2_thread_wait`; preparation can still be running after acceptance. If a launch fails or its response is lost, inspect `hal_c2_thread_list` before retrying, since a thread may already exist.

Tool names may include a harness-normalized MCP prefix, such as `mcp__hal_c2__delegate_task`; the semantics are the same. Some harnesses attach optional MCP servers lazily: if an initial tool-catalog scan does not show HAL-C2 tools, do not conclude that cross-provider delegation is unavailable. Make one bounded direct attempt using the known HAL-C2 tool name on the next tool step. In Codex code mode, for example, call `tools.mcp__hal_c2__orchestrator_capabilities({})` before reporting that the capability is absent. Keep polling/wait loops bounded, do not duplicate active work, and use stable `clientRequestId` values when retrying tools that accept them.
