# Sources:
#   docs/user/project-settings.md (Actions)
#   apps/server-ex/lib/hal_c2/worktree_setup.ex (setup script)
#   apps/web/src/components/ProjectScriptsControl.tsx
#   apps/web/src/components/chat/ThreadDetailsPanel.tsx (actions in the thread's details)
#   apps/web/src/components/projectScriptEditor.tsx
#   apps/web/src/components/useThreadTerminalActions.ts (runProjectScript)
#   packages/shared/src/projectScripts.ts
#   apps/tui/src/features.backlog.test.ts (project-scripts)
#   packages/contracts/src/project.ts (ProjectScript, ProjectScriptIcon)
#   packages/contracts/src/rpc.ts (projects.mutate, hal-c2.upsertKeybinding, hal-c2.removeKeybinding)

Feature: Project actions
  An action is a named command for a project, such as starting the dev server or running
  tests. One action can be the setup script that prepares every new worktree.

  Background:
    Given a connected environment with the project "shop"
    And "shop" has the action "Dev" running "bun dev"

  Rule: Running actions

    @backlog @desktop @tui
    Scenario: Running an action types its command into a terminal for the thread's workspace
      Given the user is looking at a thread in "shop" on a worktree
      When the user runs the action "Dev"
      Then a terminal in the worktree runs "bun dev"
      And the command knows the project folder and the worktree folder

    @backlog @desktop
    Scenario: The project's actions can be run from the thread's details
      Given the user is looking at the details of a thread in "shop"
      When the user runs "Dev" from the thread's details
      Then "bun dev" runs in a terminal for the thread's workspace

    @backlog @desktop @tui
    Scenario: Running an action while the terminal is busy opens a new terminal
      Given the thread's terminal is running a command
      When the user runs the action "Dev"
      Then "bun dev" runs in a new terminal
      And the busy terminal keeps running

    @backlog @desktop
    Scenario: The action the user ran last is offered first
      Given "shop" also has the action "Test"
      When the user runs the action "Test"
      Then "Test" is offered first the next time the user runs an action in "shop"

    @backlog @desktop @tui
    Scenario: An action runs from its keyboard shortcut
      Given "Dev" has the shortcut "mod+shift+d"
      When the user presses "mod+shift+d" in a thread of "shop"
      Then "bun dev" runs in the thread's terminal

    @backlog @desktop @tui
    Scenario: A failure to start an action is reported
      Given terminals cannot be opened for the thread
      When the user runs the action "Dev"
      Then the user is told the action "Dev" failed to run

  Rule: The setup script

    Background:
      Given "shop" has the setup action "Install" running "bun install"

    @node
    Scenario: The setup script runs in a new worktree before the agent starts
      Given "Install" waits for it to finish
      When a thread in "shop" starts on a new worktree
      Then "bun install" runs in the new worktree's setup terminal
      And the agent starts after "bun install" exits

    @node
    Scenario: A setup script that fails and must finish first stops the thread
      Given "Install" waits for it to finish
      And "bun install" exits with 1
      When a thread in "shop" starts on a new worktree
      Then the worktree setup fails with "Setup script exited with 1."
      And the agent does not start

    @node
    Scenario: A setup script that runs alongside the agent does not hold it back
      Given "Install" runs alongside the agent
      When a thread in "shop" starts on a new worktree
      Then the agent starts while "bun install" is still running
      And the setup reports how the script exited

    @node
    Scenario: A project without a setup script skips that step
      Given "shop" has no setup action
      When a thread in "shop" starts on a new worktree
      Then the setup script step is skipped
      And the agent starts

  Rule: Adding, editing and removing actions

    @backlog @desktop @mobile @tui
    Scenario: Adding an action
      When the user adds an action named "Test" running "bun test" with the test icon
      Then "shop" has the action "Test"
      And "Test" can be run

    @backlog @desktop @mobile @tui
    Scenario Outline: An action needs a name and a command
      When the user adds an action with <missing>
      Then the user is told "<message>"
      And no action is added

      Examples:
        | missing        | message               |
        | no name        | Name is required.     |
        | no command     | Command is required.  |

    @backlog @desktop @mobile @tui
    Scenario: Editing an action
      When the user changes the command of "Dev" to "bun run dev --host"
      Then "Dev" runs "bun run dev --host"

    @backlog @desktop @mobile @tui
    Scenario: Deleting an action asks first and cannot be undone
      When the user deletes the action "Dev"
      Then the user is asked to confirm deleting "Dev" because it cannot be undone
      When the user confirms
      Then "shop" no longer has the action "Dev"

    @backlog @desktop
    Scenario: Only one action can be the setup script
      Given "Install" is the setup script of "shop"
      When the user makes "Dev" run automatically on worktree creation
      Then "Dev" is the setup script
      And "Install" no longer runs on worktree creation

    @backlog @desktop
    Scenario: Clearing a shortcut removes it
      Given "Dev" has the shortcut "mod+shift+d"
      When the user clears the shortcut of "Dev"
      Then "mod+shift+d" no longer runs "Dev"

    @backlog @desktop
    Scenario: A shortcut still used by another project's action is kept
      Given the project "docs" also has an action "Dev" with the shortcut "mod+shift+d"
      When the user deletes the action "Dev" from "shop"
      Then "mod+shift+d" still runs "Dev" in "docs"

    @backlog @desktop
    Scenario: A preview address opens automatically only when one is set
      When the user edits "Dev" without a preview address
      Then opening the preview automatically cannot be turned on
      When the user sets the preview address "http://localhost:3000"
      Then opening the preview automatically can be turned on
