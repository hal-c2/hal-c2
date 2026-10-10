# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/user/activity-log.md
#   packages/client-runtime/src/halC2ToolSummary.ts, halC2ToolSummary.test.ts (summary counting rules)
#   packages/client-runtime/src/work-log/commandLabel.ts (a command's program, the shell wrapper left out)
#   packages/client-runtime/src/work-log/presentation.ts (command echo, viewed image, summaries), userInput.ts (answer preview), scrollAnchor.ts (group position)
#   apps/web/src/components/chat/MessagesTimeline.tsx (Tool calls group, Tool call failed, tool statuses, workEntryIconName)
#   apps/web/src/components/chat/V2ItemInspector.tsx (call details, file changes, Open diff)
#   apps/web/src/components/chat/ChangedFilesTree.tsx (heading counts and totals, folder totals, per-turn expansion, right click)
#   apps/web/src/components/chat/DiffStatLabel.tsx
#   apps/web/src/components/DiffPanel.tsx
#   apps/tui/src/timeline.ts (+N previous tool calls, changed files per message)
#   apps/mobile/src/features/threads/thread-work-log.tsx (tool icons, copy on long press, failure and usage limit rows)
#   apps/mobile/src/lib/threadActivity.ts (live row, rows that stand alone, delegations, workspace preparation)
#   apps/tui/src/worklog.ts (tool statuses)
#   packages/shared/src/toolOutput.ts (toolOutputIndicatesFailure: output that says a completed command failed)
#   packages/shared/src/halC2McpToolPresentation.ts (how a call to HAL-C2's own tool is named and recognised)
#   apps/tui/src/diffSplit.ts
#   apps/tui/src/components/MessagesTimeline.tsx (changed-files tree, open diff per turn and per file)
#   apps/server-ex/lib/hal_c2/orchestration/turn_writer.ex (command, file, web and tool items)
#   packages/contracts/src/rpc.ts (orchestration.getTurnDiff, orchestration.getFullThreadDiff)

