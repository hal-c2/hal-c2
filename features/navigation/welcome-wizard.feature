# Sources:
#   docs/user/welcome-wizard.md
#   apps/web/src/components/onboarding/WelcomeWizard.tsx
#   apps/web/src/components/onboarding/FirstRunGate.tsx
#   apps/server/src/project/AgentSessionScanner.ts

Feature: Welcome wizard
  A new installation, or a first visit to the hosted app, walks the user through connecting
  computers, checking agents and importing projects. Existing workspaces skip it.

  Rule: When the wizard appears

    @backlog @desktop
    Scenario: A new installation starts with the wizard
      Given a fresh installation with no workspace
      When the user opens T3 Code
      Then the user sees "Set up T3 Code"

    @backlog @desktop
    Scenario: An existing workspace skips the wizard
      Given a workspace that already has projects
      When the user opens T3 Code
      Then the app opens without the wizard

    @backlog @desktop
    Scenario: A workspace that cannot be confirmed yet says it is still connecting
      Given the app cannot confirm the workspace during startup
      When the user opens T3 Code
      Then the user sees "Still connecting"
      When the user reloads
      Then the app tries again

    @backlog @desktop
    Scenario: Unreadable settings are never replaced with defaults
      Given the saved settings cannot be read
      When the user opens T3 Code
      Then the user sees "Could not read settings"
      And the saved settings are left untouched
      When storage becomes available and the user retries
      Then the app continues with the saved settings

    @backlog @desktop
    Scenario: Finishing setup can fail
      Given the settings cannot be saved
      When the user finishes the wizard
      Then the user is told "Could not finish setup"

  Rule: Connect your computers

    @backlog @desktop
    Scenario: The serving computer is already selected
      Given the user opened T3 Code from a desktop app named "studio"
      Then "studio" is connected and selected

    @backlog @desktop
    Scenario: Saved and discovered computers are selected by default
      Given a saved computer and a computer discovered through T3 Connect
      Then both computers are selected

    @backlog @desktop
    Scenario: Unchecking a computer does not disconnect it
      Given a selected, connected computer "laptop"
      When the user unchecks "laptop"
      Then "laptop" is not set up by the wizard
      But "laptop" stays connected

    @backlog @desktop
    Scenario: Adding a computer with a pairing link
      When the user adds a computer by pasting a pairing link
      Then the computer connects and is selected

    @backlog @desktop
    Scenario: A bad pairing link is reported
      When the user adds a computer with a pairing link that fails
      Then the user is told "Pairing failed."

    @backlog @desktop
    Scenario: Continuing waits for the selected computers
      Given a selected computer is still connecting
      Then the user cannot continue yet
      When that computer connects
      Then the user can continue

  Rule: Check your agents

    @backlog @desktop
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

    @backlog @desktop
    Scenario: Installing an agent opens a terminal with the command ready
      Given Codex is not installed on "studio"
      When the user chooses to install Codex
      Then a terminal opens on "studio" with the vendor's installer command ready
      And the user is asked to review the command and press Enter to run it

    @backlog @desktop
    Scenario: The setup terminal uses the provider's own home and environment
      Given the Codex instance on "studio" has its own home directory and a secret variable
      When the user chooses to sign in to Codex
      Then the terminal runs with that home and variable
      And the secret stays redacted where the user can see it

    @backlog @desktop
    Scenario: The setup terminal cannot open
      Given terminals cannot start on "studio"
      When the user chooses to install Codex
      Then the user is told "Could not open the setup terminal."

  Rule: Import your projects

    @node
    Scenario: Git repositories come first, newest first
      Given Claude Code and Codex used two git repositories and one plain folder
      When the wizard lists projects
      Then the git repositories are listed newest activity first
      And the plain folder is listed under "Other folders"

    @node
    Scenario: Clones of the same GitHub repository share a group
      Given two folders are clones of github.com/acme/api
      When the wizard lists projects
      Then both folders are grouped under "acme/api"

    @node
    Scenario: Busy recent repositories are selected by default
      Given a repository with 3 conversations in the last 30 days
      And a repository with 1 conversation in the last 30 days
      When the wizard lists projects
      Then only the first repository is selected

    @backlog @desktop
    Scenario Outline: Selecting all or none
      When the user chooses "<choice>"
      Then <outcome>

      Examples:
        | choice      | outcome                         |
        | Select all  | every listed project is selected|
        | Select none | no project is selected          |

    @node
    Scenario Outline: Some folders are never offered
      Given an agent used a folder that is <kind>
      When the wizard lists projects
      Then that folder is not offered

      Examples:
        | kind                          |
        | a linked git worktree         |
        | under Documents/Codex         |
        | under Downloads               |

    @node
    Scenario: A scan that hits its limit keeps what it found and warns
      Given an agent history too large to scan fully
      When the wizard lists projects
      Then the projects found so far are listed
      And the user is warned "Scan limit reached. Some projects or conversations may be missing."

    @node
    Scenario: Imported conversations keep the first prompt and the newest messages
      Given a conversation of 500 visible messages from the last 30 days
      When the user imports its project
      Then the conversation keeps the first user prompt and the newest messages up to 200 in total
      And tool activity and attachments are left out

    @node
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

    @node
    Scenario: A large import continues on the next run without duplicates
      Given a project with 150 conversation files
      When the user imports it
      Then at most 100 conversation files are read
      When the user runs the import again
      Then the rest are imported
      And conversations already imported are not imported again

    @backlog @desktop
    Scenario: A failed history import is reported
      Given reading thread history will fail
      When the user imports a project
      Then the user is told "Could not import thread history."

  Rule: Moving through the wizard

    @backlog @desktop
    Scenario: The user can skip configuring agents and importing projects
      When the user continues without importing projects
      Then the app opens

    @backlog @desktop
    Scenario: The progress bar returns to an earlier step
      Given the user is on the import step
      When the user returns to the connect step from the progress bar
      Then the connect step is shown with the earlier choices

    @backlog @desktop
    Scenario: Navigation pauses while an import runs
      Given an import is running
      Then the user cannot move to another step until it finishes
