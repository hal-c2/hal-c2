# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/user/cursor.md (including Replay And Live Testing, dropped)
#   apps/server-ex/lib/hal_c2/acp.ex (cursor agent: MC + cursor-acp, HAL_C2_CURSOR_CREDENTIALS, --mode)
#   apps/server-ex/lib/hal_c2/acp/auth.ex, apps/server-ex/lib/hal_c2/acp/url_auth.ex (server.acceptAcpRegistryUrlAuth)
#   apps/server-ex/lib/hal_c2/provider_auth.ex (provider.auth.start, provider.auth.cancel, provider.auth.logout)
#   packages/cursor-acp/src/agent.ts, packages/cursor-acp/src/main.ts
#   apps/server-ex/lib/hal_c2/acp/thread_runtime.ex (open items close with the turn)
#   apps/server/src/provider/Layers/CursorProvider.ts, apps/server/src/provider/CursorAuth.ts, apps/server/src/provider/CursorCredentialStore.ts
#   apps/server/src/provider/Layers/CursorSdkCatalog.ts, apps/server/src/provider/cursorSdkModel.ts
#   apps/server/src/orchestration-v2/Adapters/CursorAdapterV2.ts
#   apps/server/src/orchestration-v2/Adapters/CursorAgentSdk.ts (what the protocol log leaves out)
#   apps/server/src/provider/Drivers/CursorDriver.ts, apps/server/src/provider/Drivers/CursorSkills.ts (skill folders and limits)
#   apps/server/src/provider/acp/CursorTransportFailure.ts (a reply that is only a connection error)
#   apps/server/src/provider/Layers/cursorUsageLimits.ts

