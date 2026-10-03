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

  @backlog
  Scenario: Cursor model options come from the Cursor catalog
    When the user opens the options for a Cursor model
    Then the reasoning, context size, fast mode and thinking choices Cursor offers for that model are shown

  Scenario: An empty Cursor catalog is a warning
    Given Cursor returns no models
    When the user opens the provider list
    Then Cursor is shown with a warning that no models were found

  @backlog
  Scenario: Cursor's plan and task list are shown
    Given the thread is in plan mode on Cursor
    When Cursor finishes planning
    Then the plan is shown as a proposed plan with its task list

  @backlog
  Scenario: Cursor's monthly allowance is shown in the limits view
    Given Cursor is signed in with a file-based login
    When the user opens the limits view
    Then Cursor shows its monthly, Auto and API usage with the billing cycle end

  Scenario: Cursor usage is unavailable with a keychain login
    Given Cursor is signed in through the system keychain
    When the user opens the limits view
    Then Cursor says usage needs a file-based login

  @backlog
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

  @backlog
  Scenario: Cursor receives the project's skills and rules
    Given the project has skills and rules for Cursor
    When a Cursor turn starts in the project
    Then Cursor receives the project's skills and rules

  Scenario: A Cursor shell command that fails to start does not stop the turn
    Given Cursor is running a turn
    When a shell command Cursor tries fails to start
    Then the turn keeps going
    And the command is shown as failed

  @backlog
  Scenario: A Cursor send whose run was abandoned is ended
    Given a message was sent to Cursor but the MC kept only its local run record and no live Cursor session
    When the MC checks its Cursor sessions
    Then the send is completed or failed explicitly
    And the user's next message starts a new Cursor run
