# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829 (upstream orchestrator behavior)
#   apps/server-ex/lib/hal_c2/mcp/tools/queue.ex (hal_c2_queue_list, hal_c2_queue_read, hal_c2_queue_edit,
#     hal_c2_queue_cancel, hal_c2_queue_reorder, hal_c2_queue_promote_to_steer, hal_c2_pending_request_list,
#     hal_c2_pending_request_read, hal_c2_pending_request_respond)
#   apps/server-ex/lib/hal_c2/mcp/tools/projects.ex (hal_c2_project_create, hal_c2_project_update,
#     hal_c2_project_delete, hal_c2_project_clone, hal_c2_worktree_list, hal_c2_worktree_status,
#     hal_c2_worktree_handoff)
#   apps/server-ex/lib/hal_c2/mcp/tools.ex (hal_c2_project_list, hal_c2_project_read)
#   apps/server-ex/lib/hal_c2/mcp/tools/pull_requests.ex (link_pull_request,
#     unlink_pull_request, list_thread_pull_requests)
#   V2 commands issued: queued-run.edit, queued-run.cancel, queued-run.reorder,
#     queued-message.promote-to-steer, runtime-request.respond, thread.delete,
#     thread.metadata.update, message.dispatch (queue_after_active),
#     thread.pull-request.link, thread.pull-request.unlink
#   apps/server/src/mcp/toolkits/orchestrator, project, worktree, pullRequests
Feature: Agents managing queues, projects, worktrees and pull requests through MCP
  Beyond threads themselves, an agent can manage queued messages, answer
  questions, register projects, move its own thread into a worktree and link
  pull requests.

  Background:
    Given a node with a project "demo"
    And thread "caller" in "demo" runs in full-access mode with a turn running on "codex"
    And thread "t2" in "demo" has a turn running and two queued messages

  @node
  Scenario: Listing a thread's queue in start order
    When the agent of "caller" lists the queue of "t2"
    Then it receives the two queued messages in the order they will start
    And each text is cut to 1,000 characters with a truncated flag

  @node
  Scenario: Reading one queued message gives up to 16,000 characters
    When the agent of "caller" reads a queued message of "t2"
    Then it receives its text up to 16,000 characters

  @node
  Scenario Outline: Changing a queued message
    When the agent of "caller" <change> a queued message of "t2"
    Then the queue of "t2" shows the change

    Examples:
      | change                          |
      | edits the text of               |
      | cancels                         |
      | moves before the other          |
      | promotes to a steer of the turn |

  @node
  Scenario: A message that is no longer queued cannot be changed
    Given the first queued message of "t2" has started
    When the agent of "caller" cancels it
    Then it fails with code "invalid_request" and "The queued message was not found."

  @node
  Scenario: Listing and reading pending questions
    Given the agent of "t2" asked the user a question and asked for an approval
    When the agent of "caller" lists the pending requests of "t2"
    Then only the question is listed
    And reading it returns its questions

  @node
  Scenario: Answering another thread's question
    Given the agent of "t2" asked the user a question
    When the agent of "caller" answers it
    Then the turn of "t2" continues with the answer

  @node
  Scenario: Agents cannot answer approvals
    Given the agent of "t2" asked for approval to run a command
    When the agent of "caller" responds to that request
    Then it fails with code "invalid_request" and "The pending user-input request was not found."

  @node
  Scenario: Listing and reading projects
    When the agent of "caller" lists the projects
    Then it receives every project of this node that is not deleted, paged
    And reading project "nowhere" fails with "The project was not found."

  @node
  Scenario: Creating a project
    When the agent of "caller" creates a project for an existing folder
    Then the project exists with the folder name as its title

  @node
  Scenario: A folder can belong to only one project
    When the agent of "caller" creates a project for the folder of "demo"
    Then it fails with code "invalid_request" and "The workspace is already registered to a project."

  @node
  Scenario: Updating a project
    When the agent of "caller" renames project "demo" to "Demo app"
    Then the project is called "Demo app"

  @node
  Scenario: Deleting a project with threads needs force
    When the agent of "caller" deletes project "demo" without force
    Then it fails with code "invalid_request" and "The project is not empty; force=true is required to delete it."

  @node
  Scenario: A forced project delete takes its threads with it
    Given project "scratch" has threads "s1" and "s2"
    When the agent of "caller" deletes project "scratch" with force
    Then "s1" and "s2" are deleted and project "scratch" is deleted

  @node
  Scenario: Cloning a repository as a project
    When the agent of "caller" clones a repository
    # hal_c2_project_clone only clones, in both servers; registering is a hal_c2_project_create call.
    Then the repository is cloned and can be registered as a project

  @node
  Scenario: Worktree status of a thread in the project root
    When the agent of "caller" asks for its worktree status
    Then it is not attached to a worktree
    And it receives the project's root and whether new worktrees start from origin

  @node
  Scenario: Listing branches and worktrees
    When the agent of "caller" lists worktrees
    Then it receives the branches and worktrees of the caller's workspace

  @node
  Scenario: Handing the caller off to a new worktree
    Given project "demo" has a setup script marked to run on new worktrees
    When the agent of "caller" hands off to a worktree on new branch "feature/x" with a continuation prompt
    Then a worktree is created on "feature/x" from origin's copy of the current branch
    And "caller" now works in that worktree on that branch
    And the setup script runs in the thread's "setup" terminal
    And the continuation prompt is queued to start after the current turn

  @node
  Scenario: A handoff without a continuation prompt waits for the next message
    When the agent of "caller" hands off to a worktree without a continuation prompt
    Then the continuation is skipped
    And the note says the conversation continues in the worktree on the next message

  @node
  Scenario Outline: Handoffs that are refused
    Given <situation>
    When the agent of "caller" hands off to a worktree on new branch "feature/x"
    Then it fails with code "<code>"

    Examples:
      | situation                                          | code                |
      | "caller" already works in a worktree               | already_in_worktree |
      | "caller" is archived                               | invalid_request     |
      | the requested path is relative                     | invalid_request     |
      | the project folder is not a git repository          | invalid_request     |
      | branch "feature/x" already exists                  | invalid_request     |
      | the project checkout is on a detached HEAD and no base is given | invalid_request |
      | origin cannot be fetched                           | operation_failed    |

  @node
  Scenario: A handoff that loses a race removes its worktree
    Given "caller" is moved to another worktree while the handoff creates one
    When the handoff tries to point "caller" at the new worktree
    Then the new worktree and its branch are removed again
    And the handoff fails with code "already_in_worktree"

  @node
  Scenario Outline: Linking pull requests from an agent
    When the agent of "caller" links a pull request by <reference>
    Then the pull request is linked to "caller" as linked by an agent

    Examples:
      | reference                                       |
      | its URL                                         |
      | repository and number on the project's host     |
      | host, repository and number                     |

  @node
  Scenario: Linking a pull request that is already linked changes nothing
    Given "caller" links pull request 12
    When the agent of "caller" links pull request 12 again
    Then the answer says it was already linked

  @node
  Scenario: Linking a pull request dismissed from a stack links it again
    Given pull request 12 was dismissed from the stack of "caller"
    When the agent of "caller" links pull request 12
    Then it is linked again

  @node
  Scenario: Unlinking reports whether the pull request was linked
    When the agent of "caller" unlinks pull request 99 that is not linked
    Then the answer says it was not linked

  @node
  Scenario Outline: Pull request references that cannot be used
    When the agent of "caller" links <reference>
    Then it fails with code "invalid_request"

    Examples:
      | reference                                           |
      | a URL that is not a pull request                    |
      | only a repository                                   |
      | a repository and number in a project with no remote |

  @node
  Scenario: Listing a thread's pull requests groups stacks
    Given "caller" has pull requests 10, 11 and 12 stacked on each other and 12 dismissed
    When the agent of "caller" lists its pull requests
    Then it receives 10 and 11 and the chain they form
