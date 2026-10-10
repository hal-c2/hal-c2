# Sources:
#   docs/user/welcome-wizard.md
#   apps/web/src/components/onboarding/WelcomeWizard.tsx
#   apps/web/src/components/onboarding/FirstRunGate.tsx
#   apps/web/src/onboarding/firstRun.logic.ts (when the wizard appears, fresh workspace, persisted completion)
#   apps/web/src/onboarding/projectImport.logic.ts (default selection, grouping, landing project)
#   apps/web/src/onboarding/providerReadiness.logic.ts (install and login commands, agent states)
#   apps/web/src/onboarding/targetEnvironment.logic.ts
#   apps/server/src/project/AgentSessionScanner.ts
#   apps/desktop-qt/src/native/OnboardingController.cpp (the desktop's gate and wizard)
#   apps/desktop-qt/qml/HalC2/Bricks/WelcomeWizard.qml
#   apps/desktop-qt/tests/native/features/OnboardingSteps.cpp (the @desktop steps)
#   apps/server-ex/lib/hal_c2/terminal.ex (the setup terminal as the provider instance)

Feature: Welcome wizard
  A new installation, or a first visit to the hosted app, walks the user through connecting
  computers, checking agents and importing projects. Existing workspaces skip it.

  Rule: When the wizard appears

    @desktop
    Scenario: A new installation starts with the wizard
      Given a fresh installation with no workspace
      When the user opens HAL-C2
      Then the user sees "Set up HAL-C2"

    @desktop
    Scenario: An existing workspace skips the wizard
      Given a workspace that already has projects
      When the user opens HAL-C2
      Then the app opens without the wizard

    @desktop
    Scenario: A workspace that cannot be confirmed yet says it is still connecting
      Given the app cannot confirm the workspace during startup
      When the user opens HAL-C2
      Then the user sees "Still connecting"
      When the user reloads
      Then the app tries again

    @desktop
    Scenario: Unreadable settings are never replaced with defaults
      Given the saved settings cannot be read
      When the user opens HAL-C2
      Then the user sees "Could not read settings"
      And the saved settings are left untouched
      When storage becomes available and the user retries
      Then the app continues with the saved settings

    @desktop
    Scenario: Finishing setup can fail
      Given the settings cannot be saved
      When the user finishes the wizard
      Then the user is told "Could not finish setup"

    @backlog @desktop
    Scenario: Finishing setup again after a failure replaces the earlier message
      Given finishing setup failed and the user was told "Could not finish setup"
      When the user finishes the wizard again
      Then the earlier message is dismissed
      And at most one "Could not finish setup" message is shown if it fails again

    @backlog @desktop
    Scenario: Nothing is shown until the workspace has been confirmed
      Given the app has not yet heard from the computer it serves
      When the user opens HAL-C2
      Then neither the app nor the wizard is shown yet

    @backlog @desktop
    Scenario: A project and thread the server made for its own folder do not count as a workspace
      Given a new installation where the server added its own folder as a project with an empty thread
      When the user opens HAL-C2
      Then the user sees "Set up HAL-C2"

    @backlog @desktop
    Scenario Outline: A workspace the user has used skips the wizard
      Given the server added its own folder as a project at startup
      And <use>
      When the user opens HAL-C2
      Then the app opens without the wizard

      Examples:
        | use                                         |
        | the user added another project              |
        | the user started a second thread            |
        | the server's own thread has a message in it |

    @backlog @desktop
    Scenario: Projects remembered from an earlier visit open the app without finishing setup
      Given the app has only remembered projects and has not confirmed them with the computer
      When the user opens HAL-C2
      Then the app opens without the wizard
      And setup is not recorded as finished

    @backlog @desktop
    Scenario: Setup is recorded as finished once an existing workspace is confirmed
      Given a workspace that already has projects
      When the computer confirms it
      Then setup is recorded as finished
      And the wizard does not appear on later starts

    @backlog @desktop
    Scenario: The wizard stays once it has appeared
      Given the wizard is showing
      When the workspace is confirmed again with more evidence
      Then the wizard stays until the user finishes it

    @backlog @desktop
    Scenario: A desktop that had its local server turned off keeps the connections settings reachable
      Given the user had turned local execution off before the wizard existed
      And no computers are connected
      When the user opens HAL-C2
      Then the app opens without the wizard
      And the user can turn local execution back on from the connections settings

    # The hosted web app is a browser tab, which has no replacement.
    @dropped @desktop
    Scenario: The hosted app starts a first-time visitor with no computers in the wizard
      Given the user opens the hosted app for the first time
      And no computers are saved in this browser
      When the app loads
      Then the user sees "Set up HAL-C2"

  Rule: Connect your computers

    @desktop
    Scenario: The serving computer is already selected
      Given the user opened HAL-C2 from a desktop app named "studio"
      Then "studio" is connected and selected

    @desktop
    Scenario: Saved and discovered computers are selected by default
      Given a saved computer and a computer discovered through HAL-C2 Connect
      Then both computers are selected

    @desktop
    Scenario: Unchecking a computer does not disconnect it
      Given a selected, connected computer "laptop"
      When the user unchecks "laptop"
      Then "laptop" is not set up by the wizard
      But "laptop" stays connected

    @desktop
    Scenario: Adding a computer with an invite link
      When the user adds a computer by pasting an invite link
      Then the computer connects and is selected

    @desktop
    Scenario: A bad invite link is reported
      When the user adds a computer with an invite link that fails
      Then the user is told "Pairing failed."

    @desktop
    Scenario: Continuing waits for the selected computers
      Given a selected computer is still connecting
      Then the user cannot continue yet
      When that computer connects
      Then the user can continue

    @backlog @desktop
    Scenario: Continuing needs at least one computer
      Given no computer is selected
      Then the user cannot continue

    @backlog @desktop
    Scenario: A computer that appears while the wizard is open is selected
      Given the wizard is on its first step
      When another computer connects
      Then it is added to the selected computers
      And the user's earlier choices are kept

    @backlog @desktop
    Scenario: A computer the user unchecked stays unchecked when others appear
      Given the user unchecked "laptop"
      When another computer connects
      Then "laptop" is still not selected

    @backlog @desktop
    Scenario: Each computer says whether it is connected or still connecting
      Given a connected computer "studio" and a computer "laptop" that is still connecting
      Then "studio" reads "Connected"
      And "laptop" reads "Connecting…"

    @backlog @desktop
    Scenario: HAL-C2 Connect asks the user to sign in before listing computers
      Given the user is not signed in to HAL-C2 Connect
      When the user opens HAL-C2 Connect in the wizard
      Then the user is asked to sign in
      And no computers are listed

    @backlog @desktop
    Scenario: A signed-in account with no linked computers says so
      Given the user is signed in to HAL-C2 Connect
      And no computers are linked to the account
      When the user opens HAL-C2 Connect in the wizard
      Then the user sees "No computers linked yet."

    @backlog @desktop
    Scenario: Where HAL-C2 Connect is on, relayed computers are listed under it
      Given HAL-C2 Connect is available
      And a computer is reached through the relay
      Then the computer is listed under HAL-C2 Connect and not among the directly saved ones

    @backlog @desktop
    Scenario: Without a local server the wizard opens the pairing form first
      Given this client cannot reach a local server
      And HAL-C2 Connect is not available
      When the wizard opens
      Then the pairing link form is expanded and has focus

    @backlog @desktop
    Scenario: A pairing link is submitted once
      Given the user pasted a pairing link
      When the user submits it twice quickly
      Then the computer is paired once
      And the field cannot be edited while pairing

    @backlog @desktop
    Scenario: An empty pairing link cannot be submitted
      Given the pairing link field is empty
      Then the user cannot pair

    @backlog @desktop
    Scenario: Enter that confirms an input method's composition does not submit the pairing link
      Given the user is composing text with an input method in the pairing link field
      When the user presses Enter to confirm the composition
      Then the pairing link is not submitted

    @backlog @desktop
    Scenario: The wizard explains how to get a pairing link
      When the user asks how to get a pairing link
      Then the wizard names the command to run on the computer with the user's code
      And it says HAL-C2 must be running there and how to share it over a tailnet

    @backlog @desktop
    Scenario: The wizard explains how to link a computer to HAL-C2 Connect
      When the user expands the instructions for HAL-C2 Connect
      Then the wizard names the command to run on each computer to connect
      And it says to keep HAL-C2 running there

  Rule: Check your agents

    @desktop
    Scenario Outline: Each selected computer is checked for an agent
      Given the computer "studio" has <agent> <state>
      When the wizard checks agents
      Then <agent> on "studio" offers <action>

      Examples:
        | agent       | state                        | action           |
        | Claude Code | not installed                | Install          |
        | Claude Code | installed but signed out     | Sign in          |
        | Codex       | not installed                | Install          |
        | Codex       | installed and signed in      | nothing to do    |

    @desktop
    Scenario: Installing an agent opens a terminal with the command ready
      Given Codex is not installed on "studio"
      When the user chooses to install Codex
      Then a terminal opens on "studio" with the vendor's installer command ready
      And the user is asked to review the command and press Enter to run it

    @desktop
    Scenario: The setup terminal uses the provider's own home and environment
      Given the Codex instance on "studio" has its own home directory and a secret variable
      When the user chooses to sign in to Codex
      Then the terminal runs with that home and variable
      And the secret stays redacted where the user can see it

    @desktop
    Scenario: The setup terminal cannot open
      Given terminals cannot start on "studio"
      When the user chooses to install Codex
      Then the user is told "Could not open the setup terminal."

    @backlog @desktop
    Scenario: A setup terminal that failed to open can be retried or closed
      Given the setup terminal could not open on "studio"
      When the user retries
      Then the wizard tries to open the terminal again
      And closing it dismisses the terminal

    @backlog @desktop
    Scenario: A setup terminal that cannot be pre-typed tells the user the command
      Given the setup terminal opened on "studio" but the command could not be typed into it
      Then the wizard shows the command and asks the user to run it in the terminal

    @backlog @desktop
    Scenario Outline: The install command follows the computer's platform
      Given the agent <agent> is not installed on a computer running <platform>
      When the user chooses to install it
      Then the command typed into the setup terminal is "<command>"

      Examples:
        | agent       | platform | command                                        |
        | Claude Code | Linux    | curl -fsSL https://claude.ai/install.sh \| bash |
        | Claude Code | macOS    | curl -fsSL https://claude.ai/install.sh \| bash |
        | Claude Code | Windows  | irm https://claude.ai/install.ps1 \| iex        |
        | Codex       | Linux    | curl -fsSL https://chatgpt.com/codex/install.sh \| sh |
        | Codex       | Windows  | irm https://chatgpt.com/codex/install.ps1 \| iex |

    @backlog @desktop
    Scenario: The install command follows the computer, not the client
      Given the user's desktop runs Windows and the computer being set up is a WSL environment
      When the user chooses to install Claude Code
      Then the command typed is the shell installer

    @backlog @desktop
    Scenario Outline: Signing in runs the agent's own login command
      Given <agent> is installed on "studio" but signed out
      When the user chooses to sign in
      Then the command typed into the setup terminal is "<command>"

      Examples:
        | agent       | command          |
        | Claude Code | claude auth login |
        | Codex       | codex login      |

    @backlog @desktop
    Scenario: Signing in uses the binary the instance is configured with
      Given the Claude Code instance on "studio" is configured to use "/opt/my tools/claude"
      When the user chooses to sign in
      Then the command typed quotes that path so the shell reads it as one program

    @backlog @desktop
    Scenario: Agents are checked again when the step opens and when a setup terminal closes
      Given the user installed Codex in the setup terminal
      When the user closes the setup terminal
      Then Codex on "studio" is checked again and shows its new state

    @backlog @desktop
    Scenario: Closing or leaving a setup terminal ends its shell and discards its history
      Given a setup terminal is open on "studio"
      When the user closes it, continues, or opens setup for another agent
      Then the terminal's shell is ended
      And its history is deleted
      And nothing keeps running behind the wizard

    @backlog @desktop
    Scenario: A setup terminal closes by itself when its shell exits
      Given a setup terminal is open on "studio"
      When the shell exits
      Then the terminal closes

    @backlog @desktop
    Scenario: Only one setup terminal is open per computer
      Given a setup terminal is open for Codex on "studio"
      When the user chooses to install Claude Code on "studio"
      Then Claude Code's terminal replaces the Codex one
      And the button for the agent whose terminal is open is unavailable

    @backlog @desktop
    Scenario: Setup cannot start before the computer's configuration is known
      Given "studio" has connected but its configuration has not arrived
      Then the agents on "studio" cannot be installed or signed in yet

    @backlog @desktop
    Scenario Outline: An agent shows its state while it is checked
      Given the agent <agent> is <state> on "studio"
      Then the agent shows <shown>

      Examples:
        | agent       | state                   | shown                  |
        | Claude Code | still being checked     | "Checking..."          |
        | Codex       | turned off              | "Disabled"             |
        | Codex       | installed and ready     | "Ready"                |

    @backlog @desktop
    Scenario: The most usable instance represents each agent
      Given "studio" has two Codex instances, one signed out and one ready
      When the wizard checks agents
      Then Codex on "studio" shows the ready instance

    @backlog @desktop
    Scenario: Only Claude Code and Codex are offered in the wizard
      Given "studio" also has other agents set up
      When the wizard checks agents
      Then only Claude Code and Codex are listed

  Rule: Import your projects

    @mc
    Scenario: Git repositories come first, newest first
      Given Claude Code and Codex used two git repositories and one plain folder
      When the wizard lists projects
      Then the git repositories are listed newest activity first
      And the plain folder is listed under "Other folders"

    @mc
    Scenario: Clones of the same GitHub repository share a group
      Given two folders are clones of github.com/acme/api
      When the wizard lists projects
      Then both folders are grouped under "acme/api"

    @mc
    Scenario: Busy recent repositories are selected by default
      Given a repository with 3 conversations in the last 30 days
      And a repository with 1 conversation in the last 30 days
      When the wizard lists projects
      Then only the first repository is selected

    @desktop
    Scenario Outline: Selecting all or none
      When the user chooses "<choice>"
      Then <outcome>

      Examples:
        | choice      | outcome                         |
        | Select all  | every listed project is selected|
        | Select none | no project is selected          |

    @mc
    Scenario Outline: Some folders are never offered
      Given an agent used a folder that is <kind>
      When the wizard lists projects
      Then that folder is not offered

      Examples:
        | kind                          |
        | a linked git worktree         |
        | under Documents/Codex         |
        | under Downloads               |

    @mc
    Scenario: A scan that hits its limit keeps what it found and warns
      Given an agent history too large to scan fully
      When the wizard lists projects
      Then the projects found so far are listed
      And the user is warned "Scan limit reached. Some projects or conversations may be missing."

    @mc
    Scenario: Imported conversations keep the first prompt and the newest messages
      Given a conversation of 500 visible messages from the last 30 days
      When the user imports its project
      Then the conversation keeps the first user prompt and the newest messages up to 200 in total
      And tool activity and attachments are left out

    @mc
    Scenario Outline: Conversations that cannot be imported are skipped
      Given a conversation that is <problem>
      When the user imports its project
      Then that conversation is skipped
      And the other conversations are imported

      # Both servers skip transcripts over 4 GiB (MAX_IMPORTED_TRANSCRIPT_BYTES); 16 MiB was an older limit.
      Examples:
        | problem                    |
        | larger than 4 GiB          |
        | not parseable              |
        | older than 30 days         |

    @mc
    Scenario: A large import continues on the next run without duplicates
      Given a project with 150 conversation files
      When the user imports it
      Then at most 100 conversation files are read
      When the user runs the import again
      Then the rest are imported
      And conversations already imported are not imported again

    @desktop
    Scenario: A failed history import is reported
      Given reading thread history will fail
      When the user imports a project
      Then the user is told "Could not import thread history."

    @backlog @desktop
    Scenario: The wizard says it is looking while the projects are scanned
      Given the first computer has not answered the project scan
      Then the wizard says "Looking for projects from Claude Code and Codex…"
      And the user can choose "Do not import projects"

    @backlog @desktop
    Scenario: A computer whose scan fails can be rescanned
      Given the project scan on "studio" fails
      Then the wizard says "Could not check projects." with the reason
      When the user chooses "Retry"
      Then "studio" is scanned again

    @backlog @desktop
    Scenario: A computer with no agent history says so
      Given "studio" has no Claude Code or Codex projects
      Then the wizard says "No existing Claude Code or Codex projects found."

    @backlog @desktop
    Scenario: With several computers each list is headed by its computer
      Given two computers are being set up
      When the wizard lists projects
      Then each computer's projects are listed under that computer's name

    @backlog @desktop
    Scenario Outline: A project is selected by default only when it looks like real work
      Given an agent used a folder that <situation>
      When the wizard lists projects
      Then the folder is offered
      And it is <selected> by default

      Examples:
        | situation                                                    | selected     |
        | is a git repository with 3 conversations in the last 30 days | selected     |
        | is a git repository with 2 conversations in the last 30 days | not selected |
        | is a git repository last used 31 days ago                    | not selected |
        | is not a git repository                                      | not selected |

    @backlog @desktop
    Scenario: A computer that does not report git details has its folders treated as repositories
      Given an older computer that does not say which folders are git repositories
      When the wizard lists projects
      Then its busy recent folders are selected by default like repositories

    @backlog @desktop
    Scenario: The wizard counts the selected projects
      Given 5 projects are offered and 2 are selected
      Then the wizard shows "2 of 5 selected"
      And the import action reads "Import 2 projects"

    @backlog @desktop
    Scenario: Importing a single project reads in the singular
      Given exactly 1 project is selected
      Then the import action reads "Import 1 project"

    @backlog @desktop
    Scenario: Nothing can be imported with nothing selected
      Given no project is selected
      Then the import action is unavailable
      And the user can still choose "Do not import projects"

    @backlog @desktop
    Scenario: Select all and Select none are unavailable when they would change nothing
      Given every project is selected
      Then "Select all" is unavailable
      When the user chooses "Select none"
      Then "Select none" is unavailable

    @backlog @desktop
    Scenario: Choosing a repository selects all its clones
      Given a repository with two clones on "studio"
      When the user checks the repository
      Then both clones are selected
      When the user unchecks one clone
      Then the repository shows as partly selected

    @backlog @desktop
    Scenario: A repository with no origin is listed by its folder name
      Given a git repository whose origin is not on GitHub
      When the wizard lists projects
      Then it is listed on its own under its folder's name

    @backlog @desktop
    Scenario: Folders that are not repositories are folded away
      Given an agent used a plain folder
      When the wizard lists projects
      Then "Other folders" is collapsed
      And the folder is reachable by opening it

    @backlog @desktop
    Scenario: A project that is already known is reused rather than created again
      Given "~/code/api" is already a project on "studio"
      When the user imports it from the wizard
      Then its history is imported into that project
      And no second project is created

    @backlog @desktop
    Scenario: The same folder on two computers is two projects
      Given "~/code/api" exists on "studio" and on "laptop"
      When the user selects only the one on "laptop"
      Then only "laptop"'s project is imported

    @backlog @desktop
    Scenario Outline: A partial import says what happened
      Given an import where <outcome>
      When the import finishes
      Then the wizard says "<message>"
      And the user stays on the import step

      Examples:
        | outcome                                           | message                                                      |
        | 3 threads imported and 2 could not be imported    | Imported 3 threads. 2 threads could not be imported.         |
        | 1 thread imported and 1 could not be imported     | Imported 1 thread. 1 thread could not be imported.           |
        | no thread imported and 1 could not be imported    | 1 thread could not be imported.                              |
        | 4 threads imported but a project's history failed | Imported 4 threads. Some thread history could not be imported. |
        | nothing imported                                  | Could not import thread history.                             |

    @backlog @desktop
    Scenario: The user can leave after a partial import
      Given an import finished with an error message
      Then the skip action reads "Continue without the rest"
      When the user chooses it
      Then the app opens in a project whose history was imported

    @backlog @desktop
    Scenario: Importing again does not repeat projects that already landed
      Given an import finished with some projects imported and one failed
      When the user imports the same selection again
      Then only the project that failed is attempted
      And the wizard still counts the earlier projects as imported

    @backlog @desktop
    Scenario: A failed project is retried as the same project
      Given creating a project failed during the import
      When the user imports again
      Then no duplicate project is created if the first attempt had in fact succeeded

    @backlog @desktop
    Scenario: The wizard opens in the first selected project that has imported history
      Given the user selected "api" then "web"
      And "web" has imported history and "api" does not
      When the import finishes
      Then the app opens in "web"

    @backlog @desktop
    Scenario: With no imported history the wizard opens in a project that imported cleanly
      Given the user selected "api"
      And "api" was imported with no conversations to bring in
      When the import finishes
      Then the app opens in "api"

  Rule: Moving through the wizard

    @desktop
    Scenario: The user can skip configuring agents and importing projects
      When the user continues without importing projects
      Then the app opens

    @desktop
    Scenario: The progress bar returns to an earlier step
      Given the user is on the import step
      When the user returns to the connect step from the progress bar
      Then the connect step is shown with the earlier choices

    @desktop
    Scenario: Navigation pauses while an import runs
      Given an import is running
      Then the user cannot move to another step until it finishes

    @backlog @desktop
    Scenario: The wizard cannot be dismissed
      Given the wizard is showing
      When the user presses Escape or clicks outside it
      Then the wizard stays open
      And it has no close action

    @backlog @desktop
    Scenario: The progress bar only goes back
      Given the user is on the agents step
      Then the connect step can be chosen from the progress bar
      But the import step cannot be reached from it

    @backlog @desktop
    Scenario: Setup covers only the computers that were selected when the user continued
      Given "studio" and "laptop" are connected and the user selected only "studio"
      When the user continues
      Then agents and projects are set up on "studio" only

    @backlog @desktop
    Scenario: Continuing from the connect step puts focus on Continue once every selected computer is connected
      Given a selected computer is still connecting and the user has not focused anything
      When that computer connects
      Then focus moves to the Continue action
