# Sources:
#   https://github.com/pingdotgg/t3code/pull/20857
#   apps/server-ex/lib/hal_c2/workflow_scripts.ex (orchestration.getWorkflowScript)
#   packages/contracts/src/orchestrationV2.ts (OrchestrationGetWorkflowScriptError reasons)
#   apps/server/src/orchestration-v2/ (workflow script reader)
@plugin-claude
Feature: Reading the script a Claude workflow ran
  A Claude workflow runs a script that Claude keeps under its projects folder.
  A client can ask the MC for that script to show it. The path the client
  sends is only a hint; the MC reads only JavaScript files inside Claude's
  projects folder.

  Background:
    Given an MC whose Claude projects folder exists

  @mc
  Scenario: Reading a workflow script
    Given a workflow script of 2 KB inside the Claude projects folder
    When a client asks for that script
    Then it receives the script's real path and its contents, not truncated

  @mc
  Scenario: Large scripts are cut at 256 KB
    Given a workflow script of 300 KB inside the Claude projects folder
    When a client asks for that script
    Then it receives the first 256 KB, marked truncated

  @mc
  Scenario Outline: Scripts that cannot be read
    Given <situation>
    When a client asks for that script
    Then it fails with reason "<reason>"

    Examples:
      | situation                                                       | reason           |
      | the path is relative                                            | invalid-path     |
      | the path does not end in .js                                    | invalid-path     |
      | the Claude projects folder does not exist                       | root-unavailable |
      | no file exists at the path                                      | not-found        |
      | the file is outside the Claude projects folder                  | outside-root     |
      | a link inside the folder points at a file outside it            | outside-root     |
      | a .js link inside the folder points at a file that is not .js   | not-js           |
      | the path is a folder named like a script                        | not-regular-file |
      | the file cannot be opened                                       | read-failed      |

  @mc
  Scenario: A script replaced while it is being read is refused
    Given a workflow script is replaced between finding it and opening it
    When a client asks for that script
    Then it fails with reason "changed-during-read"

  # Upstream #20857: a workflow thread opens with its phases and agents instead of its script
  @backlog @mc @shared
  Scenario: A workflow's thread opens with what the workflow is
    Given a Claude workflow ran with a name, a description, phases and agents
    When the user opens the workflow's thread
    Then it opens with the workflow's name, description, phases and agents
    And the script is folded away behind "Show full script"

  # Upstream #20857: the folded script stays searchable
  @backlog @shared
  Scenario: A folded workflow script is still found by Find
    Given a workflow thread whose script is folded away
    When the user finds a word that is only in the script
    Then the match is found in the script
