# Terminal history

Each terminal keeps up to 5,000 lines and 8 MiB of scrollback on its environment
server. HAL-C2 removes the oldest output when either limit is reached. A long
line can be shortened at the start. New terminal output is not truncated.

These limits apply when you reconnect and when HAL-C2 restores saved terminal
history. A client can show less scrollback than the server keeps.
