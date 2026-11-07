# Sources:
#   https://github.com/pingdotgg/t3code/pull/26718
#   https://github.com/pingdotgg/t3code/pull/26642
#   https://github.com/pingdotgg/t3code/pull/18194
#   https://github.com/pingdotgg/t3code/pull/18360
#   https://github.com/pingdotgg/t3code/pull/17454
#   https://github.com/pingdotgg/t3code/pull/21027
#   https://github.com/pingdotgg/t3code/pull/17791
#   https://github.com/pingdotgg/t3code/pull/17823
#   https://github.com/pingdotgg/t3code/pull/17145
#   https://github.com/pingdotgg/t3code/pull/16782
#   https://github.com/pingdotgg/t3code/pull/15627
#   https://github.com/pingdotgg/t3code/pull/15617
#   https://github.com/pingdotgg/t3code/pull/2829
#   https://github.com/pingdotgg/t3code/pull/24784
#   https://github.com/pingdotgg/t3code/pull/22732
#   https://github.com/pingdotgg/t3code/pull/22901
#   https://github.com/pingdotgg/t3code/pull/22452
#   https://github.com/pingdotgg/t3code/pull/25306
#   https://github.com/pingdotgg/t3code/pull/16654
#   https://github.com/pingdotgg/t3code/pull/26442
#   apps/server-ex/lib/hal_c2/mcp/tools.ex (hal_c2_thread_list, hal_c2_thread_read, hal_c2_thread_send,
#     hal_c2_thread_wait, hal_c2_thread_interrupt, hal_c2_thread_search, hal_c2_environment_read,
#     hal_c2_environment_preferences_update)
#   apps/server-ex/lib/hal_c2/mcp/tools/threads.ex (hal_c2_thread_launch, create_threads,
#     hal_c2_thread_fork, hal_c2_thread_merge_back, hal_c2_thread_update, hal_c2_thread_configure,
#     hal_c2_thread_configuration, hal_c2_thread_organize, hal_c2_thread_transfers,
#     hal_c2_thread_send_attachments, hal_c2_attachment_prepare_upload, hal_c2_attachment_discard,
#     orchestrator_capabilities)
#   V2 commands issued: message.dispatch (start_immediately, steer_active, restart_active,
#     queue_after_active), run.interrupt, thread.create, thread.fork, thread.merge_back,
#     thread.metadata.update, thread.model-selection.set, provider.switch, thread.pin,
#     thread.unpin, thread.settle, thread.unsettle, thread.snooze, thread.unsnooze,
#     thread.archive, thread.unarchive, thread.mark-unread
#   apps/server/src/mcp/toolkits/thread, orchestrator, environment, attachment, project
Feature: Agents working with threads through MCP tools
  An agent reads, messages, creates and organizes threads as the thread it runs in.
  It lists its own project unless it asks for all projects, and can read and
  organize any thread of the MC; messaging stays inside its project. Writes follow
  the access rules of the MCP server.

  Background:
    Given an MC with a project "demo"
    And thread "caller" in "demo" runs in full-access mode with a turn running on "codex"
    And thread "t2" in "demo" is idle

  @mc
  Scenario: Listing threads shows the caller's project
    Given thread "x" belongs to another project
    When the agent of "caller" lists threads
    Then it receives "caller" and "t2" with the project id and the caller's own id
    And it does not receive "x"

  @mc
  Scenario Outline: Listing threads can be filtered and paged
    When the agent of "caller" lists threads <filter>
    Then only matching threads are returned with a total and a next cursor when more remain

    Examples:
      | filter                                 |
      | with status "running"                  |
      | whose title contains "Fix" in any case |
      | leaving out subagent threads           |
      | with a limit of 1                      |

  # Upstream #25306: an empty status list returned no threads at all.
  @mc
  Scenario: An empty status filter lists threads as if no status were asked for
    When the agent of "caller" lists threads with an empty list of statuses
    Then it receives "caller" and "t2" with a total of 2

  @mc
  Scenario: Reading a thread returns its messages incrementally
    Given "t2" has 5 messages
    When the agent of "caller" reads "t2" after position 2
    Then it receives the messages at positions 3 and 4, the next position and whether more remain
    And the thread's recent runs, newest first

  # Upstream #18194: reading a thread names the thread that sent each agent message
  @mc
  Scenario: Reading a thread says which thread sent a message
    Given the agent of "caller" sent "check the tests" to "t2"
    When another agent reads "t2"
    Then "check the tests" names "caller" as the thread that sent it
    And messages the user typed name no sending thread

  @mc
  Scenario: The activity view includes tool work, not just messages
    When the agent of "caller" reads "t2" in the activity view
    Then commands, file changes and other items are included

  @mc
  Scenario: Long items are cut to a character limit and can be continued
    Given a message of "t2" is 30,000 characters long
    When the agent of "caller" reads it with a limit of 20,000 characters
    Then the text is cut to 20,000 characters and can be read on from an offset

  # Upstream #22901: limits above their maximum failed the read.
  @mc
  Scenario Outline: Reading a thread with a limit over its maximum uses the maximum
    When the agent of "caller" reads "t2" with <argument> of <value>
    Then <result>

    Examples:
      | argument          | value  | result                                  |
      | limit             | 500    | it reads with a limit of 100            |
      | runLimit          | 500    | it reads with a run limit of 50         |
      | maxCharsPerItem   | 900000 | it reads with at most 50,000 characters |
      | limit             | 0      | the read is refused                     |

  @mc
  Scenario: Reading without a thread id reads the caller
    When the agent of "caller" reads without naming a thread
    Then it receives "caller"

  # Upstream #17823: agents paging with "cursor" had it dropped and read from the start again.
  @backlog @mc @priority-low
  Scenario: Reading a thread with an argument the tool does not take is refused
    When the agent of "caller" reads "t2" with a "cursor" argument
    Then the read is refused because "cursor" is not one of its arguments
    And the tool's description says it takes no arguments other than its own

  @mc
  Scenario Outline: Sending a message picks how it is delivered
    Given "t2" <state>
    When the agent of "caller" sends "check the tests" to "t2" in mode "<mode>"
    Then the message is delivered as <delivery>
    And it is recorded as sent by "caller", created by an agent through MCP

    Examples:
      | state            | mode    | delivery                          |
      | is idle          | auto    | a new turn started immediately    |
      | has a turn running | auto  | a steer of the running turn       |
      | has a turn running | queue | a turn queued after the active one |
      | has a turn running | restart | a restart of the running turn   |

  @mc
  Scenario: Restarting needs a running turn
    Given "t2" is idle
    When the agent of "caller" sends a message to "t2" in mode "restart"
    Then it fails with code "thread_not_sendable"

  # Upstream #21027: a send the orchestrator refuses reports the orchestrator's reason, the one
  # a client would show, instead of a generic dispatch failure.
  @backlog @mc
  Scenario: A send the orchestrator refuses says why
    Given "t2" has a turn running whose provider session is gone
    When the agent of "caller" sends a message to "t2" in mode "restart"
    Then it fails with the orchestrator's reason for refusing it
    And not only with the name of the command that failed

  @mc
  Scenario: An archived thread cannot be messaged
    Given "t2" is archived
    When the agent of "caller" sends a message to "t2"
    Then it fails with code "thread_not_sendable" and "The thread is archived."

  @mc
  Scenario: Waiting returns when the run finishes
    Given "t2" has a turn running
    When the agent of "caller" waits on "t2"
    And that turn completes
    Then the wait returns status "completed" without timing out

  @mc
  Scenario: Waiting gives up at its timeout
    Given "t2" has a turn running that does not finish
    When the agent of "caller" waits on "t2" for 1 second
    Then the wait returns the run's current status and that it timed out

  @mc
  Scenario: A wait gives up before the caller's MCP client would
    Given "t2" has a turn running that does not finish
    And the MCP client of an ACP provider gives up on a tool call after 1 second
    When the agent of "caller" on "opencode" waits on "t2" for 2 hours
    Then the wait returns the run's current status and that it timed out

  @mc
  Scenario Outline: The wait timeout is clamped
    When the agent of "caller" waits on "t2" for <asked>
    Then the wait lasts at most <used>

    Examples:
      | asked            | used                |
      | nothing given    | 10 minutes          |
      | 0 milliseconds   | 1 millisecond       |
      | 2 hours          | 1 hour              |

  @mc
  Scenario: Waiting on an idle thread returns at once
    When the agent of "caller" waits on idle thread "t2"
    Then the wait returns immediately with the latest run's status

  @mc
  Scenario: Interrupting another thread's turn
    Given "t2" has a turn running
    When the agent of "caller" interrupts "t2"
    Then the running turn of "t2" is interrupted

  @mc
  Scenario: Searching threads stays inside the project
    Given threads in "demo" and in another project mention "flaky"
    When the agent of "caller" searches for "flaky"
    Then only matches in "demo" are returned

  @mc
  Scenario: Reading the environment shows enabled providers and their models
    When the agent of "caller" reads the environment
    Then it receives the environment id, label, platform, the caller's thread and project
    And each enabled provider instance with its driver, status and model slugs

  @mc
  Scenario: Updating preferences changes only the allowed settings
    When the agent of "caller" updates the default thread workspace mode and the writing style
    Then those settings change
    And settings outside the allowed list are left alone

  @mc
  Scenario: Long custom writing instructions are cut when an agent reads the environment
    Given the writing style has custom instructions of 5,000 characters
    When the agent of "caller" reads the environment
    Then the custom instructions arrive cut to 4,000 characters
    And they are flagged as truncated

  @mc
  Scenario Outline: A credential from another environment cannot reach this one's preferences
    Given a credential that was issued by another environment
    When its agent <action>
    Then it fails with code "capability_denied" and "This credential belongs to another environment."

    Examples:
      | action                       |
      | reads the environment        |
      | updates the preferences      |

  @mc
  Scenario: Launching a thread starts it with the caller's model and modes
    When the agent of "caller" launches a thread in "demo" with message "Write the release notes"
    Then a new thread is created by an agent through MCP with the caller's model and modes
    And its first turn starts with that message

  # Needs a maintainer decision on how an agent outside any thread authenticates and what access it is
  # approved for: hal-c2/hal-c2#1235 (this scenario and the next).
  # Upstream #22732: a launch from outside any thread ignored the model saved in settings and
  # always took the caller's full access.
  @backlog @mc @priority-high
  Scenario: A thread launched from outside any thread starts with the project's defaults
    Given the project "demo" defaults to the model "gpt-5.5" in Supervised mode
    And an agent outside HAL-C2 is signed in with Full access approved
    When that agent launches a thread in "demo" with message "Find why the tests are slow"
    Then the thread starts with "gpt-5.5" in Supervised mode

  # Upstream #22732: the defaults never go past what the outside caller was approved for.
  @backlog @mc @priority-high
  Scenario: A thread launched from outside any thread stays within the caller's approved access
    Given the project "demo" defaults to Full access
    And an agent outside HAL-C2 is signed in with Supervised access approved
    When that agent launches a thread in "demo"
    Then the thread starts in Supervised mode

  # Upstream #22732: scripts and terminals drive threads with the same thread tools, signed in
  # for the length of one command.
  @backlog @mc @priority-low
  Scenario: A thread is started and messaged from the terminal
    Given the MC is running and the terminal is in a folder of the project "demo"
    When the user starts a thread there from the terminal with "Find why the tests are slow"
    Then the thread's id is printed
    And sending "Now fix it" to that id from the terminal queues it behind any running turn
    And the terminal's sign-in is revoked when each command ends

  # Upstream #22732: waiting reports that run's own outcome in the exit status.
  @backlog @mc @priority-low
  Scenario Outline: Waiting on a thread from the terminal exits by how its run ended
    Given the user sent a message to a thread from the terminal and waits for it
    When that run <ends>
    Then the terminal prints <printed> and exits with <status>

    Examples:
      | ends                      | printed                  | status |
      | ends with a reply         | the reply                | 0      |
      | fails or is stopped       | the error                | 1      |
      | waits for the user's answer | that it needs an answer | 2      |

  # Upstream #22732: a launch onto a base ref that does not exist made a thread in the project folder.
  @backlog @mc
  Scenario: A launch onto a base ref that does not exist is refused before anything is made
    When the agent of "caller" launches a thread in a new worktree from the base ref "no-such-branch"
    Then the launch is refused naming the ref
    And no thread or worktree is created

  @mc
  Scenario: An agent launches a thread in a new worktree on a named branch
    When the agent of "caller" launches a thread in "demo" in a new worktree based on "feature/base" on branch "feature/demo"
    Then a new thread exists in "demo"
    And its worktree is based on "feature/base"
    And its first run waits until the worktree is ready

  # Legacy: apps/server/src/mcp/toolkits/project/tools.ts and handlers.ts (hal_c2_thread_launch)
  @mc
  Scenario: A launch that names no workspace starts in the project root, not in the caller's worktree
    Given thread "caller" works in worktree "/work/x" on branch "feature/x"
    When the agent of "caller" launches a thread in "demo" without saying where it works
    Then the new thread works in the project root with no worktree
    And it does not share the caller's worktree or branch

  # Legacy: apps/server/src/mcp/toolkits/project/tools.ts, attachment/tools.ts (input schemas)
  @mc
  Scenario Outline: A launch or an attachment send over the input limits is refused
    When the agent of "caller" <request>
    Then the tool refuses the input as invalid
    And no thread is created and nothing is sent

    Examples:
      | request                                                        |
      | launches a thread with a message of 120,001 characters         |
      | launches a thread with 9 attachments                           |
      | sends 9 attachments to "t2"                                    |
      | sends no attachments to "t2"                                   |
      | sends attachments to "t2" with a message of 120,001 characters |

  @mc
  Scenario: A launched thread accepts only freshly uploaded attachments
    When the agent of "caller" launches a thread with an attachment that already belongs to "t2"
    Then it fails with code "invalid_request" and "A new thread accepts only pending attachment uploads."

  @mc
  Scenario: Launching into an unknown project fails
    When the agent of "caller" launches a thread in project "nowhere"
    Then it fails with code "invalid_request" and "The project was not found."

  # Upstream #17791: the launch said it succeeded and the new thread failed a moment later.
  @backlog @mc
  Scenario: A launch in a new worktree on a base that does not exist is refused
    Given "demo" has no branch, tag or commit named "hal-c2/b1ffc1cb" in any namespace
    When the agent of "caller" launches a thread in "demo" in a new worktree based on "hal-c2/b1ffc1cb" without starting from origin
    Then it fails with code "invalid_request" naming "hal-c2/b1ffc1cb", the project and its folder
    And no thread or run is created

  @backlog @mc
  Scenario Outline: A launch on a base the MC cannot rule out goes ahead
    Given <situation>
    When the agent of "caller" launches a thread in "demo" in a new worktree based on "feature/base"
    Then a new thread exists in "demo"

    Examples:
      | situation                                                               |
      | "feature/base" exists only as "origin/feature/base"                     |
      | the launch starts from origin and "demo" has an origin remote           |
      | "demo" is a repository with no commit yet                               |
      | "demo"'s folder is not a repository                                     |

  # Upstream #16654: an agent whose launch reply was lost could only launch again and make a
  # second thread; the launch tool takes a request key, and a retry returns the same thread.
  @mc @priority-high
  Scenario: Repeating a thread launch with the same request key returns the same thread
    Given the agent of "caller" launched a thread in "demo" with request key "k1" and message "Hello"
    When it repeats the launch with request key "k1"
    Then it is answered with the thread the first launch created
    And that thread has one user message
    And no extra thread is created

  # Upstream #16654: a replayed launch keeps its first model and skips the checks only a new
  # launch needs, which the project may no longer pass.
  @backlog @mc
  Scenario Outline: A repeated launch is answered even when a new one would now be refused
    Given the agent of "caller" launched a thread in "demo" with request key "k1"
    And <change>
    When it repeats the launch with request key "k1"
    Then it is answered with the thread the first launch created

    Examples:
      | change                                           |
      | "demo" no longer has a default model             |
      | the base branch of the launch's worktree is gone |

  @mc
  Scenario: Creating threads in a batch puts them beside the caller
    When the agent of "caller" creates 3 threads with prompts
    Then 3 top-level threads exist in the caller's project and workspace
    And each starts its prompt immediately
    And their ids are derived from the caller, the request key and their position

  @mc
  Scenario: Repeating a batch with the same request key does not duplicate threads
    Given the agent of "caller" created threads with request key "k1"
    When it repeats the request with request key "k1"
    Then it fails because the threads already exist
    And no extra threads are created

  # Upstream #18360: a repeat of an accepted batch is answered with the threads it created, even
  # once the project has turned its provider off; a new batch is judged by today's settings.
  # Replaces the scenario above once the MC carries it.
  @mc @backlog
  Scenario: Repeating a batch with the same request key answers with the threads it created
    Given the agent of "caller" created threads on "codex-work" with request key "k1"
    And the project then turned "codex-work" off
    When it repeats the request with request key "k1"
    Then it is answered with the threads the first request created
    And no extra threads are created
    But a new batch on "codex-work" is refused because the provider is off for the project

  @mc
  Scenario Outline: Batch-created thread titles
    When the agent of "caller" creates a thread with <input>
    Then its title is <title>

    Examples:
      | input                              | title                                     |
      | title "Audit deps"                 | "Audit deps"                              |
      | no title and a 100-character prompt | the first 77 characters followed by "..." |
      | no title and no prompt, 2nd in batch | the caller's title followed by " thread 2" |

  @mc
  Scenario: A batch holds at most 20 threads
    When the agent of "caller" asks for 21 threads in one batch
    Then the request is rejected

  @mc
  Scenario Outline: A batch thread's provider must be able to run
    When the agent of "caller" creates a thread on <target>
    Then it fails with code "<code>"

    Examples:
      | target                                        | code                 |
      | a driver with no usable instance              | provider_unavailable |
      | an instance that is not registered            | provider_unavailable |
      | an instance that is not signed in             | provider_unavailable |
      | an instance whose driver differs from the one named | invalid_request |
      | a model the instance does not offer           | model_unavailable    |

  @mc
  Scenario: A failed thread in a batch stops the rest
    When the agent of "caller" creates 3 threads and the second cannot be created
    Then the first exists, the third was not attempted
    And the error names thread 2

  @mc
  Scenario: Forking the caller
    Given "caller" has a completed turn
    When the agent of "caller" forks itself
    Then a fork of "caller" is created by an agent through MCP and its id is returned

  @mc
  Scenario: Merging the caller back into its parent
    Given "caller" is a fork of "t2" with a completed turn
    When the agent of "caller" merges back into "t2"
    Then a merge-back from "caller" to "t2" is pending

  @mc
  Scenario Outline: Updating a thread's metadata
    When the agent of "caller" updates "t2" with action "<action>"
    Then <result>

    Examples:
      | action              | result                                                         |
      | rename              | "t2" has the new title                                         |
      | regenerate_title    | a title for "t2" is generated from its first message           |
      | link_pull_request   | "t2" links the pull request in its project                     |
      | unlink_pull_request | "t2" has no linked pull request                                |

  @mc
  Scenario Outline: Metadata updates that cannot be made
    When the agent of "caller" updates "t2" with <input>
    Then it fails with code "invalid_request" and "<message>"

    Examples:
      | input                                    | message                                          |
      | action "rename" and no title             | rename requires title.                           |
      | action "regenerate_title" and no message | The thread has no message to take a title from.  |
      | action "link_pull_request" and no PR     | link_pull_request requires pullRequest.          |
      | action "shout"                           | Unknown action shout.                            |

  @mc
  Scenario Outline: Configuring the caller's model
    When the agent of "caller" configures model <selection>
    Then <result>
    And the result names the selection for the next turn and the model of the turn in progress

    Examples:
      | selection                      | result                                   |
      | "gpt-5.5" on its own instance  | the caller's model selection changes     |
      | "claude-sonnet-5" on "claudeAgent" | the caller switches provider         |

  @mc
  Scenario: Reading a thread's configuration
    When the agent of "caller" reads the configuration of "t2"
    Then it receives the model selection, runtime mode and interaction mode of "t2"

  # A switch applies from the next turn; the read tells the two apart (#1048).
  @mc
  Scenario: Reading the configuration of a thread switched during its turn
    When the agent of "caller" configures model "claude-sonnet-5" on "claudeAgent"
    And the agent of "caller" reads the configuration of "caller"
    Then the configuration shows "claudeAgent" for the next turn and "codex" for the turn in progress

  @mc
  Scenario: Listing or reading a thread shows whether it can settle
    Given thread "t2" has a settlement decision
    When the agent of "caller" lists or reads "t2"
    Then the response includes the settlement state of "t2"
    And it says why "t2" can or cannot settle

  # Upstream #17454: thread list and read include the thread's visible pull request links, the
  # list list_thread_pull_requests returns, without dismissed stack members.
  @mc
  Scenario: Listing or reading a thread shows every pull request linked to it
    Given "t2" is linked to pull request 42 in "demo" and pull request 7 in another repository
    When the agent of "caller" lists or reads "t2"
    Then the response names both pull requests with their host, repository, number and state

  # Upstream #16782: agents see snooze state, can filter on it, and are told how to link a thread.
  @mc
  Scenario: Listing or reading a thread shows whether it is snoozed and until when
    Given thread "t2" is snoozed until tomorrow 09:00
    When the agent of "caller" lists or reads "t2"
    Then the response says "t2" is snoozed until tomorrow 09:00

  @mc @priority-low
  Scenario Outline: Listing threads can be filtered by snooze
    Given thread "t2" is snoozed and thread "t3" in "demo" is not
    When the agent of "caller" lists threads with snoozed <filter>
    Then the list holds <listed>

    Examples:
      | filter | listed                      |
      | true   | "t2" and not "t3"           |
      | false  | "t3" and not "t2"           |

  # Upstream #26442: going through the user's snoozed threads took one call per project.
  # Upstream reads and organizes any thread of the server, so every listed id can be acted on.
  @mc
  Scenario: An agent lists the threads of every project in one call
    Given thread "t2" in "shop" and thread "t3" in "demo" are snoozed
    When the agent of "caller" lists threads of all projects with snoozed true
    Then the list holds "t2" and "t3", each naming its project
    And the list names no single project
    And the agent of "caller" can read and unsnooze each listed thread

  @backlog @mc
  Scenario: Agents are told how to link to a thread in their answers
    When an agent reads the orchestration instructions
    Then they say a thread is linked by its id with a thread link, not by a copied title

  # Upstream #24784: every thread tool result carries the thread's link ready-made, so agents
  # do not build it from a bare id or a title.
  @backlog @mc
  Scenario Outline: A thread tool returns a ready link for each thread it names
    When the agent of "caller" <calls>
    Then each thread in the result carries a thread link holding its exact id

    Examples:
      | calls                                  |
      | lists threads                          |
      | reads "t2"                             |
      | searches threads for "tax"             |
      | launches a thread                      |
      | sends "go on" to "t2"                  |
      | delegates a task and checks its status |
  # Upstream #26642: an agent outside the app got a thread token only the app could draw; it now
  # gets a link it can open. Upstream's is a web URL; HAL-C2 has no web client, so the link opens
  # the thread in a HAL-C2 client. Agents inside HAL-C2 keep the thread link the clients draw.
  @backlog @mc
  Scenario Outline: An agent outside HAL-C2 gets thread links it can open
    Given an agent outside HAL-C2 is signed in to the MC's server
    When it <calls>
    Then each thread in the result carries a link that opens that thread in a HAL-C2 client
    And an agent inside HAL-C2 calling the same tool still gets the thread link the clients draw

    Examples:
      | calls                               |
      | launches a thread                   |
      | lists threads                       |
      | reads "t2"                          |
      | searches threads for "tax"          |
      | sends "go on" to "t2"               |
      | runs a scheduled task now           |


  @mc
  Scenario Outline: Organizing a thread
    When the agent of "caller" organizes "t2" with action "<action>"
    Then "t2" is <result>

    Examples:
      | action      | result        |
      | pin         | pinned        |
      | unpin       | unpinned      |
      | settle      | settled       |
      | unsettle    | unsettled     |
      | snooze      | snoozed       |
      | unsnooze    | not snoozed   |
      | archive     | archived      |
      | unarchive   | unarchived    |
      | mark_unread | marked unread |

  @mc
  Scenario: Snoozing needs a time
    When the agent of "caller" snoozes "t2" without a time
    Then it fails with code "invalid_request" and "snooze requires snoozedUntil."

  # Upstream #26718: an agent that named its threads under an undeclared "threadIds" lost them,
  # so organizing fell back to the calling thread and the orchestrator archived itself.
  @backlog @mc @priority-high
  Scenario: Organizing with an argument the tool does not take fails without touching the caller
    When the agent of "caller" asks to archive with "threadIds" ["t2", "t3"] instead of a thread id
    Then it fails as invalid arguments naming "threadIds"
    And "caller", "t2" and "t3" are not archived

  @mc
  Scenario: Listing a thread's context transfers
    Given "t2" has a pending merge-back from a fork
    When the agent of "caller" lists the transfers of "t2"
    Then it receives each transfer's id, source, target and status

  @mc
  Scenario: Sending attachments to another thread
    Given the agent of "caller" prepared an upload
    When it sends the uploaded attachment to "t2" with a message
    Then "t2" receives the message with the attachment

  @mc
  Scenario Outline: Attachments that cannot be sent
    Given <situation>
    When the agent of "caller" sends attachments to "t2"
    Then it fails with code "invalid_request" and "<message>"

    Examples:
      | situation                                   | message                                                                 |
      | "t2" is archived                            | Unarchive the target thread before sending attachments.                 |
      | the attachment belongs to a different thread | Attachments must be pending uploads or already belong to the target thread. |

  @mc
  Scenario: Preparing and discarding an upload
    When the agent of "caller" prepares an upload
    Then it receives where to upload it
    And discarding the attachment removes it

  @mc
  Scenario: Reporting what the orchestrator can do
    When the agent of "caller" asks for the orchestrator's capabilities
    Then it receives the caller's inherited provider, model and modes
    And each provider instance with its models, options and whether it can run a child task and why not
    And that batches hold at most 20 threads

  # Upstream reads any thread of the server, attached or not (threadAccess.ts readThread).
  @mc
  Scenario: A thread of another project can be read but not messaged
    Given thread "elsewhere" of another project has a message
    When the agent of "caller" reads "elsewhere"
    Then it receives the thread's messages
    But listing its own project, sending to or interrupting "elsewhere" is still refused

  # Dropped: read reaches every thread of the MC (upstream #26442 and threadAccess.ts), so a
  # context record, whoever wrote it, no longer decides what an agent can read.
  @dropped @mc
  Scenario: A thread an agent attached does not widen what the agent can read
    Given a message written by an agent of "caller" carries a context record naming thread "elsewhere" of another project
    When the agent of "caller" reads "elsewhere"
    Then the tool fails with code "thread_not_found"

  @mc
  Scenario: A deleted thread cannot be read
    Given thread "t2" was deleted
    When the agent of "caller" reads "t2"
    Then the tool fails with code "thread_not_found" saying "Thread t2 is no longer available."

  # Upstream #22452: an agent naming a thread by its bare id gets pointed at the right one.
  @backlog @mc @priority-low
  Scenario Outline: Reading a thread by a bare id suggests the full id only when that thread exists
    Given <thread>
    When the agent of "caller" reads "4f1c"
    Then the tool fails with code "thread_not_found" <hint>

    Examples:
      | thread                                     | hint                                               |
      | thread "mcp:4f1c" exists                   | ending in "Did you mean `mcp:4f1c`?"               |
      | thread "mcp:4f1c" was deleted              | with its usual message                             |
      | no thread "mcp:4f1c" exists                | with its usual message                             |

  @mc
  Scenario Outline: Interrupting a thread says what happened
    Given <situation>
    When the agent of "caller" interrupts "t2"
    Then the answer's status is <status>

    Examples:
      | situation                                              | status                            |
      | "t2" has a turn running                                | interrupt_requested               |
      | "t2" has no turn running                               | no_active_run                     |
      | the agent names a run of "t2" that already finished    | that run's final status           |

  @mc
  Scenario: Repeating a send with the same request key delivers it once
    Given the agent of "caller" sent "run the tests" to "t2" with request key "k1"
    When it repeats the send with request key "k1"
    Then "t2" received the message once

  @mc
  Scenario: Two callers may use the same request key without losing a message
    Given thread "other" in "demo" runs in full-access mode with a turn running on "codex"
    When the agent of "caller" sends "from caller" to "t2" with request key "status"
    And the agent of "other" sends "from other" to "t2" with request key "status"
    Then "t2" received both messages

  @mc
  Scenario: Repeating an interrupt with the same request key interrupts once
    Given the agent of "caller" interrupted "t2" with request key "k1"
    When it repeats the interrupt with request key "k1"
    Then the turn of "t2" was interrupted once

  @mc
  Scenario: Repeating an interrupt that found nothing running leaves a later turn alone
    Given the agent of "caller" interrupted idle "t2" with request key "k1"
    And "t2" has a turn running
    When it repeats the interrupt with request key "k1"
    Then the answer's status is no_active_run
    And the new turn of "t2" was not interrupted

  @backlog @mc
  Scenario: A tool that fails as declared is marked as an error
    When an agent asks to read a thread that does not exist
    Then the tool call is marked as an error
    And it carries the failure code "thread_not_found"

  @backlog @mc
  Scenario: A refused thread command says why
    Given a thread has an active run
    When an agent asks to settle the thread
    Then the refusal carries the reason the MC gave, up to 1000 characters

  # Upstream #17145: "fix it and then settle this thread" was refused because the asking turn was still running.
  @backlog @mc
  Scenario Outline: An agent that settles its own thread settles it when its turn ends
    Given the agent in "Ship checkout" asks to settle "Ship checkout" during its turn
    Then the answer says the thread settles when the turn ends
    When <ending>
    Then "Ship checkout" is <outcome>

    Examples:
      | ending                                                  | outcome |
      | the turn completes                                      | settled |
      | the turn fails                                          | active  |
      | the user interrupts the turn                            | active  |
      | the user queues a message before the turn completes     | active  |

  @backlog @mc
  Scenario: A settle waiting on the agent's turn is forgotten when the MC restarts
    Given the agent in "Ship checkout" asked to settle its own thread during its turn
    When the MC restarts before the turn ends
    Then "Ship checkout" stays active
