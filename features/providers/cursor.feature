# Sources:
#   https://github.com/pingdotgg/t3code/pull/27703
#   https://github.com/pingdotgg/t3code/pull/23326
#   https://github.com/pingdotgg/t3code/pull/24639
#   https://github.com/pingdotgg/t3code/pull/24702
#   https://github.com/pingdotgg/t3code/pull/26065
#   https://github.com/pingdotgg/t3code/pull/26592
#   https://github.com/pingdotgg/t3code/pull/21448
#   https://github.com/pingdotgg/t3code/pull/27143
#   https://github.com/pingdotgg/t3code/pull/24231
#   https://github.com/pingdotgg/t3code/pull/24595
#   https://github.com/pingdotgg/t3code/pull/23273
#   https://github.com/pingdotgg/t3code/pull/20046
#   https://github.com/pingdotgg/t3code/pull/19806
#   https://github.com/pingdotgg/t3code/pull/19678
#   https://github.com/pingdotgg/t3code/pull/18664
#   https://github.com/pingdotgg/t3code/pull/16146
#   https://github.com/pingdotgg/t3code/pull/17462
#   https://github.com/pingdotgg/t3code/pull/17419
#   https://github.com/pingdotgg/t3code/pull/19771
#   https://github.com/pingdotgg/t3code/pull/17389
#   https://github.com/pingdotgg/t3code/pull/19712
#   https://github.com/pingdotgg/t3code/pull/15875
#   https://github.com/pingdotgg/t3code/pull/13820
#   https://github.com/pingdotgg/t3code/pull/13870
#   https://github.com/pingdotgg/t3code/pull/13714
#   https://github.com/pingdotgg/t3code/pull/10409
#   https://github.com/pingdotgg/t3code/pull/2829
#   https://github.com/pingdotgg/t3code/pull/13328 (Cursor build-date ranges, dropped below)
#   https://github.com/pingdotgg/t3code/pull/22897
#   https://github.com/pingdotgg/t3code/pull/21074
#   https://github.com/pingdotgg/t3code/pull/29398
#   https://github.com/pingdotgg/t3code/pull/29419
#   https://github.com/pingdotgg/t3code/pull/29748
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

  # Cursor runs through the Cursor SDK with no binary to install (see the header), so no
  # installed version exists for a compatibility range to judge. Revisit if the SDK reports one.
  @dropped
  Scenario: Cursor's build date is judged against a compatibility range
    Given Cursor reports the build "2026.05.08"
    When the MC checks its providers
    Then Cursor is reported as a known broken version for this HAL-C2 release

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

  # Upstream #24702: a sign-in whose account had no email was refused as "Could not save the Cursor sign-in."
  Scenario: A Cursor account without an email still signs in
    Given Cursor is enabled and signed out
    And the user's Cursor account reports no email
    When the user signs in to Cursor and finishes on the website
    Then Cursor is signed in
    And the user is not told the sign-in could not be saved

  # Both servers end a sign-in after five minutes (ProviderAuth, CursorAuth AUTH_TIMEOUT_MS).
  Scenario: The Cursor sign-in request expires if nobody answers it
    Given Cursor is waiting for the user to open its sign-in page
    When five minutes pass without an answer
    Then the sign-in request is declined
    And the user can start sign-in again

  # Health states of CursorProvider.ts checkCursorProviderStatus.
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

  # Upstream #19771: a free-plan Cursor account is told a paid plan is needed; its credentials are discarded.
  @shared @backlog-desktop @backlog-mobile @backlog-tui
  Scenario: A free-plan Cursor account is told it needs a paid plan
    Given the user signs in to Cursor with a free-plan account
    When Cursor rejects the account
    Then Cursor's status and the sign-in say a paid Cursor plan is needed
    And the rejected sign-in is not kept

  # Upstream #24639: Enterprise teams can block Cursor's account endpoint while models and local
  # runs still work; the blocked read failed the whole status check.
  @priority-low
  Scenario: Cursor is ready when the team blocks reading the account
    Given the user's Cursor team has turned off the account details endpoint
    When the user opens the provider list
    Then Cursor is ready with its models
    And the account shows as "Cursor account" or "Cursor API key" without an email
    And a rejected sign-in or key still fails as an authentication error

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

  # Upstream #29748: a Cursor text generation stopped by a usage limit failed with only "Cursor SDK
  # request finished with an error."
  Scenario: Cursor text generation stopped by a usage limit says so
    Given Cursor is picked for text generation
    And the user has reached a Cursor usage limit
    When a commit message is generated
    Then the failure says the Cursor usage limit was reached
    And it says to try again later or choose another text-generation provider

  Scenario Outline: Cursor's access modes map to Cursor's own safety settings
    Given the thread runs Cursor in <mode>
    Then Cursor's review is <review> and its sandbox is <sandbox>

    # Upstream #19712: auto turns Cursor's review on too, so escalations are
    # reviewed instead of denied.
    Examples:
      | mode              | review | sandbox |
      | approval required | on     | on      |
      | auto-accept edits | off    | on      |
      | auto              | on     | on      |
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

  # Upstream #17462: Cursor handoffs used a 128K fallback whatever window the model ran with; the
  # chosen window, or the catalog's default for the model, now sets the budget.
  @backlog
  Scenario Outline: A handoff to Cursor is budgeted by the context window the model runs with
    Given "t1" is switched to a Cursor model whose catalog default context window is 1,000,000 tokens
    And <chosen>
    When the conversation is handed over with a new message
    Then the history is budgeted against <window>

    Examples:
      | chosen                                  | window           |
      | the user chose the 500,000 token window | 500,000 tokens   |
      | the user chose no window                | 1,000,000 tokens |

  # Upstream #21074: Cursor rejected its long-context variants ("Invalid parameters for registry
  # model") because the request never asked for Max Mode.
  @priority-high
  Scenario: A Cursor model variant that only runs in Max Mode runs
    Given Cursor's catalog marks every variant of a model with a long context as Max Mode
    When the user sends a message on that model with the long context, in a new thread or an existing one
    Then the turn runs in Max Mode instead of failing with "Invalid parameters"

  # Upstream #19678: a model the account's catalog rejects is explained
  Scenario: A model the Cursor account does not offer says so
    Given a Cursor thread set to a model the account's catalog does not include
    When the turn fails because Cursor rejects the model
    Then the user is told the model must be one the Cursor account offers
    And the error does not suggest trying again

  Scenario: An empty Cursor catalog is a warning
    Given Cursor returns no models
    When the user opens the provider list
    Then Cursor is shown with a warning that no models were found

  # Upstream #29398: "/compact" reached Cursor's model as plain text, which either did not know it or
  # replied with a summary, and the context stayed the same size.
  Scenario: Sending /compact compacts the Cursor conversation
    Given a Cursor thread with a long conversation
    When the user sends "/compact" to the Cursor thread
    Then the thread shows that its context was compacted
    And Cursor's summary is not shown as a reply in the chat
    And Cursor still knows what the conversation covered

  Scenario: Cursor's plan and task list are shown
    Given the thread is in plan mode on Cursor
    When Cursor finishes planning
    Then the plan is shown as a proposed plan with its task list

  Scenario: Cursor's monthly allowance is shown in the limits view
    Given Cursor is signed in with a file-based login
    When the user opens the limits view
    Then Cursor shows its monthly, Auto and API usage with the billing cycle end

  # Upstream #29419: a Cursor sign-in from HAL-C2 or a CURSOR_API_KEY showed Cursor as signed in
  # but no limits and no history; only a Cursor CLI login could be read.
  @backlog
  Scenario Outline: Cursor usage shows for an account signed in with <credential>
    Given the user signed in to Cursor with <credential> and has no Cursor CLI login
    When the user opens the limits view and the usage history
    Then Cursor shows its monthly allowance
    And Cursor's usage history lists its requests
    And the user is not asked to allow access to a Cursor CLI login

    Examples:
      | credential                                  |
      | Sign in with Cursor                         |
      | a CURSOR_API_KEY in the instance's environment |

  Scenario: Cursor usage is unavailable with a keychain login
    Given Cursor is signed in through the system keychain
    When the user opens the limits view
    Then Cursor says usage needs a file-based login

  # Upstream #10409: the keychain is read for Cursor usage only after the user opts in. Replaces
  # the scenario above once the MC carries it.
  @backlog @priority-low
  Scenario: Cursor usage through a keychain login waits until the user enables it
    Given Cursor is signed in through the system keychain
    When the user opens the limits view
    Then Cursor does not read the keychain
    And the user is offered to enable Cursor account usage

  # Upstream #13714: the keychain read is offered only where the Cursor provider is ready, so a
  # machine without a working Cursor sees no prompt.
  @backlog @shared @plugin-cursor @priority-low
  Scenario: The Cursor keychain prompt is offered only where Cursor is ready
    Given Cursor is not set up in this environment
    When the user opens the limits view
    Then Cursor's keychain prompt is not offered

  # Upstream #13820: a missing login is not a login problem; only an unreadable saved login is.
  @backlog @priority-low
  Scenario: Cursor usage names no login problem when none is saved
    Given Cursor has no saved login
    When the user opens the limits view
    Then Cursor shows no login warning

  # Upstream #27143: a Keychain token left behind by an old Cursor install was read and its 401
  # shown as "Sign in to Cursor again" to users who no longer have Cursor.
  @backlog @priority-low
  Scenario: A keychain login left by a removed Cursor install is ignored
    Given the user turned on Cursor account usage
    And the system keychain still holds a login from a Cursor install that was removed
    When the user opens the limits view
    Then the keychain is not read for Cursor
    And Cursor shows no login warning

  # Upstream #13870: once one environment reports Cursor account usage, another environment's
  # keychain is not read to report the same account again.
  @backlog @priority-low
  Scenario: The Cursor keychain is not read again for an environment that already reports the account
    Given one selected environment already reports Cursor account usage
    And another selected environment has Cursor signed in through the system keychain
    When the user opens the limits view
    Then the keychain of the other environment is not read

  # Upstream #13870: a keychain request nobody answers times out and says how to allow it.
  @backlog @priority-low
  Scenario: An unanswered Cursor keychain request times out with guidance
    Given Cursor is signed in through the system keychain
    And the keychain request is not answered
    When the request times out
    Then the user is told to allow keychain access and refresh

  Scenario: Cursor skills can be mentioned in the composer
    Given the project has the Cursor skill "deploy"
    When the user mentions "deploy" in a message
    Then Cursor receives the skill reference

  @priority-low
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

  # Upstream #21448: a read Cursor never reported back was closed as a successful read with no
  # output when the run finished normally, while the reply said the read failed.
  @priority-high
  Scenario: A tool call Cursor never finished is not shown as a success
    Given Cursor starts reading "secret.txt" and never reports a result for it
    When the Cursor run finishes normally
    Then the read of "secret.txt" is shown as interrupted
    And it stays visible in the timeline

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

  # Upstream #20046: Cursor's SDK has no sandbox on Windows, so default threads failed to start.
  Scenario Outline: A Cursor thread on a Windows MC runs without Cursor's default sandbox
    Given the MC runs on Windows
    When a Cursor thread in <mode> starts its first turn
    Then the turn runs without Cursor's sandbox
    And the thread warns that Cursor has no sandbox on Windows

    Examples:
      | mode              |
      | auto              |
      | approval required |

  # Upstream #20046: Cursor has no sandbox on Windows, so a mode that needs one is refused.
  Scenario: A Cursor mode that needs a sandbox is refused on a Windows MC
    Given the MC runs on Windows
    When a Cursor thread in auto-accept edits starts its first turn
    Then the turn fails saying Cursor cannot sandbox on Windows

  Scenario: Cursor text generation that its sandbox blocks is retried without the sandbox
    Given Cursor is picked for text generation
    And generating a title fails only because Cursor's sandbox blocks it
    When the MC retries the request
    Then the retry removes only the restriction that blocked it
    And the thread gets its title

  @backlog @priority-low
  Scenario: Cursor keeps its metadata out of the workspace
    Given a Cursor thread in a project folder
    When a Cursor turn runs
    Then the project folder gains no files generated for Cursor

  Scenario: Cursor receives the project's skills and rules
    Given the project has skills and rules for Cursor
    When a Cursor turn starts in the project
    Then Cursor receives the project's skills and rules

  # Upstream #15875. HAL-C2's own MCP server is added when the agent opens or resumes;
  # a send that named MCP servers replaced the user's, project's and plugins' ones.
  @backlog
  Scenario: Cursor keeps the user's own MCP servers alongside HAL-C2's
    Given the user's Cursor settings, the project and a Cursor plugin each configure an MCP server
    When the user sends a message on a Cursor thread
    Then the Cursor agent can use those MCP servers and HAL-C2's MCP server

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

  # Upstream #24595: Cursor's built-in skills live in ~/.cursor/skills-cursor and were missing.
  @backlog @priority-low
  Scenario: Cursor's built-in skills are offered as system skills after the others
    Given Cursor's built-in skill "review" in ".cursor/skills-cursor" of the user's home
    And the project has its own skill "review"
    When the user opens the skill list in a Cursor thread
    Then Cursor's built-in skills are offered as system skills
    And "review" is the project's skill

  @backlog @priority-low
  Scenario: A project's Cursor skill wins over the user's skill of the same name
    Given the skill "deploy" exists in the project and in the user's home
    When the user opens the skill list in a Cursor thread
    Then "deploy" is offered once, from the project

  @backlog @priority-low
  Scenario: A skill that is not meant for the Cursor CLI is not offered
    Given the project has a Cursor skill whose header limits it to surfaces other than the CLI
    When the user opens the skill list in a Cursor thread
    Then that skill is not offered

  @backlog @priority-low
  Scenario: A Cursor skill only the user may run is marked so
    Given the project has a Cursor skill whose header forbids the model from starting it
    When the user opens the skill list in a Cursor thread
    Then the skill is offered as one only the user can run

  @backlog @priority-low
  Scenario: A skill folder nested too deep does not hide the other skills
    Given the project has the Cursor skill "review"
    And the user's ".claude/skills" holds a folder tree deeper than the scan reaches
    When the user opens the skill list in a Cursor thread
    Then "review" is offered
    And skills inside the too-deep part of the tree are not

  # Upstream #18664: skill discovery walks a folder once even when two skill roots link to
  # it, so a linked root no longer doubles the scan and exhausts its budget.
  @backlog @priority-low
  Scenario: A skill folder linked from a second root is read once
    Given the user's "~/.agents/skills" is a link to "~/.claude/skills"
    And "~/.claude/skills" holds 6,000 entries including the skill "review"
    When the user opens the skill list in a Cursor thread
    Then "review" is offered once
    And the skill search is not reported as incomplete

  # Upstream #19806: installed node_modules no longer exhaust skill discovery
  @backlog
  Scenario: Installed dependencies inside a skill do not hide the other skills
    Given a Cursor skill folder holds an installed "node_modules" with thousands of files
    And other skills sit beside it
    When the user lists Cursor's skills
    Then every skill is listed
    And nothing inside "node_modules" is searched for skills

  # Upstream #23326: supporting files used up the skill search's shared budget, so 11,000 files
  # under one skill hid its sibling and failed the provider check.
  @backlog @priority-low
  Scenario: A skill's supporting files do not hide the skills beside it
    Given the project has the Cursor skills "review" and "deploy"
    And "review" holds 11,000 files under its "artifacts" folder
    When the user lists Cursor's skills
    Then "review" and "deploy" are both listed
    And Cursor's provider check passes

  @backlog @priority-low
  Scenario Outline: A Cursor skill search that cannot finish is reported, not cut short
    Given <situation>
    When the MC reads the Cursor skills
    Then reading fails saying skill discovery was incomplete because of <reason>

    Examples:
      | situation                                                              | reason                |
      | the skill folders hold more than 10,000 entries or 8 MB of skill files | scan-budget-exhausted |
      | the skill folders are nested more than ten levels deep                 | scan-budget-exhausted |
      | a skill folder cannot be read                                          | filesystem-error      |

  @backlog @priority-low
  Scenario: Only a known Cursor skill is turned into a skill reference
    Given the project has the Cursor skill "deploy"
    When the user sends "run $deploy with $HOME set" to Cursor
    Then "deploy" reaches Cursor as a skill reference
    And "$HOME" reaches Cursor as typed

  Scenario Outline: A Cursor sign-in that cannot be checked is explained
    Given <problem>
    When the MC checks Cursor
    Then the user is told "<message>"

    Examples:
      | problem                                         | message                                         |
      | the MC cannot open its store of Cursor logins   | Could not open the Cursor credential store.     |
      | Cursor cannot confirm the saved sign-in         | Could not verify the Cursor sign-in. Try again. |

  Scenario: A Cursor reply that is only a connection error fails the turn
    Given a Cursor turn is running
    When Cursor's whole reply is a connection error such as "Something went wrong communicating with the server. Please try again."
    Then the turn fails as a connection problem instead of showing the error as Cursor's answer

  # Upstream #23273: commentary earlier in the turn hid a later message that was only the error.
  Scenario: A Cursor message that is only a connection error fails the turn after commentary
    Given a Cursor turn wrote "Checking the build first." and ran a step
    When Cursor's next message is only the error "Error: RetriableError: WritableIterable is closed" and the run finishes
    Then the turn fails with "Provider turn failed."
    And a later ordinary message in the same turn lets it complete

  # Upstream #16146: a failed Cursor run fails the turn with Cursor's own message and code,
  # and an SDK failure names the SDK's reason, code and HTTP status.
  # Upstream #24231: Cursor's SDK resumed a finished turn from an older checkpoint after its
  # connection broke, gave up, and the answered turn read "Provider error".
  Scenario: A finished Cursor turn whose late resume gives up still completes
    Given a Cursor turn has answered and Cursor reported the turn ended
    When the connection to Cursor breaks and the run ends with "Agent turn stopped after repeated resume attempts made no progress"
    Then the turn completes instead of failing
    And the failed resume's text is not shown as the answer

  # Upstream #24231: a Cursor turn that had not finished still fails when the run gives up.
  Scenario Outline: A Cursor run that gives up still fails when the turn had not finished
    Given a Cursor turn is running
    When <event>
    Then the turn fails

    Examples:
      | event                                                                                     |
      | the run ends with the no-progress error before Cursor reports the turn ended              |
      | Cursor reports the turn ended and the run then ends with "Checkpoint persistence failed"  |
      | Cursor continues after the turn ended and stops mid-answer with the no-progress error     |

  Scenario: A failed Cursor turn shows the reason Cursor gave
    Given a Cursor turn is running
    When Cursor ends the run with the error "Model Blocked Please ask your admin to enable access"
    Then the turn fails with "Model Blocked Please ask your admin to enable access"
    And a thread that delegated the turn is told the same reason

  @priority-low
  Scenario: An answer that quotes a connection error is still an answer
    Given the user asked Cursor what a connection error means
    When Cursor answers and its answer quotes the error text
    Then the turn completes with that answer

  # CursorAdapterV2.ts: what the Cursor SDK's run stream becomes in the thread.
  Scenario: Compacting a Cursor thread uses Cursor's own compress command
    Given a Cursor thread with history
    When the user compacts the thread
    Then Cursor receives "/compress" as its whole message
    And nothing is added to it

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

  Scenario: A Cursor MCP tool call is named after its server and tool
    When Cursor calls the tool "search" of the MCP server "docs"
    Then the thread shows the tool call as "mcp__docs__search"
    And a result the server marks as an error shows the call as failed

  # Upstream #26065: a file with one match in a counting grep said "1 matches".
  @shared @priority-low @backlog-desktop @backlog-mobile @backlog-tui
  Scenario: A counting search says "1 match" for a file with one match
    When Cursor counts the matches of a text search across files
    Then a file with one match says "1 match"
    And a file with three matches says "3 matches"

  Scenario: A Cursor command shows its output while it runs
    Given Cursor is running a long shell command
    When the command prints output before it finishes
    Then the output appears in the thread while the command is still running

  Scenario: A Cursor edit shows its diff and line counts
    When Cursor edits a file
    Then the file change shows the diff
    And it shows how many lines were added and removed

  @priority-low
  Scenario: A folder Cursor lists shows every file under it
    When Cursor lists a folder with nested folders
    Then every file under it is listed with its path

  @priority-low
  Scenario: Lint problems Cursor reads are listed with their position
    When Cursor reads the lint problems of a file
    Then each problem is listed with its message, line and column

  Scenario: A Cursor subagent runs in its own child thread
    When Cursor hands a task to one of its subagents
    Then a child thread opens with the task as its first message
    And the subagent's tool calls appear in the child thread
    And the subagent's result is shown when it finishes
  # Upstream #26592: a subagent's empty directory listing, lint check or MCP result failed the parent run.
  Scenario Outline: A Cursor subagent's <tool> with nothing in it does not fail the parent run
    Given Cursor hands a task to one of its subagents
    When the subagent's <tool> comes back with <empty>
    Then the parent run goes on
    And the child thread shows the <tool>

    Examples:
      | tool              | empty                         |
      | directory listing | a folder holding only folders |
      | lint check        | no problems                   |
      | MCP tool call     | no content                    |


  # Upstream #17419: subagent cards show Cursor's reasoning effort.
  @backlog @shared
  Scenario: A Cursor subagent's card names its reasoning effort
    Given Cursor starts a subagent with high reasoning effort
    When the user looks at the subagent's card
    Then the card reads the effort "High"

  @backlog @priority-low
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

  @priority-low
  Scenario: Cancelled and empty Cursor to-dos are left out of the task list
    When Cursor updates its to-do list with a cancelled item and an item with no text
    Then neither item appears in the task list

  Scenario: A Cursor answer that arrives only with the run's result is still shown
    Given Cursor streamed no text during a run
    When the run finishes with a result text
    Then the result text is shown as Cursor's answer

  Scenario: Images attached to a Cursor message are sent as images
    When the user sends a Cursor message with a screenshot attached
    Then Cursor receives the screenshot as an image with the message

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
  @backlog @priority-low
  Scenario: Cursor skills kept in sub-folders of a skill folder are found
    Given the project keeps the skill "deploy" in "team/release/deploy" under ".cursor/skills"
    When the user opens the skill list in a Cursor thread
    Then "deploy" is offered

  @backlog @priority-low
  Scenario: A Cursor skill is known by its folder and shown by the name in its header
    Given the project has a Cursor skill in the folder "deploy" whose header names it "Ship it"
    When the user opens the skill list in a Cursor thread
    Then the skill is shown as "Ship it"
    And the user mentions it as "deploy"

  @backlog @priority-low
  Scenario: A Cursor skill linked from outside its skill folder is offered without searching where it lives
    Given ".cursor/skills" holds a link "shared" to a skill kept elsewhere on the machine
    And that skill's own folder holds further skills below it
    When the user opens the skill list in a Cursor thread
    Then "shared" is offered
    And the skills below it are not searched for

  @backlog @priority-low
  Scenario: A Cursor skill whose header cannot be read is not offered
    Given the project has a Cursor skill whose header is not valid
    When the user opens the skill list in a Cursor thread
    Then that skill is not offered
    And the other skills are still offered

  @backlog @priority-low
  Scenario: A Cursor skill file larger than 1 MB is offered without its description
    Given the project has a Cursor skill "manual" whose skill file is larger than 1 MB
    When the user opens the skill list in a Cursor thread
    Then "manual" is offered under its folder's name with no description

  @backlog @priority-low
  Scenario: A Cursor skill the user may not start is listed as unavailable to them
    Given the project has a Cursor skill whose header says the user cannot start it
    When the user opens the skill list in a Cursor thread
    Then the skill is listed as one the user cannot start

  # features/settings/subagents.feature: the setting is not wired for Cursor yet.
  @backlog @mc
  Scenario: Cursor's own subagents are left as they are when agents use HAL-C2 workers
    Given the subagents setting is HAL-C2 workers
    When a Cursor session is started
    Then Cursor starts as usual, because it has no switch for its subagents

  # Upstream #22897: a write to a stream the Cursor SDK already closed took the whole server down.
  @priority-high
  Scenario: A Cursor stream closing under a write does not stop the MC
    Given a Cursor turn is running
    When the Cursor SDK rejects a write because its stream already closed
    Then the MC keeps running
    And other threads are unaffected

  # Upstream #27703: when the Cursor SDK ended a run's request with a write still in flight, as after
  # an account ran out of usage, the rejected write took the whole server down.
  @priority-high
  Scenario: A Cursor write left over after its request ended does not stop the MC
    Given a Cursor turn is running
    When the Cursor SDK ends the run's request while a write is still in flight
    Then the MC keeps running
    And other threads are unaffected
