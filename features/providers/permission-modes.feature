# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829 (Codex interaction mode after resume, Grok permission mode)
#   docs/user/permission-modes.md
#   apps/server-ex/lib/hal_c2/claude/thread_runtime.ex (runtime mode map, approval decisions, plan capture)
#   apps/server-ex/lib/hal_c2/codex/thread_runtime.ex (approval policy and sandbox map, acceptAlways -> acceptForSession, collaborationMode)
#   apps/server-ex/lib/hal_c2/acp.ex (grok and cursor launch flags per mode, opencode ignores the mode)
#   apps/server-ex/lib/hal_c2/acp/thread_runtime.ex (full-access auto-grant, allow/reject option choice, cancellation)
#   apps/server-ex/lib/hal_c2/orchestration/delegation.ex (child runtime/interaction mode escalation refused)
#   apps/server-ex/lib/hal_c2/settings.ex (defaultRuntimeMode is project-scoped)
#   apps/server/src/orchestration-v2/Adapters/CodexAdapterV2.ts (auto -> auto_review), apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts
#   apps/web/src/components/chat/runtimeModeConfig.ts, apps/web/src/components/settings/ProjectDefaultsSettings.tsx (New threads -> Permissions)
#   apps/tui/src/controls.ts (runtime mode and plan/build toggles)
#   packages/contracts/src/orchestration.ts (RuntimeMode, ProviderApprovalDecision, InteractionMode)

@node
Feature: Permission modes
  A thread's permission mode decides when the agent must ask before acting. HAL-C2 has
  four modes and each provider maps them onto its own permission system. Approvals and
  plan mode work the same way from the user's side whichever provider runs the turn.

  Background:
    Given a connected environment with the project "shop"

  Scenario: New threads start in full access
    Given no default permission mode is set
    When the user starts a new thread
    Then the thread is in full access

  Scenario: A project can have its own default permission mode
    Given the environment default is full access
    And the project "shop" defaults to supervised
    When the user starts a new thread in "shop"
    Then the thread is supervised

  # auto was acceptEdits on the node; the Node server passes Claude's own auto mode.
  Scenario Outline: Each mode reaches Claude as its own permission mode
    Given a Claude thread in <mode>
    When the user sends a message
    Then Claude runs with the "<claude>" permission mode

    Examples:
      | mode              | claude            |
      | supervised        | default           |
      | auto-accept edits | acceptEdits       |
      | auto              | auto              |
      | full access       | bypassPermissions |

  Scenario Outline: Each mode reaches Codex as an approval policy and a sandbox
    Given a Codex thread in <mode>
    When the user sends a message
    Then Codex runs with the "<policy>" approval policy and the "<sandbox>" sandbox

    Examples:
      | mode              | policy     | sandbox          |
      | supervised        | untrusted  | readOnly         |
      | auto-accept edits | on-request | workspaceWrite   |
      | auto              | on-request | workspaceWrite   |
      | full access       | never      | dangerFullAccess |

  Scenario Outline: Each mode reaches Grok as a launch flag
    Given a Grok thread in <mode>
    When the user sends a message
    Then Grok starts with <flags>

    Examples:
      | mode              | flags                           |
      | supervised        | the default permission mode     |
      | auto-accept edits | the acceptEdits permission mode |
      | auto              | the auto permission mode        |
      | full access       | every action approved           |

  Scenario: Cursor is told the thread's mode when it starts
    Given a Cursor thread in auto-accept edits
    When the user sends a message
    Then Cursor starts in auto-accept edits

  Scenario: An ACP agent in full access is granted every request at once
    Given an OpenCode thread in full access
    When OpenCode asks to run a command
    Then the request is allowed without asking the user

  Scenario: An ACP agent outside full access asks the user
    Given an OpenCode thread in supervised
    When OpenCode asks to run a command
    Then the user is asked to approve the command

  Scenario Outline: The user's approval decision reaches the provider
    Given a <provider> thread waiting on a command approval
    When the user chooses "<decision>"
    Then the provider receives <received>

    Examples:
      | provider | decision                  | received                      |
      | Codex    | Allow once                | accept                        |
      | Codex    | Always allow this session | accept for the session        |
      | Codex    | Decline                   | decline                       |
      | Claude   | Always allow this session | allow                         |
      | Claude   | Decline                   | a denial saying "The user declined." |
      | Grok     | Always allow this session | its allow-always option       |
      | Grok     | Decline                   | its reject-once option        |

  Scenario: Interrupting a turn cancels its open approvals
    Given a Codex thread waiting on a command approval
    When the user interrupts the turn
    Then the approval is closed as cancelled

  Scenario: Dismissing a Claude question tells Claude it was dismissed
    Given Claude asked the user a question
    When the user dismisses the question
    Then Claude is told "The user dismissed the question."

  Scenario: Plan mode captures Claude's plan and stops
    Given a Claude thread in plan mode
    When Claude proposes a plan
    Then the plan is shown to the user
    And Claude stops to wait for the user's feedback

  Scenario: Codex always receives the thread's interaction mode explicitly
    Given a resumed Codex thread that last ran in plan mode
    When the user sends a message in default mode
    Then Codex runs in default mode

  Scenario: A delegated child cannot have more permission than its parent
    Given a supervised thread
    When the agent delegates a task in full access
    Then the delegation is refused with "Child runtime mode full-access is broader than parent mode approval-required."

  Scenario: A delegated child of a plan-mode thread stays in plan mode
    Given a thread in plan mode
    When the agent delegates a task in default mode
    Then the delegation is refused because the child mode is broader than plan

  Scenario: A delegated child inherits its parent's modes by default
    Given an auto-accept edits thread in plan mode
    When the agent delegates a task without naming modes
    Then the child thread runs in auto-accept edits and plan mode

  Scenario Outline: Auto uses the provider's automatic review where it has one
    Given a <provider> thread in auto
    When the agent runs a routine action
    Then <outcome>

    Examples:
      | provider    | outcome                                         |
      | Codex       | the provider's automatic reviewer approves it   |
      | Claude      | the provider's automatic reviewer approves it   |
      | OpenCode    | the user is asked, as in supervised             |

    # Cursor and Antigravity rows split out: they still need node work.
    @backlog
    Examples: Not yet on the node
      | provider    | outcome                                         |
      | Cursor      | the provider's automatic reviewer approves it   |
      | Antigravity | the user is asked, as in supervised             |

  @backlog
  Scenario: Grok remembers an always-allowed command for the session
    Given the user chose "Always allow this session" for a Grok command
    When Grok runs the same command again
    Then it is allowed without asking
    And a different command still asks

  @backlog
  Scenario: Antigravity can still ask in full access
    Given an Antigravity thread in full access
    When Antigravity sends its own approval request
    Then the user is asked to approve it

  Scenario: Pi does not offer auto
    Given a Pi thread
    When the user opens the permission mode choices
    Then auto is not offered

  @tui
  Scenario: Changing the mode mid-thread applies from the next turn
    Given a supervised thread with a running turn
    When the user switches the thread to full access
    Then the running turn keeps supervised
    And the next turn runs in full access

  @tui
  Scenario: Switching back to a stricter mode applies from the next turn
    Given a full access thread
    When the user switches the thread to supervised
    Then the next turn asks before commands and file changes

  @backlog @desktop @mobile
  Scenario: The permission mode can be changed from the desktop and mobile composers
    Given a supervised thread
    When the user switches the thread to auto-accept edits on desktop or mobile
    Then the next turn runs in auto-accept edits
