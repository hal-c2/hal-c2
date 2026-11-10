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

### Show times the way the user reads them

In the desktop app, `Format` from `HalC2.Bricks` writes times as the rest of the
app does: in the user's **Time format** (**Settings → General**: System
default, 12-hour or 24-hour) and locale. Each function takes a `Date`, an ISO
8601 string or milliseconds since the epoch, and returns `""` for a missing or
invalid time.

| Function              | Gives                                   |
| --------------------- | --------------------------------------- |
| `Format.time(at)`     | `18:05`, `6:05 PM`                      |
| `Format.date(at)`     | `9/20`, or `9/20/2025` in another year  |
| `Format.dateTime(at)` | `9/20 18:05`                            |
| `Format.relative(at)` | `just now`, `5m ago`, `in 2h`, `3d ago` |

```qml
import HalC2.Bricks

Text { text: Format.dateTime(order.placedAt) }
```

A text bound to one of them changes as soon as the user picks another time
format, and one bound to `Format.relative` moves on once a minute.

## Plugins that run on your MC

Some plugins do work on a machine rather than in one app, such as
[agent code review](code-review.md), the [planner](planner.md), the
[issue tracker](issue-tracker.md) and [maintenance](maintenance.md). They are
folders with a `plugin.json`, and each MC runs its own: put the folder in
`plugins` under the MC's data directory
(`~/.local/share/hal-c2/elixir/plugins/` on Linux). **Settings → Plugins** lists
them under the machine that has them, with what they do, who made them and
screenshots. A folder you put there later shows up after **Look for plugins**
beside the machine's name, or the MC's next in-place update.

Such a plugin is off until you turn it on. Turning it on shows what it asks to
do, such as commenting on pull requests or starting threads, and why. It runs
only if you accept, and an update that asks for more waits until you accept
again. Plugins that run code on the MC say so: they can do anything the MC can.
What a plugin asks for limits what it may do on the MC, not in the app: its
pages and other parts run in the app with the app's access, like any UI plugin,
so install only plugins you trust.

To see whether a plugin's code compiles without turning it on, use **Check that
it compiles** on its entry; the entry then says where the code fails, until the
plugin changes or you turn it on. The check grants nothing and leaves nothing
running, but compiling still runs some of the plugin's code, so check only
plugins you would consider running.

What a running plugin adds reaches every app connected to that machine:

- **Pages** are tabs next to **Threads** at the top of the window. Switch with a
  click or **Ctrl+Alt+]** and **Ctrl+Alt+[** (**⌘⌥]** and **⌘⌥[** on macOS). A
  plugin on several machines has one tab, or one per version when they run
  different versions, each named with its machines.
- **Threads it starts** carry its mark in the thread list and its header above
  the conversation. A plugin can keep its threads out of the list and show them
  on its page instead. They stay on their machine while the plugin runs there.
  Turn the plugin off and they are ordinary threads again, free to move, unless
  the plugin keeps its threads on their machine for good, as Code Review does.
  The threads it starts from then on cannot be moved or exported, even once the
  plugin is off or removed. The ones it started before stay too, but only while
  the plugin is installed.
- **Settings** open from the plugin's entry in **Settings → Plugins**. What the
  plugin refuses stays unsaved, with its reason. A plugin that failed can be
  restarted there.

### Plugins that watch your agents

Some plugins help agents work: they cut wasted tokens, catch an agent going in
circles, or keep notes across turns. What they ask for when you turn them on
says how far they reach:

- **See what agents do** lets a plugin follow every thread on the machine: the
  tools agents call, what those return, and the tokens each turn uses. It can
  also read the turns a thread ran before.
- **Add context and turn tools off** lets it put a note ahead of the first
  message of a new conversation and turn some of the agent's tools off. It is
  asked once as the conversation starts, and the conversation keeps that answer
  to its end. Claude turns off tools by name and Codex by capability; other
  agents get the note alone.
- **Send messages to agents** lets it steer a turn while that turn works, as if
  you had typed into the composer.
- **Show notices** lets it put a notice in a thread. A notice can offer
  **Stop**, which stops the turn it is about while that turn works.
- **Use your text model** lets it ask the **Text generation model** (**Settings
  → General**) to write for it, on your account with that provider.

### TokenEconomizer's micro-skills

TokenEconomizer's micro-skills learn short facts about each project's
environment from its turns: if agents in a project keep finding `pytest`
missing and running the tests through `python -m pytest`, that becomes one
line ("`pytest …` fails here with command not found; `python -m pytest …`
works"). Once a fact has recurred often enough, a new conversation in the
project is told it up front, so its agent skips the failing first attempt. A
fact the evidence turns against -- the plain command starts working -- stops
being stated on its own.

Learning is per project and needs no model. It is off until you turn it on:
under the plugin's **Settings**, set **Micro-skills** to **Learn environment
facts**. Two settings there bound what a new conversation is told: **Most
facts stated** and the facts' **token budget**.

Set **Micro-skills** to **Learn and ask a model** to also have your text
generation model propose facts the turns alone would not show, such as a build
step the tests need first. Every few turns (**Turns between proposals**) it
reads a digest of the project's recent turns -- commands, error lines and file
names, never file contents -- and each fact it proposes comes with a check
TokenEconomizer runs itself. A fact is kept only if that check holds on two of
the turns the model cites, and is stated only once later turns keep bearing it
out. Each proposal costs a model call; the plugin's status counts them and
their tokens. Its facts are listed, dropped and restored like the others.

A project whose saved micro-skills cannot be read is held rather than started
afresh: nothing is learned or stated there, and its listing says why, until
the file is fixed or removed.

## Connect Slack for plugins

Plugins on an MC reach Slack through that MC's one Slack connection, and only
those you allowed to read or write Slack when you turned them on. To connect it:

1. In **Settings → Integrations → Slack**, choose the environment and click
   **Copy app manifest**.
2. At [api.slack.com/apps](https://api.slack.com/apps), create an app from that
   manifest and install it to your workspace. It uses Socket Mode, so the MC
   needs no public address.
3. Under the app's **Basic Information**, add an app-level token with the
   `connections:write` scope.
4. Paste the bot token (`xoxb-…`) and the app token (`xapp-…`) into
   **Settings → Integrations → Slack** and click **Connect**. Both must come
   from the same app; the MC refuses tokens from two.

The MC keeps the tokens in its secret store and does not show them again;
**Disconnect** forgets them. The connection comes back on its own after a
network drop, a Slack outage or a restart. Invite the bot to the channels a
plugin should post in. Each environment needs a Slack app of its own: two MCs on one app would
split its events. A plugin that answers a slash command names it in its
settings; add that command to your Slack app yourself.
