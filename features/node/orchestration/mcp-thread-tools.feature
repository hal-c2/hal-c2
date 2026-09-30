# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
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
#   apps/server/src/mcp/toolkits/thread, orchestrator, environment, attachment
Feature: Agents working with threads through MCP tools
  An agent reads, messages, creates and organizes threads of its own project as
  the thread it runs in. Writes follow the access rules of the MCP server.

  Background:
    Given a node with a project "demo"
    And thread "caller" in "demo" runs in full-access mode with a turn running on "codex"
    And thread "t2" in "demo" is idle

  @node
  Scenario: Listing threads shows the caller's project
    Given thread "x" belongs to another project
    When the agent of "caller" lists threads
    Then it receives "caller" and "t2" with the project id and the caller's own id
    And it does not receive "x"

  @node
  Scenario Outline: Listing threads can be filtered and paged
    When the agent of "caller" lists threads <filter>
    Then only matching threads are returned with a total and a next cursor when more remain

    Examples:
      | filter                                 |
      | with status "running"                  |
      | whose title contains "Fix" in any case |
      | leaving out subagent threads           |
      | with a limit of 1                      |

  @node
  Scenario: Reading a thread returns its messages incrementally
    Given "t2" has 5 messages
    When the agent of "caller" reads "t2" after position 2
    Then it receives the messages at positions 3 and 4, the next position and whether more remain
    And the thread's recent runs, newest first

  @node
  Scenario: The activity view includes tool work, not just messages
    When the agent of "caller" reads "t2" in the activity view
    Then commands, file changes and other items are included

  @node
  Scenario: Long items are cut to a character limit and can be continued
    Given a message of "t2" is 30,000 characters long
    When the agent of "caller" reads it with a limit of 20,000 characters
    Then the text is cut to 20,000 characters and can be read on from an offset

  @node
  Scenario: Reading without a thread id reads the caller
    When the agent of "caller" reads without naming a thread
    Then it receives "caller"

  @node
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

  @node
  Scenario: Restarting needs a running turn
    Given "t2" is idle
    When the agent of "caller" sends a message to "t2" in mode "restart"
    Then it fails with code "thread_not_sendable"

  @node
  Scenario: An archived thread cannot be messaged
    Given "t2" is archived
    When the agent of "caller" sends a message to "t2"
    Then it fails with code "thread_not_sendable" and "The thread is archived."

  @node
  Scenario: Waiting returns when the run finishes
    Given "t2" has a turn running
    When the agent of "caller" waits on "t2"
    And that turn completes
    Then the wait returns status "completed" without timing out

  @node
  Scenario: Waiting gives up at its timeout
    Given "t2" has a turn running that does not finish
    When the agent of "caller" waits on "t2" for 1 second
    Then the wait returns the run's current status and that it timed out

  @node
  Scenario Outline: The wait timeout is clamped
    When the agent of "caller" waits on "t2" for <asked>
    Then the wait lasts at most <used>

    Examples:
      | asked            | used                |
      | nothing given    | 10 minutes          |
      | 0 milliseconds   | 1 millisecond       |
      | 2 hours          | 1 hour              |

  @node
  Scenario: Waiting on an idle thread returns at once
    When the agent of "caller" waits on idle thread "t2"
    Then the wait returns immediately with the latest run's status

  @node
  Scenario: Interrupting another thread's turn
    Given "t2" has a turn running
    When the agent of "caller" interrupts "t2"
    Then the running turn of "t2" is interrupted

  @node
  Scenario: Searching threads stays inside the project
    Given threads in "demo" and in another project mention "flaky"
    When the agent of "caller" searches for "flaky"
    Then only matches in "demo" are returned

  @node
  Scenario: Reading the environment shows enabled providers and their models
    When the agent of "caller" reads the environment
    Then it receives the environment id, label, platform, the caller's thread and project
    And each enabled provider instance with its driver, status and model slugs

  @node
  Scenario: Updating preferences changes only the allowed settings
    When the agent of "caller" updates the default thread workspace mode and the writing style
    Then those settings change
    And settings outside the allowed list are left alone

  @node
  Scenario: Launching a thread starts it with the caller's model and modes
    When the agent of "caller" launches a thread in "demo" with message "Write the release notes"
    Then a new thread is created by an agent through MCP with the caller's model and modes
    And its first turn starts with that message

  @node @backlog
  Scenario: An agent launches a thread in a new worktree on a named branch
    When the agent of "caller" launches a thread in "demo" in a new worktree based on "feature/base" on branch "feature/demo"
    Then a new thread exists in "demo"
    And its worktree is based on "feature/base"
    And its first run waits until the worktree is ready

  @node
  Scenario: A launched thread accepts only freshly uploaded attachments
    When the agent of "caller" launches a thread with an attachment that already belongs to "t2"
    Then it fails with code "invalid_request" and "A new thread accepts only pending attachment uploads."

  @node
  Scenario: Launching into an unknown project fails
    When the agent of "caller" launches a thread in project "nowhere"
    Then it fails with code "invalid_request" and "The project was not found."

  @node
  Scenario: Creating threads in a batch puts them beside the caller
    When the agent of "caller" creates 3 threads with prompts
    Then 3 top-level threads exist in the caller's project and workspace
    And each starts its prompt immediately
    And their ids are derived from the caller, the request key and their position

  @node
  Scenario: Repeating a batch with the same request key does not duplicate threads
    Given the agent of "caller" created threads with request key "k1"
    When it repeats the request with request key "k1"
    Then it fails because the threads already exist
    And no extra threads are created

  @node
  Scenario Outline: Batch-created thread titles
    When the agent of "caller" creates a thread with <input>
    Then its title is <title>

    Examples:
      | input                              | title                                     |
      | title "Audit deps"                 | "Audit deps"                              |
      | no title and a 100-character prompt | the first 77 characters followed by "..." |
      | no title and no prompt, 2nd in batch | the caller's title followed by " thread 2" |

  @node
  Scenario: A batch holds at most 20 threads
    When the agent of "caller" asks for 21 threads in one batch
    Then the request is rejected

  @node
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

  @node
  Scenario: A failed thread in a batch stops the rest
    When the agent of "caller" creates 3 threads and the second cannot be created
    Then the first exists, the third was not attempted
    And the error names thread 2

  @node
  Scenario: Forking the caller
    Given "caller" has a completed turn
    When the agent of "caller" forks itself
    Then a fork of "caller" is created by an agent through MCP and its id is returned

  @node
  Scenario: Merging the caller back into its parent
    Given "caller" is a fork of "t2" with a completed turn
    When the agent of "caller" merges back into "t2"
    Then a merge-back from "caller" to "t2" is pending

  @node
  Scenario Outline: Updating a thread's metadata
    When the agent of "caller" updates "t2" with action "<action>"
    Then <result>

    Examples:
      | action              | result                                                         |
      | rename              | "t2" has the new title                                         |
      | regenerate_title    | a title for "t2" is generated from its first message           |
      | link_pull_request   | "t2" links the pull request in its project                     |
      | unlink_pull_request | "t2" has no linked pull request                                |

  @node
  Scenario Outline: Metadata updates that cannot be made
    When the agent of "caller" updates "t2" with <input>
    Then it fails with code "invalid_request" and "<message>"

    Examples:
      | input                                    | message                                          |
      | action "rename" and no title             | rename requires title.                           |
      | action "regenerate_title" and no message | The thread has no message to take a title from.  |
      | action "link_pull_request" and no PR     | link_pull_request requires pullRequest.          |
      | action "shout"                           | Unknown action shout.                            |

  @node
  Scenario Outline: Configuring the caller's model
    When the agent of "caller" configures model <selection>
    Then <result>

    Examples:
      | selection                      | result                                   |
      | "gpt-5.5" on its own instance  | the caller's model selection changes     |
      | "claude-sonnet-5" on "claudeAgent" | the caller switches provider         |

  @node
  Scenario: Reading a thread's configuration
    When the agent of "caller" reads the configuration of "t2"
    Then it receives the model selection, runtime mode and interaction mode of "t2"

  @node @backlog
  Scenario: Listing or reading a thread shows whether it can settle
    Given thread "t2" has a settlement decision
    When the agent of "caller" lists or reads "t2"
    Then the response includes the settlement state of "t2"
    And it says why "t2" can or cannot settle

  @node
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

  @node
  Scenario: Snoozing needs a time
    When the agent of "caller" snoozes "t2" without a time
    Then it fails with code "invalid_request" and "snooze requires snoozedUntil."

  @node
  Scenario: Listing a thread's context transfers
    Given "t2" has a pending merge-back from a fork
    When the agent of "caller" lists the transfers of "t2"
    Then it receives each transfer's id, source, target and status

  @node
  Scenario: Sending attachments to another thread
    Given the agent of "caller" prepared an upload
    When it sends the uploaded attachment to "t2" with a message
    Then "t2" receives the message with the attachment

  @node
  Scenario Outline: Attachments that cannot be sent
    Given <situation>
    When the agent of "caller" sends attachments to "t2"
    Then it fails with code "invalid_request" and "<message>"

    Examples:
      | situation                                   | message                                                                 |
      | "t2" is archived                            | Unarchive the target thread before sending attachments.                 |
      | the attachment belongs to a different thread | Attachments must be pending uploads or already belong to the target thread. |

  @node
  Scenario: Preparing and discarding an upload
    When the agent of "caller" prepares an upload
    Then it receives where to upload it
    And discarding the attachment removes it

  @node
  Scenario: Reporting what the orchestrator can do
    When the agent of "caller" asks for the orchestrator's capabilities
    Then it receives the caller's inherited provider, model and modes
    And each provider instance with its models, options and whether it can run a child task and why not
    And that batches hold at most 20 threads