@plugin-cursor @mc
Feature: Cursor
  Cursor runs through the Cursor SDK behind a small ACP agent that ships with the MC.
  There is no Cursor binary to install. The user signs in with a Cursor account in the
  browser, or sets an API key for the instance.

  Background:
    Given a connected environment with the project "shop"

  Scenario: Cursor does nothing until the user enables it
    Given Cursor is not enabled on the MC
    When the MC starts
    Then no Cursor process is started

  Scenario: Enabling Cursor lists its models
    Given the user is signed in to Cursor
    When the user enables Cursor
    Then the Cursor models are offered in the model picker

  Scenario: Signing in to Cursor opens the Cursor sign-in page
    Given Cursor is enabled and signed out
    When the user signs in to Cursor
    Then every client of the MC is offered the Cursor sign-in page
    And Cursor is signed in once the user finishes on the website

  # Both servers end a sign-in after five minutes (ProviderAuth, CursorAuth AUTH_TIMEOUT_MS).
  Scenario: The Cursor sign-in request expires if nobody answers it
    Given Cursor is waiting for the user to open its sign-in page
    When five minutes pass without an answer
    Then the sign-in request is declined
    And the user can start sign-in again

  # Health states of CursorProvider.ts checkCursorProviderStatus.
  @backlog
  Scenario Outline: Cursor's health states are explained
    Given <situation>
    When the user opens the provider list
    Then Cursor is shown with the message "<message>"

    Examples:
      | situation                                                 | message                                                                     |
      | Cursor is turned off in the provider settings             | Cursor is disabled in HAL-C2 settings.                                      |
      | the MC is still looking for Cursor                        | Checking Cursor SDK availability...                                         |
      | Cursor has neither a sign-in nor a CURSOR_API_KEY         | Sign in with Cursor or add CURSOR_API_KEY in provider settings.             |
      | a browser sign-in was rejected by Cursor                  | Cursor sign-in expired or was rejected. Sign in again in provider settings. |
      | the CURSOR_API_KEY was rejected by Cursor                 | Cursor SDK authentication failed. Check CURSOR_API_KEY.                     |
      | the Cursor model catalog request fails for another reason | Cursor SDK catalog request failed. Check server logs for details.           |

  @backlog
  Scenario: A Cursor model catalog request that does not finish is reported
    Given the user has a CURSOR_API_KEY
    And the Cursor model catalog request does not finish in time
    When the user opens the provider list
    Then Cursor is shown as unavailable with a message that the catalog request timed out

  Scenario: Cancelling Cursor sign-in leaves Cursor signed out
    Given Cursor sign-in is in progress
    When the user cancels sign-in
    Then Cursor stays signed out

  Scenario: Signing out of Cursor
    Given the user is signed in to Cursor
    When the user signs out of Cursor
    Then Cursor is shown as signed out

  Scenario: Each Cursor instance keeps its own sign-in
    Given two Cursor instances "work" and "personal"
    When the user signs in to "work"
    Then "personal" stays signed out

  Scenario: An API key in the instance's environment is used instead of sign-in
    Given the Cursor instance has a Cursor API key in its environment
    When the user sends a message to Cursor
    Then the turn runs with that API key
    And no browser sign-in is offered

  Scenario: A Cursor turn follows the thread's access mode
    Given the thread runs Cursor with approval required
    When the user sends a message
    Then Cursor runs with its review and sandbox turned on

  Scenario: Cursor writes thread titles and commit messages
    Given Cursor is picked for text generation
    When a new thread needs a title
    Then Cursor writes the title without using any tools

  Scenario Outline: Cursor's access modes map to Cursor's own safety settings
    Given the thread runs Cursor in <mode>
    Then Cursor's review is <review> and its sandbox is <sandbox>

    Examples:
      | mode              | review | sandbox |
      | approval required | on     | on      |
      | auto-accept edits | off    | on      |
      | auto              | off    | on      |
      | full access       | off    | off     |

  Scenario: A Cursor sign-in that takes too long expires
    Given Cursor sign-in has been waiting for five minutes
    When the time runs out
    Then the user is told Cursor sign-in expired and to start again

  Scenario: Browser sign-in is refused while an API key is set
    Given the Cursor instance has a Cursor API key in its environment
    When the user tries to sign in with the browser
    Then the user is told to remove the API key first

  Scenario: An expired Cursor sign-in is explained
    Given the Cursor sign-in was revoked
    When the user opens the provider list
    Then Cursor says the sign-in expired and to sign in again

  Scenario: Cursor model options come from the Cursor catalog
    When the user opens the options for a Cursor model
    Then the reasoning, context size, fast mode and thinking choices Cursor offers for that model are shown

  Scenario: An empty Cursor catalog is a warning
    Given Cursor returns no models
    When the user opens the provider list
    Then Cursor is shown with a warning that no models were found

  Scenario: Cursor's plan and task list are shown
    Given the thread is in plan mode on Cursor
    When Cursor finishes planning
    Then the plan is shown as a proposed plan with its task list

  Scenario: Cursor's monthly allowance is shown in the limits view
    Given Cursor is signed in with a file-based login
    When the user opens the limits view
    Then Cursor shows its monthly, Auto and API usage with the billing cycle end

  Scenario: Cursor usage is unavailable with a keychain login
    Given Cursor is signed in through the system keychain
    When the user opens the limits view
    Then Cursor says usage needs a file-based login

  Scenario: Cursor skills can be mentioned in the composer
    Given the project has the Cursor skill "deploy"
    When the user mentions "deploy" in a message
    Then Cursor receives the skill reference

  @backlog
  Scenario: Credentials from an older Cursor login move to the MC's secrets once
    Given an older Cursor login file exists
    When Cursor starts for the first time on this version
    Then the login moves into the MC's secrets and the old file is removed

  @dropped
  Scenario: Cursor turns can be recorded and replayed against the SDK boundary
    Given a recorded Cursor replay fixture
    When the MC's tests replay it
    Then the thread receives the recorded updates, results and cancellation in order
    # docs/user/cursor.md "Replay And Live Testing" is contributor tooling for the TypeScript
    # adapter (record:cursor-replay), not product behaviour; the MC does not carry it.

  # Cursor's SDK says nothing once a run finishes, and nothing Cursor starts outlives it.
  Scenario: A command Cursor leaves running ends with its turn
    When Cursor ends a turn with a command still running
    Then the command it left running ends with the turn

  Scenario: A Cursor command the user stops shows as interrupted
    Given Cursor is running a command
    When the user stops the turn
    Then the command is shown as interrupted
    And it is not shown as a successful command

  Scenario: A full-access Cursor thread does not loosen a sandboxed one
    Given a Cursor thread runs in a sandbox and another Cursor thread runs in full access
    When the full-access thread runs and then the sandboxed thread runs again
    Then the sandboxed thread still runs in its sandbox
    And its tools still work

  @backlog
  Scenario: Cursor text generation that its sandbox blocks is retried without the sandbox
    Given Cursor is picked for text generation
    And generating a title fails only because Cursor's sandbox blocks it
    When the MC retries the request
    Then the retry removes only the restriction that blocked it
    And the thread gets its title

  @backlog
  Scenario: Cursor keeps its metadata out of the workspace
    Given a Cursor thread in a project folder
    When a Cursor turn runs
    Then the project folder gains no files generated for Cursor

  Scenario: Cursor receives the project's skills and rules
    Given the project has skills and rules for Cursor
    When a Cursor turn starts in the project
    Then Cursor receives the project's skills and rules

  Scenario: A Cursor shell command that fails to start does not stop the turn
    Given Cursor is running a turn
    When a shell command Cursor tries fails to start
    Then the turn keeps going
    And the command is shown as failed

  Scenario: A Cursor send whose run was abandoned is ended
    Given a message was sent to Cursor but the MC kept only its local run record and no live Cursor session
    When the MC checks its Cursor sessions
    Then the send is completed or failed explicitly
    And the user's next message starts a new Cursor run

  @backlog
  Scenario Outline: Cursor skills are read from every skill folder Cursor reads
    Given a skill "deploy" in <folder> of the project or of the user's home
    When the user opens the skill list in a Cursor thread
    Then "deploy" is offered

    Examples:
      | folder         |
      | .cursor/skills |
      | .agents/skills |
      | .codex/skills  |
      | .claude/skills |

  @backlog
  Scenario: A project's Cursor skill wins over the user's skill of the same name
    Given the skill "deploy" exists in the project and in the user's home
    When the user opens the skill list in a Cursor thread
    Then "deploy" is offered once, from the project

  @backlog
  Scenario: A skill that is not meant for the Cursor CLI is not offered
    Given the project has a Cursor skill whose header limits it to surfaces other than the CLI
    When the user opens the skill list in a Cursor thread
    Then that skill is not offered

  @backlog
  Scenario: A Cursor skill only the user may run is marked so
    Given the project has a Cursor skill whose header forbids the model from starting it
    When the user opens the skill list in a Cursor thread
    Then the skill is offered as one only the user can run

  @backlog
  Scenario Outline: A Cursor skill search that cannot finish is reported, not cut short
    Given <situation>
    When the MC reads the Cursor skills
    Then reading fails saying skill discovery was incomplete because of <reason>

    Examples:
      | situation                                                              | reason                |
      | the skill folders hold more than 10,000 entries or 8 MB of skill files | scan-budget-exhausted |
      | the skill folders are nested more than ten levels deep                 | scan-budget-exhausted |
      | a skill folder cannot be read                                          | filesystem-error      |

  @backlog
  Scenario: Only a known Cursor skill is turned into a skill reference
    Given the project has the Cursor skill "deploy"
    When the user sends "run $deploy with $HOME set" to Cursor
    Then "deploy" reaches Cursor as a skill reference
    And "$HOME" reaches Cursor as typed

  @backlog
  Scenario Outline: A Cursor sign-in that cannot be checked is explained
    Given <problem>
    When the MC checks Cursor
    Then the user is told "<message>"

    Examples:
      | problem                                         | message                                         |
      | the MC cannot open its store of Cursor logins   | Could not open the Cursor credential store.     |
      | Cursor cannot confirm the saved sign-in         | Could not verify the Cursor sign-in. Try again. |

  @backlog
  Scenario: A Cursor reply that is only a connection error fails the turn
    Given a Cursor turn is running
    When Cursor's whole reply is a connection error such as "Something went wrong communicating with the server. Please try again."
    Then the turn fails as a connection problem instead of showing the error as Cursor's answer

  @backlog
  Scenario: An answer that quotes a connection error is still an answer
    Given the user asked Cursor what a connection error means
    When Cursor answers and its answer quotes the error text
    Then the turn completes with that answer

  # CursorAdapterV2.ts: what the Cursor SDK's run stream becomes in the thread.
  @backlog
  Scenario: Compacting a Cursor thread uses Cursor's own compress command
    Given a Cursor thread with history
    When the user compacts the thread
    Then Cursor receives "/compress" as its whole message
    And nothing is added to it

  @backlog
  Scenario Outline: Cursor's tool calls are shown by kind
    When Cursor <does>
    Then the thread shows <shown>

    Examples:
      | does                               | shown                                   |
      | runs a shell command               | a command with its output and exit code |
      | writes, edits or deletes a file    | a file change naming the file           |
      | generates an image                 | a file change naming the image file     |
      | reads a file or lists a folder     | a file search                           |
      | searches by name, text or meaning  | a file search with what it looked for   |
      | reads the lint problems of a file  | a file search                           |

  @backlog
  Scenario: A Cursor MCP tool call is named after its server and tool
    When Cursor calls the tool "search" of the MCP server "docs"
    Then the thread shows the tool call as "mcp__docs__search"
    And a result the server marks as an error shows the call as failed

  @backlog
  Scenario: A Cursor command shows its output while it runs
    Given Cursor is running a long shell command
    When the command prints output before it finishes
    Then the output appears in the thread while the command is still running

  @backlog
  Scenario: A Cursor edit shows its diff and line counts
    When Cursor edits a file
    Then the file change shows the diff
    And it shows how many lines were added and removed

  @backlog
  Scenario: A folder Cursor lists shows every file under it
    When Cursor lists a folder with nested folders
    Then every file under it is listed with its path

  @backlog
  Scenario: Lint problems Cursor reads are listed with their position
    When Cursor reads the lint problems of a file
    Then each problem is listed with its message, line and column

  @backlog
  Scenario: A Cursor subagent runs in its own child thread
    When Cursor hands a task to one of its subagents
    Then a child thread opens with the task as its first message
    And the subagent's tool calls appear in the child thread
    And the subagent's result is shown when it finishes

  @backlog
  Scenario Outline: A Cursor subagent that never reported back takes the run's outcome
    Given a Cursor subagent is still working
    When the Cursor run <ends> without the subagent reporting a result
    Then the subagent is shown as <status>

    Examples:
      | ends                   | status      |
      | finishes               | idle        |
      | is cancelled           | cancelled   |
      | fails                  | failed      |
      | is stopped by the user | interrupted |

  @backlog
  Scenario: Cancelled and empty Cursor to-dos are left out of the task list
    When Cursor updates its to-do list with a cancelled item and an item with no text
    Then neither item appears in the task list

  @backlog
  Scenario: A Cursor answer that arrives only with the run's result is still shown
    Given Cursor streamed no text during a run
    When the run finishes with a result text
    Then the result text is shown as Cursor's answer

  @backlog
  Scenario: Images attached to a Cursor message are sent as images
    When the user sends a Cursor message with a screenshot attached
    Then Cursor receives the screenshot as an image with the message

  @backlog
  Scenario: Stopping a Cursor turn does not wait on Cursor for more than 10 seconds
    Given a Cursor turn is running
    When the user stops it and Cursor does not confirm the cancellation within 10 seconds
    Then the turn ends as interrupted anyway

  @backlog
  Scenario Outline: What the Cursor SDK cannot do is refused with a reason
    Given a Cursor thread
    When <request>
    Then it is refused with "<reason>"

    Examples:
      | request                                  | reason                                                          |
      | an approval answer is sent to Cursor     | Cursor Agent SDK does not expose interactive approval requests. |
      | the thread is rewound to an earlier turn | Cursor Agent SDK does not expose conversation rollback.         |
      | the thread is forked                     | Cursor Agent SDK does not expose native agent forks.            |

  # CursorAgentSdk.ts: the protocol log keeps the shape of what was sent, not its secrets.
  @backlog
  Scenario: Cursor is offered the HAL-C2 tools without the credential reaching the logs
    Given protocol logging is on
    When a Cursor turn starts in a thread that has the HAL-C2 tools
    Then Cursor is offered them as the MCP server "hal-c2"
    And the protocol log records the model and mode of the run
    And it holds neither the Cursor API key nor the HAL-C2 tools credential

  # CursorSkills.ts: the corners of reading Cursor's skill folders.
  @backlog
  Scenario: Cursor skills kept in sub-folders of a skill folder are found
    Given the project keeps the skill "deploy" in "team/release/deploy" under ".cursor/skills"
    When the user opens the skill list in a Cursor thread
    Then "deploy" is offered

  @backlog
  Scenario: A Cursor skill is known by its folder and shown by the name in its header
    Given the project has a Cursor skill in the folder "deploy" whose header names it "Ship it"
    When the user opens the skill list in a Cursor thread
    Then the skill is shown as "Ship it"
    And the user mentions it as "deploy"

  @backlog
  Scenario: A Cursor skill linked from outside its skill folder is offered without searching where it lives
    Given ".cursor/skills" holds a link "shared" to a skill kept elsewhere on the machine
    And that skill's own folder holds further skills below it
    When the user opens the skill list in a Cursor thread
    Then "shared" is offered
    And the skills below it are not searched for

  @backlog
  Scenario: A Cursor skill whose header cannot be read is not offered
    Given the project has a Cursor skill whose header is not valid
    When the user opens the skill list in a Cursor thread
    Then that skill is not offered
    And the other skills are still offered

  @backlog
  Scenario: A Cursor skill file larger than 1 MB is offered without its description
    Given the project has a Cursor skill "manual" whose skill file is larger than 1 MB
    When the user opens the skill list in a Cursor thread
    Then "manual" is offered under its folder's name with no description

  @backlog
  Scenario: A Cursor skill the user may not start is listed as unavailable to them
    Given the project has a Cursor skill whose header says the user cannot start it
    When the user opens the skill list in a Cursor thread
    Then the skill is listed as one the user cannot start
