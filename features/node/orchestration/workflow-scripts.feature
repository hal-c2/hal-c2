# Sources:
#   apps/server-ex/lib/t3/workflow_scripts.ex (orchestration.getWorkflowScript)
#   packages/contracts/src/orchestrationV2.ts (OrchestrationGetWorkflowScriptError reasons)
#   apps/server/src/orchestration-v2/ (workflow script reader)
@plugin-claude
Feature: Reading the script a Claude workflow ran
  A Claude workflow runs a script that Claude keeps under its projects folder.
  A client can ask the node for that script to show it. The path the client
  sends is only a hint; the node reads only JavaScript files inside Claude's
  projects folder.

  Background:
    Given a node whose Claude projects folder exists

  @node
  Scenario: Reading a workflow script
    Given a workflow script of 2 KB inside the Claude projects folder
    When a client asks for that script
    Then it receives the script's real path and its contents, not truncated

  @node
  Scenario: Large scripts are cut at 256 KB
    Given a workflow script of 300 KB inside the Claude projects folder
    When a client asks for that script
    Then it receives the first 256 KB, marked truncated

  @node
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

  @node
  Scenario: A script replaced while it is being read is refused
    Given a workflow script is replaced between finding it and opening it
    When a client asks for that script
    Then it fails with reason "changed-during-read"