Feature: Tool calls and file changes
  The agent's work shows as tool calls between its messages. Calls group into a short
  summary, open into their details, and file changes lead to a diff of the turn.

  Background:
    Given a connected environment with the project "shop"
    And the user is looking at a thread in "shop"

  # TUI: implemented in apps/tui/src/timeline.ts
  @shared @backlog-mobile
  Scenario: Consecutive tool calls in a running turn show only the latest
    Given the agent has run five tool calls in a row in the running turn
    Then the latest tool call is shown
    And the other four are behind "+4 previous tool calls"

  @shared @backlog-mobile
  Scenario: The previous tool calls can be shown and hidden again
    Given the agent has run five tool calls in a row in the running turn
    When the user shows the previous tool calls
    Then all five tool calls are shown
    When the user hides them again
    Then the other four are behind "+4 previous tool calls"

  @shared @backlog-mobile @backlog-tui
  Scenario: A group of tool calls reads as a summary of what the agent did
    Given the agent ran two commands and sent messages to three threads
    When the user reads the activity group
    Then it reads "Ran 2 commands and sent messages to 3 threads"

  @shared @backlog-mobile @backlog-tui
  Scenario: A summary names at most two kinds of work
    Given the agent ran commands, changed files, searched the web and read files
    When the user reads the activity group
    Then the summary names commands and file changes
    And it counts the rest instead of naming them

  @shared @backlog-mobile @backlog-tui
  Scenario: Failed calls are not counted as work done
    Given the agent sent three messages and one of them failed
    When the user reads the activity group
    Then the summary counts two messages sent

  @backlog @desktop @mobile @tui
  Scenario Outline: A summary says what kind of work the calls were
    Given the activity group holds <calls>
    When the user reads the activity group
    Then it reads "<summary>"

    Examples:
      | calls                                          | summary                             |
      | one file read                                  | Read 1 file                         |
      | edits to three different files                 | Changed 3 files                     |
      | two edits to the same file                     | Changed 1 file                      |
      | one command                                    | Ran 1 command                       |
      | two web searches                               | Searched the web 2 times            |
      | one search of the project's code               | Searched code 1 time                |
      | three browser calls                            | Used browser 3 times                |
      | two device controls                            | Used device controls 2 times        |
      | one tool with no more specific kind            | Used 1 tool                         |
      | two progress updates                           | Received 2 updates                  |
      | one thread the agent created                   | Created 1 thread                    |
      | two links of a pull request and one check      | Linked 2 pull requests and checked linked pull requests |
      | one pull request unlinked                      | Unlinked 1 pull request             |
      | two checks of the linked pull requests         | Checked linked pull requests 2 times |

  @backlog @desktop @mobile @tui
  Scenario: Reasoning is left out of a group's counts
    Given the activity group holds two thoughts and one command
    When the user reads the activity group
    Then it reads "Ran 1 command"

  @backlog @desktop @mobile @tui
  Scenario Outline: A group of only reasoning reads as a thought
    Given the activity group holds <thoughts>
    When the user reads the activity group
    Then it reads "<summary>"

    Examples:
      | thoughts       | summary       |
      | one thought    | Thought       |
      | three thoughts | Thought (×3)  |

  @backlog @desktop @mobile @tui
  Scenario: Calls through a named integration are summarised by its name
    Given the activity group holds two calls through the "Chrome" integration and one command
    When the user reads the activity group
    Then it reads "Used Chrome integration and ran 1 command"

  @backlog @desktop @mobile @tui
  Scenario Outline: Several integrations are named in a list
    Given the activity group holds calls through <sources>
    When the user reads the activity group
    Then it reads "<summary>"

    Examples:
      | sources                                         | summary                                  |
      | the "Chrome" and "Slack" integrations           | Used Chrome and Slack integrations       |
      | the "Chrome", "Slack" and "Linear" integrations | Used Chrome, Slack, and Linear integrations |
      | the built-in browser and computer controls      | Used Browser and Computer Use            |

  @backlog @desktop @mobile @tui
  Scenario: Calls a summary leaves out are counted
    Given the activity group holds commands, file changes and four web searches
    When the user reads the activity group
    Then the summary names commands and file changes
    And it ends with "Performed 4 other actions"

  # Legacy: packages/client-runtime/src/halC2ToolSummary.ts (summarizeHalC2ToolCalls)
  @backlog @desktop @mobile @tui
  Scenario Outline: A summary says what the agent did through HAL-C2's own tools
    Given the activity group holds <calls>
    When the user reads the activity group
    Then it reads "<summary>"

    Examples:
      | calls                                                   | summary                                  |
      | two tasks delegated to subagents                        | Delegated 2 tasks                        |
      | the same task cancelled twice                           | Requested cancellation of 1 task         |
      | one thread read and the same thread read again          | Read 1 thread                            |
      | one wait on a thread                                    | Waited on 1 thread                       |
      | one scheduled task created                              | Scheduled 1 task                         |
      | one scheduled task run on request                       | Requested 1 scheduled task run           |
      | a queued message edited and another reordered           | Edited 1 queued message and reordered 1 queued run |
      | a pending question answered                             | Answered 1 pending question request      |
      | one handoff to a worktree                               | Handed off to 1 worktree                 |
      | one project registered and one cloned                   | Registered 1 project and cloned 1 repository |
      | two attachments sent to one thread                      | Sent 2 attachments to 1 thread           |

  # Legacy: packages/client-runtime/src/halC2ToolSummary.ts (phrase: "Tried to …")
  @backlog @desktop @mobile @tui
  Scenario: A summary of calls that all failed says what the agent tried
    Given the activity group holds two attempts to send a message that both failed
    When the user reads the activity group
    Then it reads "Tried to send 2 messages"
    And the group is marked as having a failure

  # Legacy: packages/client-runtime/src/halC2ToolSummary.ts (readResult, halC2ToolResultIndicatesFailure)
  @backlog @desktop @mobile @tui
  Scenario: A HAL-C2 tool call that answered with an error counts as failed though the provider finished it
    Given the provider reported a HAL-C2 tool call as completed
    And the tool's answer says it is an error
    When the user reads the activity group
    Then the call is shown as failed

  # Legacy: packages/shared/src/halC2McpToolPresentation.ts (displayName per tool)
  @backlog @desktop @mobile @tui
  Scenario Outline: A call to one of HAL-C2's own tools is named for what it does
    Given the agent called HAL-C2's "<tool>" tool
    Then the call reads "<label>"

    Examples:
      | tool                    | label                                  |
      | delegate_task           | Delegate a child task                  |
      | hal_c2_thread_wait      | Wait for a HAL-C2 thread               |
      | hal_c2_thread_read      | Read a HAL-C2 thread                   |
      | hal_c2_thread_interrupt | Interrupt a HAL-C2 thread              |
      | task_cancel             | Cancel delegated task                  |
      | link_pull_request       | Link a pull request                    |
      | preview_open            | Open a page in the preview browser     |
      | device_screenshot       | Take a screenshot of the device        |

  # Legacy: packages/shared/src/halC2McpToolPresentation.ts (resolveHalC2McpToolName: provider prefixes, "completed" suffix)
  @backlog @desktop @mobile @tui
  Scenario Outline: HAL-C2's own tools are recognised however the provider writes their names
    Given the agent called HAL-C2's thread-reading tool and the provider named it "<name>"
    Then the call reads "Read a HAL-C2 thread"

    Examples:
      | name                              |
      | mcp__hal-c2__hal_c2_thread_read   |
      | mcp__hal_c2__hal_c2_thread_read   |
      | hal-c2.hal_c2_thread_read         |
      | hal-c2:hal_c2_thread_read         |
      | hal_c2_thread_read                |
      | hal-c2 · hal_c2_thread_read       |
      | hal_c2_thread_read completed      |

  # Legacy: packages/shared/src/halC2McpToolPresentation.ts (a tool of another server is not claimed)
  @backlog @desktop @mobile @tui
  Scenario: A tool of another server with the same name is not shown as HAL-C2's
    Given the agent called a tool named "mcp__other-server__hal_c2_thread_read"
    Then the call is shown as an ordinary tool call
    And it does not carry HAL-C2's name for the tool

  @backlog @desktop @mobile @tui
  Scenario: A group with a failed call is marked as having a failure
    Given the activity group holds a command that exited with a failure
    When the user reads the activity group
    Then the group is marked as having a failure

  # Legacy: packages/shared/src/toolOutput.ts (toolOutputIndicatesFailure),
  # packages/client-runtime/src/work-log/presentation.ts, apps/server/src/orchestration-v2/WireProjection.ts
  @backlog @desktop @mobile @tui
  Scenario Outline: A command the provider called finished is shown as failed when its output says it failed
    Given the provider reported a command as completed
    And the command's output says <output>
    When the user reads the activity group
    Then the command is shown as failed

    Examples:
      | output                                              |
      | "No such file or directory"                         |
      | "command not found"                                 |
      | "exited with exit code 1"                           |
      | "Cannot find path 'C:\x' because it does not exist" |

  @backlog @desktop @mobile @tui
  Scenario: A command whose output merely mentions a zero exit code stays a success
    Given the provider reported a command as completed
    And the command's output says "exited with exit code 0"
    When the user reads the activity group
    Then the command is shown as succeeded

  @shared @backlog-mobile @backlog-tui
  Scenario: A group opens into each call's details
    Given a collapsed group of tool calls
    When the user opens the group
    Then each call shows its command or input, its status and its exit code
    When the user closes the group
    Then the calls collapse back into the summary

  @desktop @backlog
  Scenario Outline: A command's details say how it ended
    Given the agent ran a command that exited with code <code>
    When the user opens the command's details
    Then the details show its input
    And they say "Process exited with code <code>" as <tone>

    Examples:
      | code | tone      |
      | 0    | a success |
      | 2    | a failure |

  @desktop @backlog
  Scenario: A command that has not exited gives no exit code
    Given the agent's command is still running
    When the user opens the command's details
    Then the details show its input
    And no exit code is shown

  @desktop @backlog
  Scenario: A file search's details list where each match is
    Given the agent searched the files and found "cart.total" in "src/cart.ts" at line 12 column 4
    When the user opens the search's details
    Then the match is listed as "src/cart.ts:12:4" with its preview line

  @desktop @backlog
  Scenario Outline: A web search's details link only to safe addresses
    Given the agent searched the web and a result has the address <address>
    When the user opens the search's details
    Then the result is <shown>

    Examples:
      | address                   | shown                                  |
      | "https://example.com/tax" | a link titled with the page's title    |
      | "javascript:alert(1)"     | its title as plain text with no link   |

  @desktop @backlog
  Scenario: A web result without a title shows its address or a generic name
    Given the agent searched the web and a result has no title
    When the user opens the search's details
    Then the result shows its address
    And a result with neither is called "Search result"

  @desktop @backlog
  Scenario: A to-do list's details show what is done
    Given the agent's plan has one finished step "Add the tax line" and one open step "Write tests"
    When the user opens the plan's details
    Then the finished step is marked done and the open step is marked not done

  @desktop @backlog
  Scenario: A file change's details name the file relative to the project
    Given the agent changed "/work/shop/src/cart.ts" adding 3 lines and removing 1
    When the user opens the file change's details
    Then the details show "src/cart.ts" with "+3" and "-1"
    And the details offer "Open diff" for that file

  @desktop @backlog
  Scenario: A file change that renamed a file shows where it came from
    Given the agent renamed "src/cart.ts" to "src/basket.ts"
    When the user opens the file change's details
    Then the details list the rename as "src/cart.ts → src/basket.ts"

  @shared @backlog-mobile @backlog-tui
  Scenario: A call is labelled by what it did
    Given the agent ran "git status" through a shell and changed a file in the workspace
    When the user opens the activity group
    Then the command is labelled "git status" and the file change "src/cart.ts"

  # TUI: implemented in apps/tui/src/worklog.ts
  @shared @backlog-mobile
  Scenario Outline: A tool call shows how it ended
    Given the agent's tool call <ended>
    Then the call is marked "<status>"

    Examples:
      | ended                    | status   |
      | is still running         | Running  |
      | failed                   | Failed   |
      | was declined by the user | Declined |
      | was interrupted          | Stopped  |

  @shared @backlog-mobile
  Scenario Outline: A tool call's icon says what kind of work it was
    Given the agent's most recent tool call <call>
    Then the call is shown with the "<icon>" icon

    Examples:
      | call               | icon           |
      | ran a command      | terminal       |
      | changed a file     | square-pen     |
      | searched the files | search         |
      | searched the web   | globe          |
      | called an MCP tool | wrench         |
      | asked for approval | message-circle |

  @backlog @mobile
  Scenario Outline: A tool call made through a website, an integration or an app shows that one's own icon
    Given the agent's tool call <call>
    Then the call is shown with <icon>

    Examples:
      | call                                       | icon                                                         |
      | used a website                             | that website's own icon                                      |
      | used an integration that has its own logo  | the logo made for the phone's light or dark appearance       |
      | drove an app on the environment's machine  | that app's icon, fetched from the environment                |
      | used a website whose icon cannot be loaded | the generic icon for that kind of work, without a gap        |

  @backlog @mobile
  Scenario: Long pressing a tool call or a failure copies what it says
    Given the activity log shows a tool call and a failed turn
    When the user long presses the tool call
    Then its text is copied and the row says "Copied" for a moment
    When the user long presses the failure
    Then the failure message is copied and the row says "Copied" for a moment

  @backlog @mobile
  Scenario Outline: A turn that failed says why in the activity log
    Given the turn ended <how>
    Then the activity log shows <row>

    Examples:
      | how                                           | row                                                                    |
      | with an error                                 | the error's title, its message and when it happened                    |
      | at a provider usage limit that resets at 17:00 | "Usage limit reached. Retry after" that time, without the message      |
      | at a provider usage limit with no reset time  | "Usage limit reached." alone                                           |

  @mc @shared @backlog-mobile
  Scenario Outline: An ACP agent's read, search and fetch tools keep their meaning
    Given an ACP agent's tool call is of kind "<provider kind>"
    When the MC projects the call
    Then the timeline shows it as <timeline kind>

    Examples:
      | provider kind | timeline kind |
      | read          | a file read   |
      | search        | a file search |
      | fetch         | a web search  |

  # OpenCode announces a tool call before it has its input and names it once it runs.
  @mc
  Scenario Outline: An ACP read or search named only once it runs still says what it looked for
    Given an ACP agent announces a call of kind "<provider kind>" and names its input <when>
    When the MC projects the call
    Then the timeline shows it as <timeline kind>

    Examples:
      | provider kind | when             | timeline kind |
      | read          | while it runs    | a file read   |
      | search        | while it runs    | a file search |
      | read          | when it finishes | a file read   |
      | search        | when it finishes | a file search |

  # TUI: implemented in apps/tui/src/components/MessagesTimeline.tsx
  @shared @backlog-mobile
  Scenario: Files changed by a turn are listed under its reply
    Given the agent changed "src/cart.ts" and "src/checkout.ts" in one turn
    When the turn completes
    Then the reply lists both files with their added and removed lines

  # TUI: implemented in apps/tui/src/components/MessagesTimeline.tsx
  @shared @backlog-mobile
  Scenario: The user opens the diff of one turn
    Given a turn changed two files
    When the user opens that turn's changes
    Then the diff shows only what that turn changed, split per file

  # TUI: implemented in apps/tui/src/components/MessagesTimeline.tsx
  @shared @backlog-mobile
  Scenario: The user opens the diff of a single changed file
    Given a turn changed "src/cart.ts" and "src/checkout.ts"
    When the user opens "src/cart.ts" from the list of changed files
    Then the diff shows only "src/cart.ts"

  @desktop
  Scenario: A turn's changed files are folded under their folders
    Given a turn changed "src/cart.ts" and "src/checkout.ts"
    Then the reply lists the folder "src" with its files hidden
    When the user expands all folders of the changed files
    Then "cart.ts" and "checkout.ts" are listed under their folder
    When the user collapses all folders of the changed files
    Then the reply lists the folder "src" with its files hidden

  @desktop @backlog
  Scenario Outline: A turn's changed files say how many there are and how much changed
    Given a turn changed <files>
    Then the changed files' heading reads "<heading>"

    Examples:
      | files                                                              | heading                       |
      | "src/cart.ts" with 3 lines added and 1 removed                     | 1 changed file +3 -1          |
      | "src/cart.ts" and "src/checkout.ts" with 5 lines added in all      | 2 changed files +5            |
      | "src/cart.ts" and "src/checkout.ts" with no line counts            | 2 changed files               |

  @desktop @backlog
  Scenario: A folder of changed files carries the totals of what is inside it
    Given a turn changed "src/cart.ts" with 3 lines added and "src/checkout.ts" with 2 lines added
    Then the folder "src" is listed with "+5"
    And each file is listed with its own line counts

  @desktop @backlog
  Scenario: One folder can be opened without opening the rest
    Given a turn changed "src/cart.ts" and "test/cart.test.ts"
    When the user opens the folder "src" of the changed files
    Then "cart.ts" is listed under "src"
    And the folder "test" is still shown with its files hidden

  @desktop @backlog
  Scenario: A turn's changed files stay open or closed as the user left them
    Given a turn's changed files have all their folders expanded
    When the user opens another thread and comes back
    Then the turn's changed files still have all their folders expanded

  @desktop @backlog
  Scenario: A turn that changed only files at the project's top has no folders to open
    Given a turn changed "package.json" and "README.md"
    Then the changed files are listed without a control to expand or collapse folders

  @desktop @backlog
  Scenario: A changed file offers the file's own actions on right click
    Given a turn changed "src/cart.ts"
    When the user right-clicks "src/cart.ts" in the changed files
    Then the menu offers what the environment can do with that file
    And a file that cannot be located on the environment's machine offers nothing

  @mc
  Scenario: The MC serves a turn's diff and the whole thread's diff
    Given a thread with three finished turns
    When a client asks for the diff of the second turn
    Then it receives the changes made during the second turn
    When a client asks for the whole thread's diff
    Then it receives the changes from before the first turn to after the last

  # The phone keeps exactly one live row at the end of a running turn.
  @backlog @mobile
  Scenario Outline: A running turn always has one live row saying what the agent is doing
    Given the agent is working
    And <state>
    Then the last row of the activity log reads "<row>"

    Examples:
      | state                                           | row                              |
      | it has not made a tool call yet                 | Thinking                         |
      | its latest tool call failed                     | Thinking                         |
      | its latest tool call was stopped                | Thinking                         |
      | its latest tool call is still running           | what that call is doing          |
      | its latest tool call succeeded and none followed | what that call did               |

  # Legacy: packages/client-runtime/src/work-log/commandLabel.ts (commandProgramName)
  @backlog @desktop @mobile
  Scenario Outline: A command is named by the program it runs, through the shells and set-up around it
    Given the agent's latest command is <command>
    When it finishes
    Then the live row reads "Ran <program>"

    Examples:
      | command                                                | program |
      | "/bin/zsh -lc 'git diff --check'"                      | git     |
      | "bash -lc \"zsh -c 'git status'\""                     | git     |
      | "cd apps/web && vp test run"                           | vp      |
      | "export CI=1 && vp test run"                           | vp      |
      | "CI=1 env -u DEBUG sudo -u root vp test run"           | vp      |
      | "timeout 10 pnpm test"                                 | pnpm    |
      | "vp test && git status"                                | vp      |
      | "pwsh -NoProfile -Command \"Set-Location C:\\work; pnpm test\"" | pnpm |

  # Legacy: packages/client-runtime/src/work-log/commandLabel.ts (commandProgramName falls back)
  @backlog @desktop @mobile
  Scenario Outline: A command with no program to name is called "command"
    Given the agent's latest command is <command>
    When it finishes
    Then the live row reads "Ran command"

    Examples:
      | command                                         |
      | "cd packages/client-runtime"                    |
      | "if test -f package.json; then vp test; fi"     |
      | "export NODE_ENV=test"                          |
      | "zsh -lc 'git status"                           |

  # Legacy: apps/web/src/components/chat/MessagesTimeline.logic.ts (liveWorkEntryLabel),
  # apps/mobile/src/lib/threadActivity.ts
  @backlog @desktop @mobile
  Scenario Outline: The live row's verb follows how the command ended
    Given the agent's latest command is "npm test"
    When the command <ending>
    Then the live row reads "<label>"

    Examples:
      | ending                      | label          |
      | is running                  | Running npm    |
      | succeeds                    | Ran npm        |
      | fails                       | Failed npm     |
      | is declined by the user     | Declined npm   |
      | is stopped                  | Stopped npm    |

  # Legacy: packages/client-runtime/src/work-log/commandLabel.ts (commandDisplayText)
  @backlog @desktop @mobile
  Scenario Outline: A command is shown without the shell the provider wrapped it in
    Given the agent ran <command>
    When the user reads the activity group
    Then the command reads <shown>

    Examples:
      | command                              | shown                            |
      | "/bin/zsh -lc 'git diff --stat'"     | "git diff --stat"                |
      | "bash -c \"printf hi; git status\""  | "printf hi; git status"          |
      | "git status"                         | "git status"                     |
      | "zsh script.sh"                      | "zsh script.sh"                  |
      | "zsh -lc 'echo $1' name value"       | "zsh -lc 'echo $1' name value"   |
      | "zsh -lc 'pwd'; git status"          | "zsh -lc 'pwd'; git status"      |

  # Legacy: packages/client-runtime/src/work-log/commandLabel.ts (commandDisplayText keeps the original for details)
  @backlog @desktop @mobile
  Scenario: The command as the provider ran it stays available in the call's details
    Given the agent ran "/bin/zsh -lc 'git diff --stat'"
    When the user opens the call's details
    Then the details show "/bin/zsh -lc 'git diff --stat'"

  # Legacy: packages/client-runtime/src/work-log/presentation.ts (commandDetailRepeatsCommand, extractCommandOutputText)
  @backlog @desktop @mobile
  Scenario: A command's own text is not shown again as its output
    Given the provider reported the command "npm test" with no output but its own text as the detail
    When the user opens the command's details
    Then the details show the command once
    And no output is shown

  # Legacy: packages/client-runtime/src/work-log/presentation.ts (workEntryViewedImagePath, resolveViewedImageAsset)
  @backlog @desktop @mobile
  Scenario Outline: An image the agent looked at is shown in the call's details only when it is in the workspace
    Given the agent viewed <image>
    When the user opens the call's details
    Then <result>

    Examples:
      | image                                   | result                                        |
      | "assets/logo.png" in the thread's workspace | the image is shown                        |
      | "/tmp/outside.png" outside the workspace    | the path is shown and no image is loaded  |
      | "notes.txt" in the thread's workspace       | the path is shown and no image is loaded  |

  # Legacy: packages/client-runtime/src/work-log/userInput.ts (getQuestionAnswerPreview)
  @backlog @desktop @mobile
  Scenario Outline: A question the user answered is previewed in the tool call by what they said
    Given the agent asked a question that the user answered with <answer>
    Then the call's row previews <preview>

    Examples:
      | answer                                       | preview                      |
      | "SQLite" and "WAL on"                        | "SQLite · WAL on"            |
      | only the files "schema.sql" and "seed.sql"   | "schema.sql, seed.sql"       |
      | nothing but the question "Which database?"   | "Which database?"            |

  # Legacy: packages/client-runtime/src/work-log/scrollAnchor.ts, apps/web/src/components/chat/MessagesTimeline.logic.ts (resolveWorkGroupScrollIndex, shouldFollowWorkGroupAppend)
  @backlog @desktop @mobile
  Scenario: A long group opens again where the user had left it
    Given a long group of tool calls that the user scrolled partway down
    When the user closes the group and opens it again
    Then the group shows the call the user was reading at the same place

  # Legacy: apps/web/src/components/chat/MessagesTimeline.logic.ts (shouldFollowWorkGroupAppend)
  @backlog @desktop
  Scenario: An open group follows new calls only while the user is at its end
    Given the user has a long group of tool calls open and is looking at its last call
    When the agent adds another call to the group
    Then the group scrolls to show the new call
    When the user has scrolled up in the group and the agent adds another call
    Then the group stays where it is
    And a call changing its status or output never moves the group

  @backlog @mobile
  Scenario Outline: Some rows stand alone between groups of tool calls
    Given the agent made tool calls, then <event>, then made more tool calls
    Then the tool calls before and after are two groups
    And <event> is shown on its own between them

    Examples:
      | event                       |
      | a context compaction        |
      | a context handoff           |
      | a notification              |
      | a provider error that failed the turn |

  @backlog @mobile
  Scenario: A call that never reported an end in a settled turn is not listed
    Given a tool call in a turn that has settled never reported that it ended
    Then the call is not listed among the turn's tool calls

  @backlog @mobile
  Scenario: A call that was stopped or declined stays listed
    Given a settled turn has a tool call that was interrupted and one that the user declined
    Then both are listed with "Stopped" and "Declined"

  @backlog @mobile
  Scenario: A delegation is not repeated as a tool call once its subagent has a card
    Given the agent delegated "write the tax tests" and the subagent's card is in the timeline
    Then the delegating call is not also listed among the tool calls

  @backlog @mobile
  Scenario Outline: A delegation without a card stays visible as a tool call
    Given the agent delegated "write the tax tests" and <case>
    Then the delegating call is listed among the tool calls

    Examples:
      | case                                             |
      | the delegation failed                            |
      | the delegation is still being started            |
      | no subagent card matches the delegation          |

  @backlog @mobile
  Scenario: The step that prepares the workspace is not listed as a tool call
    Given the MC prepared the thread's workspace before the first turn
    Then the activity log does not show a command for preparing the workspace

  @backlog @mobile
  Scenario: A usage limit is not marked as a failed call
    Given the turn stopped at the provider's usage limit
    Then the row "Usage limit reached" is shown without a failure mark
    And a provider error that is not a usage limit is shown with a failure mark

  @backlog @mobile
  Scenario: A turn's failure cannot be opened for more detail
    Given the turn failed with a provider error
    Then the failure row stays open with its message
    And the row has nothing more to expand
