# Sources:
#   docs/user/project-settings.md (Actions)
#   apps/server-ex/lib/hal_c2/worktree_setup.ex (setup script)
#   apps/web/src/components/ProjectScriptsControl.tsx
#   apps/web/src/components/chat/ThreadDetailsPanel.tsx (actions in the thread's details)
#   apps/web/src/components/projectScriptEditor.tsx
#   apps/web/src/components/projectScriptEditor.tsx (save lifecycle, validation)
#   apps/web/src/projectScripts.ts (action identities, primary and setup action, shortcut commands)
#   apps/web/src/lib/projectScriptKeybindings.ts (a shortcut that is not a key combination)
#   apps/web/src/components/useThreadTerminalActions.ts (runProjectScript)
#   packages/shared/src/projectScripts.ts
#   apps/tui/src/features.backlog.test.ts (project-scripts)
#   packages/contracts/src/project.ts (ProjectScript, ProjectScriptIcon)
#   packages/contracts/src/rpc.ts (projects.mutate, hal-c2.upsertKeybinding, hal-c2.removeKeybinding)
#   apps/desktop-qt/src/native/WorkspaceController.cpp (the header's action menu, the action run last)
#   apps/desktop-qt/src/native/TerminalController.cpp (runs an action in the thread's drawer)
#   apps/web/src/components/ChatView.tsx (deleting an action: the confirmation by name, the failure)

