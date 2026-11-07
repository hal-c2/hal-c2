# Sources:
#   https://github.com/pingdotgg/t3code/pull/17561
#   https://github.com/pingdotgg/t3code/pull/17211
#   https://github.com/pingdotgg/t3code/pull/17948
#   https://github.com/pingdotgg/t3code/pull/16284
#   https://github.com/pingdotgg/t3code/pull/13140
#   https://github.com/pingdotgg/t3code/pull/15094
#   https://github.com/pingdotgg/t3code/pull/18761
#   https://github.com/pingdotgg/t3code/pull/18865
#   https://github.com/pingdotgg/t3code/pull/18897
#   https://github.com/pingdotgg/t3code/pull/18898
#   https://github.com/pingdotgg/t3code/pull/19654
#   https://github.com/pingdotgg/t3code/pull/20036
#   https://github.com/pingdotgg/t3code/pull/15475
#   https://github.com/pingdotgg/t3code/pull/15037
#   https://github.com/pingdotgg/t3code/pull/16199
#   https://github.com/pingdotgg/t3code/pull/15968
#   https://github.com/pingdotgg/t3code/pull/16283
#   https://github.com/pingdotgg/t3code/pull/13386 (a tool's progress does not split the answer)
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
#   https://github.com/MoonshotAI/kimi-code/blob/%40moonshot-ai/kimi-code%402.3.1/packages/acp-server/src/events-map.ts (Kimi's tool calls)
#   https://github.com/MoonshotAI/kimi-code/blob/%40moonshot-ai/kimi-code%402.3.1/packages/agent-core-v2/docs/wire-manifest.d.ts (Kimi's session records)
#   apps/server-ex/lib/hal_c2/acp/kimi.ex (Kimi's subagents, read from those records)
#   packages/contracts/src/rpc.ts (orchestration.getTurnDiff, orchestration.getFullThreadDiff)
#   https://github.com/pingdotgg/t3code/pull/15056
#   https://github.com/pingdotgg/t3code/pull/15384
#   https://github.com/pingdotgg/t3code/pull/15505
#   https://github.com/pingdotgg/t3code/pull/15506

