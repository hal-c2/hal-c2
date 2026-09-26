# Sources:
#   apps/tui/src/components/SettingsView.tsx, SettingsView.test.tsx
#   apps/tui/src/keymap.ts (keybinding reference)
#   apps/tui/src/components/ChatView.tsx (Settings palette entry)
#   apps/tui/src/hooks/useKeyBindings.ts (settings mode)
#   apps/tui/src/features.backlog.test.ts (editable-settings, server-operations)
#   Shared domain: settings/ owns every settings panel; editing stays there for now.

Feature: Settings in the terminal client
  The terminal client shows a read-only view of the settings that shape its behaviour.
  Editing settings is done in the web or desktop app until the terminal can do it.

  @tui
  Scenario: Settings opens a read-only reference
    When the user chooses "Settings" from the command palette
    Then the overlay shows providers, source control and keybindings

  @tui
  Scenario: The settings overlay scrolls
    Given the settings overlay is open
    When the user presses "PgDn"
    Then the overlay scrolls down

  @tui
  Scenario: Esc closes settings
    Given the settings overlay is open
    When the user presses "Esc"
    Then the conversation is shown again

  @tui
  Scenario: Settings is found by what it contains
    Given the command palette is open
    When the user types "keybindings"
    Then "Settings" is offered

  @backlog @tui
  Scenario: The user edits thread, git and text generation defaults
    When the user changes the default new-thread workspace to a new worktree
    Then the next new-thread draft preselects a new worktree

  @backlog @tui
  Scenario: The user manages provider instances and their secrets
    When the user adds a provider instance with an API key
    Then the provider is listed and the key is stored as a secret

  @backlog @tui
  Scenario: The user refreshes providers
    When the user refreshes providers
    Then provider status and models are fetched again

  @backlog @tui
  Scenario: The user updates a provider
    Given a provider has an update available
    When the user runs the provider update
    Then the update progress and result are shown

  @backlog @tui
  Scenario: The user reads server diagnostics
    When the user opens diagnostics
    Then the server's version, uptime and recent errors are shown

  @backlog @tui
  Scenario: An unhealthy server process is signalled
    Given the server reports a process as unhealthy
    Then the terminal client shows which process is unhealthy