Feature: Project actions
  An action is a named command for a project, such as starting the dev server or running
  tests. One action can be the setup script that prepares every new worktree.

  Background:
    Given a connected environment with the project "shop"
    And "shop" has the action "Dev" running "bun dev"

  Rule: Running actions

    @desktop @tui
    Scenario: Running an action types its command into a terminal for the thread's workspace
      Given the user is looking at a thread in "shop" on a worktree
      When the user runs the action "Dev"
      Then a terminal in the worktree runs "bun dev"
      And the command knows the project folder and the worktree folder

    @desktop
    Scenario: The project's actions can be run from the thread's details
      Given the user is looking at the details of a thread in "shop"
      When the user runs "Dev" from the thread's details
      Then "bun dev" runs in a terminal for the thread's workspace

    @desktop @tui
    Scenario: Running an action while the terminal is busy opens a new terminal
      Given the thread's terminal is running a command
      When the user runs the action "Dev"
      Then "bun dev" runs in a new terminal
      And the busy terminal keeps running

    @desktop
    Scenario: The action the user ran last is offered first
      Given "shop" also has the action "Test"
      When the user runs the action "Test"
      Then "Test" is offered first the next time the user runs an action in "shop"

    @desktop @tui
    Scenario: An action runs from its keyboard shortcut
      Given "Dev" has the shortcut "mod+shift+d"
      When the user presses "mod+shift+d" in a thread of "shop"
      Then "bun dev" runs in the thread's terminal

    @desktop @tui
    Scenario: A failure to start an action is reported
      Given terminals cannot be opened for the thread
      When the user runs the action "Dev"
      Then the user is told the action "Dev" failed to run

    @backlog @desktop
    Scenario: The action offered first is never the setup script
      Given "shop" has the setup action "Install" and the action "Dev"
      And the user has not run any action in "shop"
      When the user looks at the actions of "shop"
      Then "Dev" is the action offered first
      And "Install" is listed as the setup script

    @backlog @desktop
    Scenario: A project with only a setup script still offers it
      Given "shop" has only the setup action "Install"
      When the user looks at the actions of "shop"
      Then "Install" is offered

  Rule: The setup script

    Background:
      Given "shop" has the setup action "Install" running "bun install"

    @mc
    Scenario: The setup script runs in a new worktree before the agent starts
      Given "Install" waits for it to finish
      When a thread in "shop" starts on a new worktree
      Then "bun install" runs in the new worktree's setup terminal
      And the agent starts after "bun install" exits

    @mc
    Scenario: A setup script that fails and must finish first stops the thread
      Given "Install" waits for it to finish
      And "bun install" exits with 1
      When a thread in "shop" starts on a new worktree
      Then the worktree setup fails with "Setup script exited with 1."
      And the agent does not start

    @mc
    Scenario: A setup script that runs alongside the agent does not hold it back
      Given "Install" runs alongside the agent
      When a thread in "shop" starts on a new worktree
      Then the agent starts while "bun install" is still running
      And the setup reports how the script exited

    @mc
    Scenario: A project without a setup script skips that step
      Given "shop" has no setup action
      When a thread in "shop" starts on a new worktree
      Then the setup script step is skipped
      And the agent starts

  Rule: Adding, editing and removing actions

    @desktop @mobile @tui @backlog-mobile
    Scenario: Adding an action
      When the user adds an action named "Test" running "bun test" with the test icon
      Then "shop" has the action "Test"
      And "Test" can be run

    @desktop @mobile @tui @backlog-mobile
    Scenario Outline: An action needs a name and a command
      When the user adds an action with <missing>
      Then the user is told "<message>"
      And no action is added

      Examples:
        | missing        | message               |
        | no name        | Name is required.     |
        | no command     | Command is required.  |

    @desktop @mobile @tui @backlog-mobile
    Scenario: Editing an action
      When the user changes the command of "Dev" to "bun run dev --host"
      Then "Dev" runs "bun run dev --host"

    @desktop @mobile @tui @backlog-mobile
    Scenario: Deleting an action asks first and cannot be undone
      When the user deletes the action "Dev"
      Then the user is asked to confirm deleting "Dev" because it cannot be undone
      When the user confirms
      Then "shop" no longer has the action "Dev"

    @backlog @desktop
    Scenario: Deleting an action is confirmed by name
      When the user deletes the action "Dev" and confirms
      Then the user sees a "success" toast "Deleted action "Dev""

    @backlog @desktop
    Scenario: An action that could not be deleted is reported and kept
      Given the environment refuses to save the project's actions
      When the user deletes the action "Dev" and confirms
      Then the user sees an "error" toast "Could not delete action" with the reason
      And "shop" still has the action "Dev"

    @desktop
    Scenario: Only one action can be the setup script
      Given "Install" is the setup script of "shop"
      When the user makes "Dev" run automatically on worktree creation
      Then "Dev" is the setup script
      And "Install" no longer runs on worktree creation

    @desktop
    Scenario: Clearing a shortcut removes it
      Given "Dev" has the shortcut "mod+shift+d"
      When the user clears the shortcut of "Dev"
      Then "mod+shift+d" no longer runs "Dev"

    # Legacy: apps/web/src/lib/projectScriptKeybindings.ts (decodeProjectScriptKeybindingRule), projectScriptEditor.tsx
    @backlog @desktop
    Scenario: A shortcut that is not a key combination is refused before the action is saved
      When the user saves a new action named "Test" with the shortcut "mod+shift+"
      Then the form says "Invalid keybinding."
      And "shop" has no action named "Test"

    @desktop
    Scenario: A shortcut still used by another project's action is kept
      Given the project "docs" also has an action "Dev" with the shortcut "mod+shift+d"
      When the user deletes the action "Dev" from "shop"
      Then "mod+shift+d" still runs "Dev" in "docs"

    @desktop
    Scenario: A preview address opens automatically only when one is set
      When the user edits "Dev" without a preview address
      Then opening the preview automatically cannot be turned on
      When the user sets the preview address "http://localhost:3000"
      Then opening the preview automatically can be turned on

    @backlog @desktop
    Scenario: Actions with the same name are both kept
      When the user adds another action named "Dev" running "bun run dev:api"
      Then "shop" has two actions named "Dev"
      And each of them runs its own command

    @backlog @desktop
    Scenario: Waiting for setup to finish can only be chosen for the setup script
      When the user edits "Dev" so it does not run on worktree creation
      Then waiting for it to finish before the agent starts cannot be turned on
      When the user makes "Dev" run automatically on worktree creation
      Then waiting for it to finish before the agent starts can be turned on

    @backlog @desktop
    Scenario: A save that fails keeps the action's form open for another try
      Given the environment refuses to save actions
      When the user saves a new action named "Test"
      Then the form stays open with what the user typed
      And the form shows why the action could not be saved
      When the environment accepts saves again and the user saves
      Then "shop" has the action "Test"

    @backlog @desktop
    Scenario: An action cannot be saved twice while it is being saved
      When the user saves a new action named "Test" and presses save again before it finishes
      Then "shop" has one action named "Test"
      And the form cannot be edited until the save finishes

    @backlog @desktop
    Scenario: Closing the form while saving ignores the result
      Given the user saved a new action and the save is still running
      When the user cancels the form and opens it again for another action
      Then the late result does not close or change the new form

    @backlog @desktop
    Scenario: An action from hal-c2.json that cannot be imported opens the form with its values
      Given the checkout's hal-c2.json declares the action "Lint" and the environment refuses to save it
      When the user imports "Lint"
      Then the form opens filled in with "Lint"
      And the form shows why it could not be imported

    @backlog @desktop
    Scenario: An action that was set to wait for setup keeps that when imported
      Given the checkout's hal-c2.json declares the setup action "Install" that does not run alongside the agent
      When the user imports "Install"
      Then "Install" waits for it to finish before the agent starts

    @backlog @desktop
    Scenario Outline: An action's identity may be too old to carry a shortcut
      Given "shop" has an action with the identity "<id>" from an earlier version
      When the user opens the actions of "shop"
      Then the action can still be run and edited
      And it shows no shortcut

      Examples:
        | id                               |
        | install-javascript-dependencies  |
        | A.b                              |
