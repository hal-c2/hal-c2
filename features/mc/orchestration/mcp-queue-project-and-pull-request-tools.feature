# Sources:
#   https://github.com/pingdotgg/t3code/pull/18143
#   https://github.com/pingdotgg/t3code/pull/2829
#   https://github.com/pingdotgg/t3code/pull/23899
#   https://github.com/pingdotgg/t3code/pull/22850
#   https://github.com/pingdotgg/t3code/pull/27994
#   https://github.com/pingdotgg/t3code/pull/27925
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
#   https://github.com/pingdotgg/t3code/pull/25561
Feature: Agents managing queues, projects, worktrees and pull requests through MCP
  Beyond threads themselves, an agent can manage queued messages, answer
  questions, register projects, move its own thread into a worktree and link
  pull requests.

  Background:
    Given an MC with a project "demo"
    And thread "caller" in "demo" runs in full-access mode with a turn running on "codex"
    And thread "t2" in "demo" has a turn running and two queued messages

  @mc
  Scenario: Listing a thread's queue in start order
    When the agent of "caller" lists the queue of "t2"
    Then it receives the two queued messages in the order they will start
    And each text is cut to 1,000 characters with a truncated flag

  @mc
  Scenario: Reading one queued message gives up to 16,000 characters
    When the agent of "caller" reads a queued message of "t2"
    Then it receives its text up to 16,000 characters

  @mc
  Scenario Outline: Changing a queued message
    When the agent of "caller" <change> a queued message of "t2"
    Then the queue of "t2" shows the change

    Examples:
      | change                          |
      | edits the text of               |
      | cancels                         |
      | moves before the other          |
      | promotes to a steer of the turn |

  @mc
  Scenario: A message that is no longer queued cannot be changed
    Given the first queued message of "t2" has started
    When the agent of "caller" cancels it
    Then it fails with code "invalid_request" and "The queued message was not found."

  @mc
  Scenario: Listing and reading pending questions
    Given the agent of "t2" asked the user a question and asked for an approval
    When the agent of "caller" lists the pending requests of "t2"
    Then only the question is listed
    And reading it returns its questions

  @mc
  Scenario: Answering another thread's question
    Given the agent of "t2" asked the user a question
    When the agent of "caller" answers it
    Then the turn of "t2" continues with the answer

  @mc
  Scenario: Agents cannot answer approvals
    Given the agent of "t2" asked for approval to run a command
    When the agent of "caller" responds to that request
    Then it fails with code "invalid_request" and "The pending user-input request was not found."

  # Upstream #22850: every request no longer pending was reported as not found.
  @backlog @mc
  Scenario Outline: Answering a question that is no longer pending says why
    Given the agent of "t2" asked the user a question
    And <state>
    When the agent of "caller" answers it
    Then it fails saying "<message>"

    Examples:
      | state                                | message                                                  |
      | the user already answered it          | The user-input request was already answered.             |
      | it expired                            | The user-input request is no longer pending (expired).   |
      | it was cancelled                      | The user-input request is no longer pending (cancelled). |

  @mc
  Scenario: Listing and reading projects
    When the agent of "caller" lists the projects
    Then it receives every project of this MC that is not deleted, paged
    And reading project "nowhere" fails with "The project was not found."

  # Legacy: apps/server/src/mcp/toolkits/project/tools.ts and handlers.ts (hal_c2_project_list)
  @mc
  Scenario Outline: A page of the project list holds 20 projects unless the agent asks for more
    Given this MC has 120 projects that are not deleted
    When the agent of "caller" lists the projects <asking>
    Then it receives <count> projects and a cursor for the rest

    Examples:
      | asking              | count |
      | without a limit     | 20    |
      | with a limit of 100 | 100   |

  @mc
  Scenario Outline: A page size outside 1 to 100 is refused
    When the agent of "caller" lists the projects with a limit of <limit>
    Then the tool refuses the input as invalid

    Examples:
      | limit |
      | 0     |
      | 101   |

  @mc
  Scenario: Creating a project
    When the agent of "caller" creates a project for an existing folder
    Then the project exists with the folder name as its title

  @mc
  Scenario: A folder can belong to only one project
    When the agent of "caller" creates a project for the folder of "demo"
    Then it fails with code "invalid_request" and "The workspace is already registered to a project."

  @mc
  Scenario: Updating a project
    When the agent of "caller" renames project "demo" to "Demo app"
    Then the project is called "Demo app"

  @mc
  Scenario: Deleting a project with threads needs force
    When the agent of "caller" deletes project "demo" without force
    Then it fails with code "invalid_request" and "The project is not empty; force=true is required to delete it."

  @mc
  Scenario: A forced project delete takes its threads with it
    Given project "scratch" has threads "s1" and "s2"
    When the agent of "caller" deletes project "scratch" with force
    Then "s1" and "s2" are deleted and project "scratch" is deleted

  @mc
  Scenario: Cloning a repository as a project
    When the agent of "caller" clones a repository
    # hal_c2_project_clone only clones, in both servers; registering is a hal_c2_project_create call.
    Then the repository is cloned and can be registered as a project

  @mc
  Scenario: Worktree status of a thread in the project root
    When the agent of "caller" asks for its worktree status
    Then it is not attached to a worktree
    And it receives the project's root and whether new worktrees start from origin

  @mc
  Scenario: Listing branches and worktrees
    When the agent of "caller" lists worktrees
    Then it receives the branches and worktrees of the caller's workspace

  @mc
  Scenario: Handing the caller off to a new worktree
    Given project "demo" has a setup script marked to run on new worktrees
    When the agent of "caller" hands off to a worktree on new branch "feature/x" with a continuation prompt
    Then a worktree is created on "feature/x" from origin's copy of the current branch
    And "caller" now works in that worktree on that branch
    And the setup script runs in the thread's "setup" terminal
    And the continuation prompt is queued to start after the current turn

  @mc
  Scenario: A handoff without a continuation prompt waits for the next message
    When the agent of "caller" hands off to a worktree without a continuation prompt
    Then the continuation is skipped
    And the note says the conversation continues in the worktree on the next message

  @mc
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

  @mc
  Scenario: A handoff that loses a race removes its worktree
    Given "caller" is moved to another worktree while the handoff creates one
    When the handoff tries to point "caller" at the new worktree
    Then the new worktree and its branch are removed again
    And the handoff fails with code "already_in_worktree"

  @mc
  Scenario Outline: Linking pull requests from an agent
    When the agent of "caller" links a pull request by <reference>
    Then the pull request is linked to "caller" as linked by an agent

    Examples:
      | reference                                       |
      | its URL                                         |
      | repository and number on the project's host     |
      | host, repository and number                     |

  # Upstream #23899: GitCafe's own address for a pull request is /pull/<n> (/pulls/<n> redirects
  # to it), and the link, unlink and watch tools refused the address a user copies.
  @backlog @mc @priority-low
  Scenario Outline: An agent links a GitCafe pull request by either of its addresses
    When the agent of "caller" links the pull request "<url>"
    Then pull request 42 of "team/shop" on "git.cafe" is linked to "caller"
    And the same address can be unlinked and watched

    Examples:
      | url                                       |
      | https://git.cafe/team/shop/pull/42        |
      | https://git.cafe/team/shop/pulls/42       |
      | https://staging.git.cafe/team/shop/pull/42/files |

  @mc
  Scenario: Linking a pull request that is already linked changes nothing
    Given "caller" links pull request 12
    When the agent of "caller" links pull request 12 again
    Then the answer says it was already linked

  @mc
  Scenario: Linking a pull request dismissed from a stack links it again
    Given pull request 12 was dismissed from the stack of "caller"
    When the agent of "caller" links pull request 12
    Then it is linked again

  @mc
  Scenario: Unlinking reports whether the pull request was linked
    When the agent of "caller" unlinks pull request 99 that is not linked
    Then the answer says it was not linked

  # Upstream #25561: unlinking a pull request dismissed from a stack answered that it had been linked.
  @backlog @mc
  Scenario: Unlinking a pull request dismissed from a stack says it was not linked
    Given pull request 12 was dismissed from the stack of "caller"
    When the agent of "caller" unlinks pull request 12
    Then the answer says it was not linked
    And the thread is not changed

  # Upstream #27994: one call links several pull requests to a thread.
  @backlog @mc
  Scenario: An agent links several pull requests in one call
    Given "caller" already links pull request 12
    When the agent of "caller" links pull requests 12, 13 and 14 and one address that is not a pull request in one call
    Then 13 and 14 are reported as linked, 12 as already linked and the address as invalid
    And the work log of "caller" says 2 pull requests were linked

  # Upstream #27925: one call unlinks every linked pull request in the given states.
  @backlog @mc
  Scenario: An agent unlinks every pull request in the given states in one call
    Given "caller" links merged pull request 10, closed pull request 11, open pull request 12 and pull request 13 that has never been synced
    When the agent of "caller" unlinks its pull requests that are merged or closed
    Then 10 and 11 are unlinked and 12 and 13 stay linked
    And the answer groups the unlinked pull requests by repository and state with their count
    And the work log of "caller" says 2 pull requests were unlinked

  @mc
  Scenario Outline: Pull request references that cannot be used
    When the agent of "caller" links <reference>
    Then it fails with code "invalid_request"

    Examples:
      | reference                                           |
      | a URL that is not a pull request                    |
      | only a repository                                   |
      | a repository and number in a project with no remote |

  @mc
  Scenario Outline: A pull request linked by number gets its URL in the host's own shape
    Given the project of "caller" is hosted on <host kind>
    When the agent of "caller" links pull request 42 of its repository by number
    Then the pull request is linked with the URL <url>

    Examples:
      | host kind                                         | url                                                      |
      | GitLab with a nested group                        | https://gitlab.com/group/sub/project/-/merge_requests/42 |
      | Forgejo served from a port and a path prefix      | http://forge.example:3000/git/owner/repo/pulls/42        |
      | GitHub                                            | https://github.com/owner/repo/pull/42                    |

  @mc
  Scenario: A pull request on another host than the project's gets a default URL
    Given the project of "caller" is hosted on GitLab
    When the agent of "caller" links pull request 42 of "owner/repo" on "other.example"
    Then the pull request is linked with the URL "https://other.example/owner/repo/pull/42"
    And the project's own host is not used to guess its shape

  @mc
  Scenario: A Forgejo link made without its port is listed with the port from its URL
    Given "caller" has a Forgejo pull request linked as host "forge.example" with the URL "http://forge.example:3000/hal-c2/hal-c2/pulls/42"
    When the agent of "caller" lists its pull requests
    Then the pull request is reported on host "forge.example:3000"

  @mc
  Scenario: Listing a thread's pull requests groups stacks
    Given "caller" has pull requests 10, 11 and 12 stacked on each other and 12 dismissed
    When the agent of "caller" lists its pull requests
    Then it receives 10 and 11 and the chain they form

  # Upstream #18143: agents asked to prepare review guides had no tool to call.
  @backlog @mc @priority-low
  Scenario Outline: An agent starts review guides for several pull requests at once
    Given "Review guides (beta)" is on
    And <situation>
    When the agent of "caller" asks for guides of pull request 42 of "owner/repo" and pull request 43 of "<repo>"
    Then it is told at once that the guide of 42 has started
    And that 43 <outcome>

    Examples:
      | situation                                                  | repo       | outcome                                                                  |
      | a guide of 43 at its head is already being written          | owner/repo | joined the guide already being written                                   |
      | no project in this environment checks out "other/repo"      | other/repo | failed because no project checks out its repository, pointing at adding one |

  @backlog @mc @priority-low
  Scenario: At most twenty pull requests are guided in one call
    When the agent of "caller" asks for guides of 21 pull requests
    Then the call is refused for asking for more than 20

  @backlog @mc @priority-low
  Scenario: Every guide an agent asks for is refused while review guides are off
    Given "Review guides (beta)" is off
    When the agent of "caller" asks for guides of pull requests 42 and 43
    Then each is refused, naming the "Review guides (beta)" setting

  @backlog @mc @priority-low
  Scenario: Reading a guide never starts one
    Given the guide of pull request 42 was written before its latest push
    When the agent of "caller" reads the guide of pull request 42
    Then it receives the guide, that no guide is being written and that a push left it stale
    And no guide is started

  # Writing a guide changes no thread, so it needs the pull requests permission, not
  # control of a thread.
  @backlog @mc @priority-low
  Scenario Outline: Who may ask for review guides
    Given the agent of "caller" <access>
    When it asks for a guide of pull request 42
    Then the request is <result>

    Examples:
      | access                                                    | result   |
      | may work with pull requests but not control threads       | accepted |
      | runs in read-only mode                                    | refused  |
      | belongs to a turn that has ended                          | refused  |

  @backlog @shared @priority-low
  Scenario: An agent's guide requests are named in the thread's work log
    When the agent of "caller" starts review guides and later reads one
    Then the work log reads "Started review guides" and "Read a review guide"