Feature: Tool calls and file changes
  The agent's work shows as tool calls between its messages. Calls group into a short
  summary, open into their details, and file changes lead to a diff of the turn.

  Background:
    Given a connected environment with the project "shop"
    And the user is looking at a thread in "shop"

  # A new tool call still separates two messages. Progress on a tool already shown does not,
  # so a table or link the agent is writing is not cut in two.
  @mc @shared
  Scenario: A running command's progress does not split the agent's message in two
    Given the agent is writing a message
    And a command it started in the background reports progress in the middle of the message
    Then the message stays one message
    And the text the agent writes after the progress is part of it

  # TUI: implemented in apps/tui/src/timeline.ts
  @shared
  Scenario: Consecutive tool calls in a running turn show only the latest
    Given the agent has run five tool calls in a row in the running turn
    Then the latest tool call is shown
    And the other four are behind "+4 previous tool calls"

  @shared
  Scenario: The previous tool calls can be shown and hidden again
    Given the agent has run five tool calls in a row in the running turn
    When the user shows the previous tool calls
    Then all five tool calls are shown
    When the user hides them again
    Then the other four are behind "+4 previous tool calls"

  # The running group is one line: what the agent is doing now, with the count of the calls
  # before it at its end. It changes as calls land and never animates.
  # Proved by tst_Timeline.qml (test_runningToolCallsReadAsOneLiveRow), not yet by a step (hal-c2/hal-c2#213).
  # TUI: the latest call and "+N previous tool calls" are still two lines (apps/tui/src/host/timelineState.ts).
  @shared @backlog-desktop @backlog-mobile @backlog-tui @priority-high
  Scenario: A running turn's tool calls read as one live row
    Given the agent has run five tool calls in a row in the running turn
    Then one row shows the latest tool call with "+4 previous tool calls" beside it
    When the agent starts a sixth tool call
    Then the row shows the sixth tool call with "+5 previous tool calls" beside it
    When the user opens the row
    Then all six tool calls are shown

  # Upstream #16284: the live row also says what the agent is thinking about.
  @backlog @shared
  Scenario: The live row shows the first sentence of the agent's latest thought
    Given the agent is running a tool call in the running turn
    When the agent thinks "Checking the tax tables first. Then the cart."
    Then the live row shows "Checking the tax tables first." above the running tool call
    When the turn ends
    Then the thought folds away with the row

  @shared
  Scenario: A group of tool calls reads as a summary of what the agent did
    Given the agent ran two commands and sent messages to three threads
    When the user reads the activity group
    Then it reads "Ran 2 commands and sent messages to 3 threads"

  @shared
  Scenario: A summary names at most two kinds of work
    Given the agent ran commands, changed files, searched the web and read files
    When the user reads the activity group
    Then the summary names commands and file changes
    And it counts the rest instead of naming them

  @shared
  Scenario: Failed calls are not counted as work done
    Given the agent sent three messages and one of them failed
    When the user reads the activity group
    Then the summary counts two messages sent

  # A lone call reads as itself; the thought, which is not counted, makes each group a summary.
  @desktop @mobile @tui
  Scenario Outline: A summary says what kind of work the calls were
    Given the activity group holds a thought and <calls>
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

  @desktop @mobile @tui
  Scenario: Reasoning is left out of a group's counts
    Given the activity group holds two thoughts and one command
    When the user reads the activity group
    Then it reads "Ran 1 command"

  @desktop @mobile @tui
  Scenario Outline: A group of only reasoning reads as a thought
    Given the activity group holds <thoughts>
    When the user reads the activity group
    Then it reads "<summary>"

    Examples:
      | thoughts       | summary       |
      | one thought    | Thought       |
      | three thoughts | Thought (×3)  |

  @desktop @mobile @tui
  Scenario: Calls through a named integration are summarised by its name
    Given the activity group holds two calls through the "Chrome" integration and one command
    When the user reads the activity group
    Then it reads "Used Chrome integration and ran 1 command"

  @desktop @mobile @tui
  Scenario Outline: Several integrations are named in a list
    Given the activity group holds calls through <sources>
    When the user reads the activity group
    Then it reads "<summary>"

    Examples:
      | sources                                         | summary                                  |
      | the "Chrome" and "Slack" integrations           | Used Chrome and Slack integrations       |
      | the "Chrome", "Slack" and "Linear" integrations | Used Chrome, Slack, and Linear integrations |
      | the built-in browser and computer controls      | Used Browser and Computer Use            |

  @desktop @mobile @tui
  Scenario: Calls a summary leaves out are counted
    Given the activity group holds commands, file changes and four web searches
    When the user reads the activity group
    Then the summary names commands and file changes
    And it ends with "Performed 4 other actions"

  # Legacy: packages/client-runtime/src/halC2ToolSummary.ts (summarizeHalC2ToolCalls)
  @desktop @mobile @tui
  Scenario Outline: A summary says what the agent did through HAL-C2's own tools
    Given the activity group holds a thought and <calls>
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
  @desktop @mobile @tui
  Scenario: A summary of calls that all failed says what the agent tried
    Given the activity group holds two attempts to send a message that both failed
    When the user reads the activity group
    Then it reads "Tried to send 2 messages"
    And the group is marked as having a failure

  # Legacy: packages/client-runtime/src/halC2ToolSummary.ts (readResult, halC2ToolResultIndicatesFailure)
  @desktop @mobile @tui
  Scenario: A HAL-C2 tool call that answered with an error counts as failed though the provider finished it
    Given the provider reported a HAL-C2 tool call as completed
    And the tool's answer says it is an error
    When the user reads the activity group
    Then the call is shown as failed

  # Legacy: packages/shared/src/halC2McpToolPresentation.ts (displayName per tool)
  @desktop @mobile @tui
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
  @desktop @mobile @tui
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

  # Upstream #13140: a thread read names the thread by its title now and links to it.
  @backlog @shared
  Scenario Outline: Reading another thread names that thread
    Given the agent <state> HAL-C2's thread-reading tool on thread "t2"
    And "t2" is titled "Fix checkout"
    Then the call reads "<label>"
    And the call links to "t2"

    Examples:
      | state             | label                            |
      | is calling        | Reading thread “Fix checkout”    |
      | called            | Read thread “Fix checkout”       |
      | failed to call    | Failed to read thread “Fix checkout” |

  @backlog @shared
  Scenario Outline: A thread read on a thread the client cannot show stays generic
    Given the agent called HAL-C2's thread-reading tool on thread "t2"
    And "t2" is <state>
    Then the call reads "Read a HAL-C2 thread"
    And the call links nowhere

    Examples:
      | state     |
      | unknown   |
      | archived  |
      | deleted   |

  # Legacy: packages/shared/src/halC2McpToolPresentation.ts (a tool of another server is not claimed)
  @desktop @mobile @tui
  Scenario: A tool of another server with the same name is not shown as HAL-C2's
    Given the agent called a tool named "mcp__other-server__hal_c2_thread_read"
    Then the call is shown as an ordinary tool call
    And it does not carry HAL-C2's name for the tool

  @desktop @mobile @tui
  Scenario: A group with a failed call is marked as having a failure
    Given the activity group holds a command that exited with a failure
    When the user reads the activity group
    Then the group is marked as having a failure

  # Legacy: packages/shared/src/toolOutput.ts (toolOutputIndicatesFailure),
  # packages/client-runtime/src/work-log/presentation.ts, apps/server/src/orchestration-v2/WireProjection.ts
  @desktop @mobile @tui
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

  @desktop @mobile @tui
  Scenario: A command whose output merely mentions a zero exit code stays a success
    Given the provider reported a command as completed
    And the command's output says "exited with exit code 0"
    When the user reads the activity group
    Then the command is shown as succeeded

  @shared
  Scenario: A group opens into each call's details
    Given a collapsed group of tool calls
    When the user opens the group
    Then each call shows its command or input, its status and its exit code
    When the user closes the group
    Then the calls collapse back into the summary

  @desktop
  Scenario Outline: A command's details say how it ended
    Given the agent ran a command that exited with code <code>
    When the user opens the command's details
    Then the details show its input
    And they say "Process exited with code <code>" as <tone>

    Examples:
      | code | tone      |
      | 0    | a success |
      | 2    | a failure |

  @desktop
  Scenario: A command that has not exited gives no exit code
    Given the agent's command is still running
    When the user opens the command's details
    Then the details show its input
    And no exit code is shown

  @mc @shared @backlog
  Scenario: An opened command shows its output while it runs
    Given the agent's command is still running and printing
    When the user opens the command's details
    Then the output printed so far is shown
    And new output is added as it is printed, at most every 100 ms
    And once the command ends the output is replaced by the output the thread kept

  @mc @shared @backlog
  Scenario: A finished command's output is fetched when it is opened
    Given the agent ran a command that finished
    When the user opens the command's details
    Then the command's final output is shown

  @mc @backlog
  Scenario: Command output does not ride the thread
    Given the agent's command prints 17 MB of output
    And no client has opened the command's details
    Then no client receives any of that output
    And the thread's history and stream do not grow by it

  @mc @backlog
  Scenario: A running command keeps only the last 64K characters of output
    Given the agent's command has printed more than 64K characters
    When the user opens the command's details
    Then the last 64K characters are shown

  @mc @backlog
  Scenario: A client that falls behind is sent the whole tail again
    Given a client watching a running command falls more than 16 KB behind
    Then it is sent the whole kept output instead of the missed parts, at most every 500 ms
    And what it shows afterwards matches what a client that kept up shows

  @mc @shared @backlog
  Scenario: Progress bars in command output show only their latest frame
    Given the agent's command draws a progress bar that redraws its line
    When the user opens the command's details
    Then the progress bar is shown once, at its latest state
    And the output's colours are shown
    And other terminal control codes are not shown

  @shared @backlog
  Scenario: Coloured command output stays readable
    Given the agent's command prints dark text on a dark background
    When the user opens the command's details
    Then that text is drawn in a colour readable on its background

  @desktop
  Scenario: A file search's details list where each match is
    Given the agent searched the files and found "cart.total" in "src/cart.ts" at line 12 column 4
    When the user opens the search's details
    Then the match is listed as "src/cart.ts:12:4" with its preview line

  @desktop
  Scenario Outline: A web search's details link only to safe addresses
    Given the agent searched the web and a result has the address <address>
    When the user opens the search's details
    Then the result is <shown>

    Examples:
      | address                   | shown                                  |
      | "https://example.com/tax" | a link titled with the page's title    |
      | "javascript:alert(1)"     | its title as plain text with no link   |

  @desktop
  Scenario: A web result without a title shows its address or a generic name
    Given the agent searched the web and a result has no title
    When the user opens the search's details
    Then the result shows its address
    And a result with neither is called "Search result"

  @desktop
  Scenario: A to-do list's details show what is done
    Given the agent's plan has one finished step "Add the tax line" and one open step "Write tests"
    When the user opens the plan's details
    Then the finished step is marked done and the open step is marked not done

  @desktop
  Scenario: A file change's details name the file relative to the project
    Given the agent changed "/work/shop/src/cart.ts" adding 3 lines and removing 1
    When the user opens the file change's details
    Then the details show "src/cart.ts" with "+3" and "-1"
    And the details offer "Open diff" for that file

  @desktop
  Scenario: A file change that renamed a file shows where it came from
    Given the agent renamed "src/cart.ts" to "src/basket.ts"
    When the user opens the file change's details
    Then the details list the rename as "src/cart.ts → src/basket.ts"

  @shared
  Scenario: A call is labelled by what it did
    Given the agent ran "git status" through a shell and changed a file in the workspace
    When the user opens the activity group
    Then the command is labelled "git status" and the file change "src/cart.ts"

  # TUI: implemented in apps/tui/src/worklog.ts
  @shared
  Scenario Outline: A tool call shows how it ended
    Given the agent's tool call <ended>
    Then the call is marked "<status>"

    Examples:
      | ended                    | status   |
      | is still running         | Running  |
      | failed                   | Failed   |
      | was declined by the user | Declined |
      | was interrupted          | Stopped  |

  @shared
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

  @mobile
  Scenario Outline: A tool call made through a website, an integration or an app shows that one's own icon
    Given the agent's tool call <call>
    Then the call is shown with <icon>

    Examples:
      | call                                       | icon                                                         |
      | used a website                             | that website's own icon                                      |
      | used an integration that has its own logo  | the logo made for the phone's light or dark appearance       |
      | drove an app on the environment's machine  | that app's icon, fetched from the environment                |
      | used a website whose icon cannot be loaded | the generic icon for that kind of work, without a gap        |

  @mobile
  Scenario: Long pressing a tool call or a failure copies what it says
    Given the activity log shows a tool call and a failed turn
    When the user long presses the tool call
    Then its text is copied and the row says "Copied" for a moment
    When the user long presses the failure
    Then the failure message is copied and the row says "Copied" for a moment

  @mobile
  Scenario Outline: A turn that failed says why in the activity log
    Given the turn ended <how>
    Then the activity log shows <row>

    Examples:
      | how                                           | row                                                                    |
      | with an error                                 | the error's title, its message and when it happened                    |
      | at a provider usage limit that resets at 17:00 | "Usage limit reached. Retry after" that time, without the message      |
      | at a provider usage limit with no reset time  | "Usage limit reached." alone                                           |

  @mc @shared
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

  # Kimi Code's text for a running call is its arguments streaming in, and it names a
  # file only by an absolute path.
  @mc
  Scenario Outline: Kimi's tool calls say what they ran
    Given Kimi streams a "<tool>" call's arguments while it runs
    When the MC projects the call
    Then the timeline shows it as <timeline kind>

    Examples:
      | tool  | timeline kind |
      | Bash  | a command     |
      | Read  | a file read   |
      | Grep  | a file search |
      | Write | a file change |

  # Kimi's Agent tool runs a subagent whose work ACP never carries: Kimi writes it only
  # to the session's own records on the MC's machine, which the MC reads while it runs.
  @mc
  Scenario: A Kimi subagent's work shows in its own thread
    Given Kimi hands a task to one of its subagents
    When the MC projects the subagent
    Then the subagent's thread opens with its task
    And the subagent's thinking, commands and replies appear in its thread
    And the subagent's result is the summary Kimi recorded

  # A turn can end, with Kimi still running, before its subagent's end reaches the
  # record or its call.
  @mc
  Scenario: A Kimi subagent ends with its turn
    Given Kimi's turn fails while one of its subagents works
    When the turn fails
    Then the subagent ends with it

  # A subagent Kimi runs in the background outlives its call and its turn.
  @mc
  Scenario: A Kimi background subagent runs on after its turn
    Given Kimi hands a task to a subagent in the background
    When the MC projects the subagent
    Then the subagent is still running
    When Kimi records that the subagent finished
    Then the subagent's result is the summary Kimi recorded

  # TUI: implemented in apps/tui/src/components/MessagesTimeline.tsx
  @shared
  Scenario: Files changed by a turn are listed under its reply
    Given the agent changed "src/cart.ts" and "src/checkout.ts" in one turn
    When the turn completes
    Then the reply lists both files with their added and removed lines

  # TUI: implemented in apps/tui/src/components/MessagesTimeline.tsx
  @shared
  Scenario: The user opens the diff of one turn
    Given a turn changed two files
    When the user opens that turn's changes
    Then the diff shows only what that turn changed, split per file

  # TUI: implemented in apps/tui/src/components/MessagesTimeline.tsx
  @shared
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

  @desktop
  Scenario Outline: A turn's changed files say how many there are and how much changed
    Given a turn changed <files>
    Then the changed files' heading reads "<heading>"

    Examples:
      | files                                                              | heading                       |
      | "src/cart.ts" with 3 lines added and 1 removed                     | 1 changed file +3 -1          |
      | "src/cart.ts" and "src/checkout.ts" with 5 lines added in all      | 2 changed files +5            |
      | "src/cart.ts" and "src/checkout.ts" with no line counts            | 2 changed files               |

  @backlog @shared @mobile
  Scenario: Large line counts are grouped the way the user's locale writes numbers
    Given the user's locale is English
    And a turn changed files with 85000 lines added and 30000 removed
    Then every place that shows those counts reads "+85,000 -30,000"

  @desktop
  Scenario: A folder of changed files carries the totals of what is inside it
    Given a turn changed "src/cart.ts" with 3 lines added and "src/checkout.ts" with 2 lines added
    Then the folder "src" is listed with "+5"
    And each file is listed with its own line counts

  @desktop
  Scenario: One folder can be opened without opening the rest
    Given a turn changed "src/cart.ts" and "test/cart.test.ts"
    When the user opens the folder "src" of the changed files
    Then "cart.ts" is listed under "src"
    And the folder "test" is still shown with its files hidden

  @desktop
  Scenario: A turn's changed files stay open or closed as the user left them
    Given a turn's changed files have all their folders expanded
    When the user opens another thread and comes back
    Then the turn's changed files still have all their folders expanded

  @desktop
  Scenario: A turn that changed only files at the project's top has no folders to open
    Given a turn changed "package.json" and "README.md"
    Then the changed files are listed without a control to expand or collapse folders

  @desktop
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
  @mobile
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
  @desktop @mobile
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
  @desktop @mobile
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
  @desktop @mobile
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
  @desktop @mobile
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
  @desktop @mobile
  Scenario: The command as the provider ran it stays available in the call's details
    Given the agent ran "/bin/zsh -lc 'git diff --stat'"
    When the user opens the call's details
    Then the details show "/bin/zsh -lc 'git diff --stat'"

  # Legacy: packages/client-runtime/src/work-log/presentation.ts (commandDetailRepeatsCommand, extractCommandOutputText)
  @desktop @mobile
  Scenario: A command's own text is not shown again as its output
    Given the provider reported the command "npm test" with no output but its own text as the detail
    When the user opens the command's details
    Then the details show the command once
    And no output is shown

  # Legacy: packages/client-runtime/src/work-log/presentation.ts (workEntryViewedImagePath, resolveViewedImageAsset)
  @desktop @mobile
  Scenario Outline: An image the agent looked at is shown in the call's details only when it is in the workspace
    Given the agent viewed <image>
    When the user opens the call's details
    Then <result>

    Examples:
      | image                                   | result                                        |
      | "assets/logo.png" in the thread's workspace | the image is shown                        |
      | "/tmp/outside.png" outside the workspace    | the path is shown and no image is loaded  |
      | "notes.txt" in the thread's workspace       | the path is shown and no image is loaded  |

  @backlog @shared
  Scenario: A file read that returned only an image shows the image without a placeholder
    Given Claude read "assets/logo.png" in the thread's workspace and got back only the image
    When the user opens the call's details
    Then the image is shown
    And the details show neither "[image]" nor "No output"

  @backlog @shared
  Scenario: A computer-use or script call reads as the action the agent named
    Given the agent ran a computer-use or JavaScript call titled "Open the billing page"
    When the user looks at the timeline
    Then the call reads "Open the billing page"

  # Legacy: packages/client-runtime/src/work-log/userInput.ts (getQuestionAnswerPreview)
  @desktop @mobile
  Scenario Outline: A question the user answered is previewed in the tool call by what they said
    Given the agent asked a question that the user answered with <answer>
    Then the call's row previews <preview>

    Examples:
      | answer                                       | preview                      |
      | "SQLite" and "WAL on"                        | "SQLite · WAL on"            |
      | only the files "schema.sql" and "seed.sql"   | "schema.sql, seed.sql"       |
      | nothing but the question "Which database?"   | "Which database?"            |

  # Legacy: packages/client-runtime/src/work-log/scrollAnchor.ts, apps/web/src/components/chat/MessagesTimeline.logic.ts (resolveWorkGroupScrollIndex, shouldFollowWorkGroupAppend)
  @desktop @mobile
  Scenario: A long group opens again where the user had left it
    Given a long group of tool calls that the user scrolled partway down
    When the user closes the group and opens it again
    Then the group shows the call the user was reading at the same place

  # Legacy: apps/web/src/components/chat/MessagesTimeline.logic.ts (shouldFollowWorkGroupAppend)
  @desktop
  Scenario: An open group follows new calls only while the user is at its end
    Given the user has a long group of tool calls open and is looking at its last call
    When the agent adds another call to the group
    Then the group scrolls to show the new call
    When the user has scrolled up in the group and the agent adds another call
    Then the group stays where it is
    And a call changing its status or output never moves the group

  @mobile
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

  @mobile
  Scenario: A call that never reported an end in a settled turn is not listed
    Given a tool call in a turn that has settled never reported that it ended
    Then the call is not listed among the turn's tool calls

  @mobile
  Scenario: A call that was stopped or declined stays listed
    Given a settled turn has a tool call that was interrupted and one that the user declined
    Then both are listed with "Stopped" and "Declined"

  @mobile
  Scenario: A delegation is not repeated as a tool call once its subagent has a card
    Given the agent delegated "write the tax tests" and the subagent's card is in the timeline
    Then the delegating call is not also listed among the tool calls

  @mobile
  Scenario Outline: A delegation without a card stays visible as a tool call
    Given the agent delegated "write the tax tests" and <case>
    Then the delegating call is listed among the tool calls

    Examples:
      | case                                             |
      | the delegation failed                            |
      | the delegation is still being started            |
      | no subagent card matches the delegation          |

  @mobile
  Scenario: The step that prepares the workspace is not listed as a tool call
    Given the MC prepared the thread's workspace before the first turn
    Then the activity log does not show a command for preparing the workspace

  @mobile
  Scenario: A usage limit is not marked as a failed call
    Given the turn stopped at the provider's usage limit
    Then the row "Usage limit reached" is shown without a failure mark
    And a provider error that is not a usage limit is shown with a failure mark

  @mobile
  Scenario: A turn's failure cannot be opened for more detail
    Given the turn failed with a provider error
    Then the failure row stays open with its message
    And the row has nothing more to expand

  @backlog @shared @priority-high
  Scenario: The thinking row after a failed call still opens the run's tool calls
    Given the latest tool call of a running turn failed and the live row reads "Thinking"
    When the user opens that row
    Then the run's tool calls show below it and close again when it is closed

  @backlog @shared @priority-low
  Scenario: Tool inputs that are JSON are highlighted
    Given a tool call whose input is valid JSON
    When the user inspects the call
    Then the input is highlighted for the current theme
    And an input that is not JSON shows as plain text

  @backlog @shared @priority-high
  Scenario: An expanded command or tool call shows its output
    Given a finished command whose output was not sent with the thread
    When the user expands the call
    Then the MC supplies its stored output, limited to 256 KiB per value
    And a call with nothing more to show does not expand

  @backlog @shared @priority-high
  Scenario: An expanded call shows the call above a muted result
    When the user expands a tool call
    Then the full call shows first and its result below it, muted, without cards or labels

  @backlog @shared
  Scenario: An MCP tool call reads as the integration it belongs to
    Given an agent calls "firecrawl_scrape" on an MCP server named "Firecrawl"
    When the call is shown
    Then its title is readable rather than "Mcp__claude_ai_Firecrawl__firecrawl_scrape"
    And it shows the server's logo when the provider supplies one
    And a run of calls to that server groups as "Used Firecrawl integration"

  @backlog @shared @priority-low
  Scenario: An agent's own built-in tools are not shown as an integration
    Given an agent labels its built-in shell and edit tools like MCP tools
    When they are shown
    Then they keep their command and diff display and are not grouped as an integration

  @backlog @shared @priority-low
  Scenario: An expanded shell command is syntax highlighted
    Given a command row with a chained command, or a script inside a heredoc or a shell wrapper
    When the user expands it
    Then the command shows as it ran, wrapper included, with the shell's syntax highlighted
    And a script inside it is highlighted in its own language
    And a PowerShell command is highlighted as PowerShell
    And words wrap whole, control characters show as visible symbols, and a blank command gets no blank label

  @backlog @shared
  Scenario: A tool's screenshot shows as an image
    Given an agent took a device screenshot or a preview snapshot with an image
    When the user expands its tool row
    Then the image is shown, also when the output is larger than the 256 KiB the expanded read allows
    And no base64 text is shown

  @backlog @shared @priority-low
  Scenario: An agent can show an HTML page inline above its reply
    Given an agent published a self-contained HTML page in the thread
    When the thread is shown
    Then the page renders inline above the agent's final reply
    And it cannot read local files or reach the local network, and a link in it opens only after a user action in the frame

  @backlog @shared @priority-low
  Scenario: An inline HTML page does not hold the thread's scroll
    Given an inline page that wraps a few pixels taller than its frame
    When the user scrolls the thread with the pointer over it
    Then the thread scrolls
    And the frame fits the page's reported content height, capped by the agent's height only when that is smaller

  @backlog @mobile
  Scenario: Dragging over an inline HTML page taller than its frame scrolls the page, then the thread
    Given an inline page taller than the most its frame can show
    When the user drags up over the page on the phone
    Then the page scrolls its hidden part first
    And once the page is at its end the thread carries on scrolling
    And a page that is only too wide lets vertical drags scroll the thread and sideways drags pan the page

  @backlog @mc @shared
  Scenario: An inline HTML page shows the shape of its layout while it loads
    Given an agent published an HTML page with a heading, an image and a table
    When the thread is shown before the page has loaded
    Then the page's frame shows placeholders where its text, image and table will be
    And the MC described that outline when the page was published, in at most 48 boxes
    And a page published before outlines existed shows a generic placeholder

  @backlog @mc @shared
  Scenario: An inline HTML page opened full screen is not downloaded again
    Given an inline HTML page has loaded in the thread
    When the user opens it full screen
    Then it opens from the copy already loaded, as long as its address is valid for more than five more minutes
    And addresses the MC hands out for that page within the same half hour are the same address

  @backlog @shared
  Scenario: An inline HTML page opens full screen with zoom
    Given an agent published an HTML page in the thread
    Then the page offers "Open full screen" and no longer offers opening it in the side panel
    When the user opens it full screen
    Then the page fills the window with a close button and zoom from 50% to 200%
    When the user closes it
    Then focus returns to the page in the thread, still loaded

  @backlog @shared
  Scenario: Clicking an image in an inline HTML page opens it in the image viewer
    Given an agent published an HTML page with an image
    When the user clicks the image, inline or full screen
    Then the image opens in the same viewer chat images use, with its alt text
    And an image inside a link still follows the link
    And a click with a modifier key, or one the page itself handled, does not open the viewer
    And closing the viewer leaves the page open

  @backlog @shared
  Scenario Outline: A link in an inline HTML page opens the way a chat link does
    Given an agent published an HTML page linking to <target>
    When the user <clicks> the link
    Then <result>

    Examples:
      | target                                  | clicks                    | result                                                    |
      | a pull request of the thread's project  | clicks                    | the pull request opens in the thread's side panel          |
      | "https://example.com/docs"              | clicks                    | it opens where the "Open links in" setting says            |
      | "https://example.com/docs"              | Cmd- or Ctrl-clicks       | it opens in the system browser                             |

  @backlog @shared
  Scenario: App shortcuts keep working while an inline HTML page has focus
    Given the user clicked into an inline HTML page
    When the user presses the command palette's shortcut
    Then the command palette opens
    And the page's own handling of a key, or a key typed into a field in the page, stays with the page

  @backlog @shared
  Scenario: An inline HTML page cannot press a shortcut that changes a thread
    Given an inline HTML page sends the app a key it made up itself
    When that key is the shortcut to settle, steer or undo
    Then the thread is unchanged
