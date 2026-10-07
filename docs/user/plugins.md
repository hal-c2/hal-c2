# Plugins

A plugin adds something small of your own to the desktop app: a clock in the
status bar, a quota meter under the thread list, a button beside the composer.
Each plugin is one QML file.

## Add a plugin

Open **Settings → Plugins**. Put a plugin file in the folder named at the top
of that page, or paste the address of one into **Load from URL**. HAL-C2 asks
before it downloads anything: a plugin from a URL is not signed, and a plugin
can do whatever the app can.

A plugin shows up as soon as its file is in the folder. Saving the file again
replaces the plugin while the app runs. If the new version has a mistake, the
version that was already running stays and the page says what went wrong.

## Turn a plugin off or remove it

**Disable** keeps the file and hides what the plugin added; **Enable** brings
it back. A disabled plugin stays disabled when you restart. The trash button
deletes the file.

## Write a plugin

A plugin names the places it adds to:

| Place              | Where it shows                  |
| ------------------ | ------------------------------- |
| `sidebar.footer`   | Under the thread list           |
| `composer.actions` | With the composer's own actions |
| `statusbar`        | Along the bottom of the window  |

```qml
import OpenTUI

Plugin {
    pluginId: "clock"

    property string now: new Date().toLocaleTimeString()

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: now = new Date().toLocaleTimeString()
    }

    Contribution {
        slot: "statusbar"
        Text { text: now }
    }
}
```

The same file works in the terminal client. Keep to `Text`, `Row`, `Column`,
`Rectangle` and `Timer` if you want it on both. A plugin that names a place the
app does not have is listed as loaded and shows nothing.

## Plugins that run on your MC

Some plugins do work on a machine rather than in one app, such as
[agent code review](code-review.md). They are folders with a `plugin.json`, and
each MC runs its own: put the folder in `plugins` under the MC's data directory
(`~/.local/share/hal-c2/elixir/plugins/` on Linux). **Settings → Plugins** lists
them under the machine that has them, with what they do, who made them and
screenshots.

Such a plugin is off until you turn it on. Turning it on shows what it asks to
do, such as commenting on pull requests or starting threads, and why. It runs
only if you accept, and an update that asks for more waits until you accept
again. Plugins that run code on the MC say so: they can do anything the MC can.
What a plugin asks for limits what it may do on the MC, not in the app: its
pages and other parts run in the app with the app's access, like any UI plugin,
so install only plugins you trust.

What a running plugin adds reaches every app connected to that machine:

- **Pages** are tabs next to **Threads** at the top of the window. Switch with a
  click or **Ctrl+Alt+]** and **Ctrl+Alt+[** (**⌘⌥]** and **⌘⌥[** on macOS). A
  plugin on several machines has one tab, or one per version when they run
  different versions, each named with its machines.
- **Threads it starts** carry its mark in the thread list and its header above
  the conversation. A plugin can keep its threads out of the list and show them
  on its page instead. They stay on their machine while the plugin runs there.
  Turn the plugin off and they are ordinary threads again, free to move.
- **Settings** open from the plugin's entry in **Settings → Plugins**. What the
  plugin refuses stays unsaved, with its reason. A plugin that failed can be
  restarted there.
