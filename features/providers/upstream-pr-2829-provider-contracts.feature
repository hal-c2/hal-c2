# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   upstream commits 3ec7df1e8, 98400c6a5, 954dbd734, 0481b76be,
#     55cb2fc69, 2679d279c, a3fbbe453, 1f2f91ded, f8b86345a,
#     def34c28b, 0dcb029da
#   apps/server/src/orchestration-v2/Adapters/
#   apps/server-ex/lib/hal_c2/{codex,claude,acp}/
Feature: Provider-specific workflow contracts
  Providers may expose different protocols, but the node keeps the same
  user-visible rules for permissions, plans, tool activity, attachments and
  provider failures.

  @node @backlog @plugin-claude
  Scenario: Claude still asks before a command in auto-accept edits
    Given a Claude thread is in auto-accept edits
    When Claude requests to run a command
    Then the thread waits for the user's approval
    And the command is not silently approved as full access

  @node @backlog @plugin-grok @plugin-cursor @plugin-opencode @plugin-antigravity @plugin-acp-registry
  Scenario: An ACP allow-once approval does not become an allow-always grant
    Given an ACP provider asks to run a command
    When the user allows it once
    Then that command proceeds
    And the provider must ask again for a later matching command

  @node @backlog @plugin-grok
  Scenario: A Grok session grant stays in the session
    Given the user allows a Grok command for this session
    When another project asks Grok to run the same command
    Then the other project still asks for approval

  @node @backlog @plugin-codex
  Scenario: A completed Codex plan can be implemented again
    Given Codex has proposed a plan and the plan is shown as complete
    When the user chooses Implement
    Then a new run starts from that plan
    And the Implement action remains available until the plan is used

  @node @backlog @plugin-opencode
  Scenario: OpenCode can generate a thread title
    Given an OpenCode thread has no generated title
    When the node asks OpenCode to generate one
    Then the returned title is stored on the thread
    And the title request does not become a user turn

  @node @backlog @shared
  Scenario Outline: Read and search activity keeps its tool meaning
    Given the provider emits a tool item of kind <provider-kind>
    When the node projects the item
    Then the timeline classifies it as <timeline-kind>

    Examples:
      | provider-kind | timeline-kind |
      | read          | file read     |
      | search        | file search   |
      | fetch         | web search    |

  @node @backlog @plugin-grok @plugin-cursor @plugin-opencode @plugin-antigravity @plugin-acp-registry
  Scenario: An ACP edit with old and new text produces a useful diff
    Given an ACP provider edits a file by sending old text and new text
    When the node projects the file change
    Then the change includes the replaced lines
    And the diff does not appear empty merely because no patch was supplied

  @node @backlog @plugin-grok @plugin-cursor @plugin-opencode @plugin-antigravity @plugin-acp-registry
  Scenario: An ACP agent can read a file while write approval is pending
    Given an ACP provider is waiting for approval to write
    When it requests a read of a workspace file
    Then the read is allowed
    And the pending write remains awaiting approval

  @node @backlog @plugin-antigravity
  Scenario: Antigravity can inspect an unsupported file by path
    Given Antigravity cannot classify a file's usual language
    When it requests that file by path
    Then the provider receives the file contents

  @node @backlog @shared
  Scenario: A provider failure explains how the user can recover
    Given a provider cannot start its session
    When the run fails
    Then the thread contains an actionable provider error
    And the error names the next recovery action when one is known

  @node @backlog @shared
  Scenario: A rejected usage-limit wake keeps its reset time
    Given a thread is waiting for a provider limit to reset at 15:00
    When the provider rejects the automatic wake
    Then the thread still records 15:00 as the next reset time
