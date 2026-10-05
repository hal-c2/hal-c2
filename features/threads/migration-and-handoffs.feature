# Sources:
#   docs/user/thread-migration.md
#   docs/user/portable-handoffs.md
#   docs/internals/context-handoffs.md
#   apps/web/src/components/LegacyThreadMigrationToast.tsx
#   apps/server-ex/lib/hal_c2/import/v2.ex
#   apps/server-ex/lib/hal_c2/import/previous_install.ex
#   apps/server-ex/lib/mix/tasks/hal_c2.threads.import.ex
#   apps/server-ex/lib/hal_c2/orchestration/handoff.ex
# Moving a thread to another machine, where the handoff is the fallback: threads/moving-between-machines.feature.

Feature: Carrying threads and context across servers and agents
  Threads made on an older server come across once, with their conversation. When an
  agent has to pick up a conversation it did not see, it gets a trimmed account of it.

  @mc
  Scenario: Threads from the previous server carry over to the MC
    Given the previous server's event log holds the threads "Alpha" and "Beta"
    When the MC imports that log
    Then "Alpha" and "Beta" are listed with their messages, titles and projects
    And the previous server's log is left unchanged

  @mc
  Scenario: Importing keeps read state quiet
    Given the previous server recorded visits to "Alpha"
    When the MC imports that log
    Then "Alpha" keeps its read state without showing new activity

  @mc
  Scenario: The threads of an older install on the same machine are offered
    Given a T3 Code install on this machine holds the threads "Alpha" and "Beta"
    When the user asks which threads that install holds
    Then "Beta" and "Alpha" are offered with their project, newest first
    And the thread "Alpha"'s subagent ran in is counted with it, not offered on its own

  @mc
  Scenario: A thread picked from an older install comes with everything it had
    Given a T3 Code install on this machine holds the threads "Alpha" and "Beta"
    When the user imports "Alpha" from that install
    Then "Alpha" is listed in a new project at the folder it worked in
    And "Alpha" has its messages, its subagent's thread, its attachment and its terminal scrollback
    And "Alpha" keeps its tie to the agent's session, with the turn it was running ended
    And "Beta" is not imported
    And the install is left unchanged

  @mc
  Scenario: A picked thread joins the project already at its folder
    Given a T3 Code install on this machine holds the threads "Alpha" and "Beta"
    And the project "shop" is at the folder that install worked in
    When the user imports "Alpha" from that install
    Then "Alpha" is listed in "shop"

  @mc
  Scenario: A thread that was already picked is not imported again
    Given a T3 Code install on this machine holds the threads "Alpha" and "Beta"
    And the user imported "Alpha" from that install
    When the user imports "Alpha" from that install
    Then the user is told "Alpha" is already here
    And that install offers "Alpha" as imported

  @backlog @mc
  Scenario: Threads from the first version are migrated once
    Given the first version's database holds the thread "Legacy work"
    When the environment starts for the first time on the new version
    Then "Legacy work" is listed
    And the first version's database is not changed
    And starting again does not migrate it a second time

  @mc
  Scenario Outline: What a migrated thread keeps
    Given the first version's thread "Legacy work" had <detail>
    When the thread is migrated
    Then "Legacy work" still has <detail>

    Examples:
      | detail                                      |
      | its title and project                       |
      | its agent and model                         |
      | its permission and interaction modes        |
      | its branch and worktree                     |
      | its archive, settle, snooze and pin state   |
      | its linked pull request                     |
      | its user and agent messages with timestamps |
      | its supported attachments                   |

  @mc
  Scenario Outline: What a migrated thread leaves behind
    Given the first version's thread "Legacy work" had <detail>
    When the thread is migrated
    Then "Legacy work" does not have <detail>

    Examples:
      | detail                |
      | a live agent session  |
      | checkpoints and diffs |
      | tool activity         |
      | pending approvals     |
      | plans                 |

  @mc
  Scenario: The first message after migration starts a fresh agent with the history
    Given "Legacy work" was migrated
    When the user sends its first message after the migration
    Then a new agent session starts
    And the agent receives a trimmed account of the earlier conversation

  @desktop @mobile @backlog-mobile
  Scenario: The user is told threads were migrated
    Given threads were migrated from the first version
    When the user opens the app
    Then the user is told the threads were brought over

  @mc
  Scenario: A short conversation is handed over whole
    Given the thread "Alpha" has a short conversation on Codex
    When the user switches "Alpha" to Claude and sends a message
    Then Claude receives the whole conversation ahead of the message

  @mc
  Scenario: A long conversation keeps what matters most
    Given the thread "Alpha" has a conversation longer than the handoff budget
    When the user switches "Alpha" to Claude and sends a message
    Then Claude receives the original request, the recent turns and command outcomes
    And the new message is never shortened

  @mc
  Scenario: Left-out history can be looked up
    Given parts of the conversation did not fit in the handoff
    When the agent needs one of the left-out parts
    Then the agent can read it through the thread-reading tool

  @backlog @mc
  Scenario: A handoff that cannot fit at all fails clearly
    Given even the references to earlier history do not fit the agent's context
    When the user sends a message after switching agents
    Then the user is told the conversation is too large to hand over

  @backlog @mc
  Scenario Outline: The handoff budget follows its setting
    Given the handoff token cap is set to <cap>
    When a conversation is handed to another agent
    Then the handoff uses at most <used> tokens

    Examples:
      | cap    | used  |
      | unset  | 16000 |
      | 500    | 1024  |
      | 100000 | 64000 |

  @mc
  Scenario: Each command the agent ran is handed over with how it ended
    Given the thread "Alpha" has attachments and tool activity
    When the user switches "Alpha" to another agent
    Then the new agent receives each command with its exit code and output

  @mc
  Scenario: Reasoning and attachments are not handed over
    Given the thread "Alpha" has attachments and tool activity
    When the user switches "Alpha" to another agent
    Then the new agent receives only what was said and the commands that ran

  @mc
  Scenario: A transcript handoff stays well inside the agent's context
    Given the thread "Alpha" has more than 60,000 characters of history
    When the user switches "Alpha" to another agent and sends a message
    Then the agent receives at most 60,000 characters of history
    And every message it receives is whole
