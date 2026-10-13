# Plugins

Each folder here is an MC plugin package: an ordinary plugin that needs nothing
from this repository but the plugin API. Copy a folder into an MC's `plugins`
folder to install it, or start your own from one of them.

| Plugin                      | What it does                                                                                  | Uses                                                          |
| --------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| [code-review](code-review/) | An agent reviews pull requests; you decide what reaches GitHub.                               | pull requests, threads, agent tools                           |
| [planner](planner/)         | A plan of tasks and milestones as a Gantt chart, board or list; agents propose changes to it. | issues and boards, pull requests, threads, Slack, agent tools |

## Writing one

A package is a `plugin.json`, an `mc/` folder with the Elixir that runs on the MC,
a `ui/` folder with one self-contained QML file per part, and `assets/`. How a
plugin is written, what it may ask for and what each part gets is in
[docs/user/plugins.md](../docs/user/plugins.md#write-a-plugin); the behaviour of
the plugin host itself is in [features/plugins/](../features/plugins/).

What the MC lends a plugin, each behind a permission the user grants:

- the MC's projects and agents, and threads it starts and reads;
- pull requests, issues, milestones and GitHub Projects boards, through the
  machine's `gh` login;
- the MC's Slack connection: posting as the bot, and hearing mentions, replies and
  slash commands;
- tools for agents, offered in HAL-C2's MCP server;
- a data folder of its own, and topics its UI parts watch.

The two packages here use all of it, and their tests show how to test a plugin:
MC scenarios in `features/`, run with `mix features`, and the desktop drawing the
QML against a fake of the MC part in `tst_Features`.
