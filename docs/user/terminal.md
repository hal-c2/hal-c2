# Terminal history

Each terminal keeps up to 5,000 lines and 8 MiB of scrollback on its environment
server. HAL-C2 removes the oldest output when either limit is reached. A long
line can be shortened at the start. New terminal output is not truncated.

These limits apply when you reconnect and when HAL-C2 restores saved terminal
history. A client can show less scrollback than the server keeps.

## Running a command from a reply

When the agent writes a shell command in a code block, **Run in terminal** beside
**Copy** runs it in the thread's terminal, in the thread's folder. It is offered only
on a finished reply whose block is one complete command: a `sh`, `bash`, `zsh`,
`fish`, `shell`, `powershell` or `pwsh` block of a single line that does not end in a
backslash. Running it does not change the action the header offers next.

# Terminals on the phone

Tap the terminal button in a thread to open its terminal, and hold it for the
menu of the thread's terminals and scripts. The terminal's own menu also has the
text size and adds the lines on screen to your message.

Drag to scroll, hold a word to select it, and tap a link to open it. The row of
keys above the keyboard has the keys a touch keyboard lacks; Ctrl and Alt apply
to the next key you type.
