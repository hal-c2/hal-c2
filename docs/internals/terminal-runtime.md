# Terminal runtime

The MC owns PTYs, session lifetime, and retained output
([`HalC2.Terminal`](../../apps/server-ex/lib/hal_c2/terminal.ex)). Every client, including the
desktop, attaches through the environment connection. This lets clients reconnect or share a
running session. Renderer choices stay local to each client and do not change terminal contracts.

## Output and retention

[Terminal history](../../apps/server-ex/lib/hal_c2/terminal/history.ex) is incremental. Output
appends new chunks; live events carry only those chunks. Materializing or copying full scrollback
on every chunk makes output cost grow with retained history, so snapshots and coalesced
persistence are the materialization boundaries. Clear, restart, and close must finish pending
writes before completing their lifecycle boundary.

MC history is capped at 5,000 lines and 8 MiB of UTF-8 text per terminal, so a long unterminated
line cannot bypass retention. Eviction removes the oldest output; live output is not truncated.
Client buffers have a separate 512 KiB cap
([`TerminalController`](../../apps/desktop-qt/src/native/TerminalController.cpp)). Measure
throughput with full scrollback when changing this path.

A client that falls behind is held back per subscription at the socket, not at the PTY: a
subscription made with `"acks": true`
([`OutputWindow`](../../apps/server-ex/lib/hal_c2/terminal/output_window.ex)) stops being sent
output once 64 KiB waits unacknowledged, and gets one snapshot when it has acknowledged what it
was sent. The shell is not paused, because another client may be keeping up and a paused PTY
would stall it too; bounded history is what the slow client catches up from. A snapshot's history
does not count against the 64 KiB: output held right after a large snapshot would make a client
that keeps up catch up from snapshot to snapshot.

The TUI acknowledges what its emulator has parsed, never what it has painted, so a terminal that
is not on screen still takes output. A terminal with no pane has no subscription, and so no window,
and catches up from a snapshot when it is shown again
([`terminalState`](../../apps/tui/src/host/terminalState.ts)).

## Renderer ownership

The phone and the Qt desktop use the same `libghostty-vt` C ABI for terminal behavior. Platform
adapters own drawing and input integration. The Qt desktop draws with
[qml-ghostty](https://github.com/hal-c2/qml-ghostty), whose own Ghostty pin
[`cmake/QmlGhostty.cmake`](../../apps/desktop-qt/cmake/QmlGhostty.cmake) checks
against ours at configure time. The canonical upstream pin is
[`native/libghostty-vt/VERSION`](../../native/libghostty-vt/VERSION); rebuild the native
artifacts when it changes.

Restoring scrollback must not send terminal replies to the current shell. Historical
device queries can otherwise provoke fresh replies that appear as junk at the
prompt. The MC strips query/response traffic from retained history, and the Qt drawer replays
through qml-ghostty's `restore()`, which answers nothing. Preserve both protections when changing
retention or renderer code.
