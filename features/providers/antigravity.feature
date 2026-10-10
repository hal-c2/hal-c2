# Sources:
#   https://github.com/pingdotgg/t3code/pull/2829
#   docs/user/providers-antigravity.md
#   docs/internals/providers.md (isolated profiles, installer leases, sign-in owned by the initiating session, reject revert before touching files)
#   apps/server/src/provider/Layers/AntigravityProvider.ts, apps/server/src/provider/AntigravityAuth.ts
#   apps/server/src/provider/antigravityAuthSupport.ts, apps/server/src/provider/antigravityCallback.ts
#   apps/server/src/provider/AntigravityInstallation.ts, apps/server/src/provider/antigravityRelease.ts
#   apps/server/src/provider/acp/AntigravityAcpSupport.ts, apps/server/src/provider/acp/AntigravityProtocol.ts
#   apps/server/src/provider/acp/AntigravityClientFiles.ts, apps/server/src/provider/acp/AntigravitySessionFiles.ts
#   apps/server/src/provider/Drivers/AntigravityDriver.ts, apps/server/src/provider/Drivers/AntigravitySkills.ts
#   apps/server/src/provider/acp/AcpSessionRuntime.ts (a stopped turn Antigravity never confirms)
#   apps/server/src/orchestration-v2/Adapters/AntigravityAdapterV2.ts (open execute tools complete with the turn)
#   apps/server-ex/lib/hal_c2/acp/thread_runtime.ex (open items close with the turn)
#   apps/web/src/components/settings/ProviderSetupSection.tsx
#   packages/contracts/src/rpc.ts (provider.install.start, provider.install.cancel, provider.install.remove, provider.install.subscribe, provider.auth.complete)
#   packages/contracts/src/providerSetup.ts (ProviderInstallState)

@plugin-antigravity @mc
Feature: Antigravity
  Antigravity runs Google's official Antigravity ACP agent. The MC downloads and
  verifies the runtime itself, keeps a private Google profile for each instance, and
  finishes browser sign-in even when the browser is on another device.

  Background:
    Given a connected environment with the project "shop"
    And Antigravity is enabled on that environment

  Scenario: Installing the Antigravity runtime shows its progress
    Given the Antigravity runtime is not installed
    When the user installs the Antigravity runtime
    Then the user sees the download progress in megabytes
    And then that it is extracting and then checking the runtime
    And finally that Antigravity is installed

  Scenario: Installation continues when the user leaves settings or reconnects
    Given the Antigravity runtime is downloading
    When the client disconnects and reconnects
    Then the download progress is still shown

  Scenario: Cancelling an installation keeps the previous runtime
    Given an older Antigravity runtime is installed and a new one is downloading
    When the user cancels the installation
    Then the user is told the previous runtime is unchanged

  Scenario: A download that does not match its checksum is rejected
    Given the downloaded runtime does not match the published checksum
    When the installation checks the download
    Then the installation fails
    And the previous runtime is unchanged

  Scenario: A failed installation can be retried
    Given the Antigravity installation failed for lack of disk space
    When the user frees space and retries the installation
    Then the runtime is installed

  Scenario: Removing the downloaded runtime keeps the Google sign-in
    Given the Antigravity runtime is installed and the user is signed in
    And no Antigravity session is running
    When the user removes the downloaded runtime and confirms
    Then the runtime is removed
    And the Google sign-in and thread history are kept

  Scenario: The runtime cannot be removed while it is in use
    Given an Antigravity session is running
    When the user tries to remove the downloaded runtime
    Then the removal is refused until the sessions and sign-ins stop

  @backlog
  Scenario: The runtime cannot be removed while an instance's binary path points into it
    Given the Antigravity runtime is installed
    And an Antigravity instance's binary path is inside the downloaded runtime
    When the user tries to remove the downloaded runtime
    Then the removal is refused asking the user to clear that path first

  @backlog
  Scenario: An installation that would not fit on disk stops before downloading
    Given the environment has less free disk space than the Antigravity runtime needs
    When the user installs the Antigravity runtime
    Then the installation fails naming the free space it needs in megabytes
    And nothing is downloaded

  @backlog
  Scenario: A downloaded archive with unexpected contents is rejected
    Given the downloaded runtime matches its checksum but holds more than the executable and its helper
    When the installation extracts the download
    Then the installation fails
    And the previous runtime is unchanged

  @backlog
  Scenario: Installing a release that is already stored checks and activates it
    Given the downloaded runtime of this release is already stored on the environment
    When the user installs the Antigravity runtime
    Then the stored runtime is checked and activated without downloading it again

  @backlog
  Scenario: A half-installed runtime is reported at startup
    Given the downloaded Antigravity runtime is missing files the MC recorded
    When the MC starts
    Then the user is told the managed runtime is incomplete
    And is told to remove it and install again

  @backlog
  Scenario: Cancelling an installation that is no longer current is refused
    Given an Antigravity installation finished after the client last refreshed
    When the client cancels that earlier installation
    Then the user is told to refresh the installation status before cancelling

  Scenario: An unsupported platform cannot install the runtime
    Given the environment runs on an Intel Mac
    When the user opens Antigravity setup
    Then the user is told Google does not publish a runtime for this platform
    And is offered to set a binary path or use another environment

  Scenario: A manual installation is used through the binary path
    Given the user extracted the Antigravity executable and its helper into one folder
    When the user sets the binary path to that executable
    Then Antigravity uses that installation
    And the managed installer leaves it alone

  Scenario: A manual installation missing its helper is explained
    Given the binary path points to an Antigravity executable without its helper
    When the user refreshes provider status
    Then the user is told the executable or its helper is missing

  @backlog
  Scenario Outline: Antigravity's health states are explained
    Given <situation>
    When the user opens the provider list
    Then Antigravity is shown with the message "<message>"

    Examples:
      | situation                                                      | message                                                                  |
      | Antigravity is turned off in the provider settings             | Antigravity is disabled in HAL-C2 settings.                              |
      | the MC is still checking Antigravity                           | Checking Antigravity availability.                                       |
      | no Antigravity runtime is installed                            | Antigravity is not installed or its executable could not be found.       |
      | the runtime starts but fails its local health check            | Antigravity could not complete its local health check.                   |
      | the runtime does not answer its health check within 90 seconds | Antigravity did not respond to its local health check within 90 seconds. |
      | the runtime is installed and the user has not signed in        | Sign in with Google to use Antigravity.                                  |
      | the runtime is installed and the sign-in has not been checked  | Antigravity is installed. Google account access is not checked yet.      |

  Scenario: Signing in with a Google account in the browser
    Given the Antigravity runtime is installed
    When the user signs in with a Google account and finishes in the browser
    Then Antigravity confirms access and loads the account's models

  Scenario: Finishing sign-in from another device by pasting the return address
    Given the user started sign-in from a phone connected to a remote environment
    And the final Google page failed to load
    When the user pastes the full return address into the sign-in
    Then Antigravity confirms access

  Scenario: A return address from another sign-in is rejected
    Given the user started sign-in on one client
    When a return address from a different sign-in attempt is pasted
    Then the user is told the address does not belong to the current sign-in

  Scenario: A successful callback page alone does not mean the user is signed in
    Given the Google page says sign-in succeeded
    When Antigravity cannot confirm account access
    Then Antigravity is not shown as signed in
    And the user is told why

  Scenario: An Antigravity sign-in expires after five minutes
    Given the user started Google sign-in
    When five minutes pass without finishing
    Then the user is told Google sign-in expired

  Scenario Outline: Antigravity sign-in methods
    When the user chooses the sign-in method <method> and provides <credentials>
    Then Antigravity connects with that method

    Examples:
      | method                     | credentials                                  |
      | Google account             | a browser sign-in                            |
      | Gemini Enterprise          | a browser sign-in, GCP project and location  |
      | Gemini API key             | an API key                                   |
      | Agent Platform             | an API key, or a GCP project and location    |

  Scenario: Ambient Google credentials do not override the instance's method
    Given the environment has a Gemini API key in its variables
    And the Antigravity instance uses a Google account
    When a thread runs on Antigravity
    Then the Google account is used

  Scenario: Changing the sign-in method stops the instance's sessions
    Given an Antigravity session is running
    When the user changes the sign-in method
    Then the instance's sessions stop

  Scenario: Signing out removes the saved Google login and keeps history
    Given the user is signed in to Antigravity
    When the user signs out
    Then the instance's sessions stop and its saved Google login is removed
    And thread history is kept

  Scenario: Sending logout in a thread signs out its instance
    When the user sends "/logout" by itself in an Antigravity thread
    Then that instance is signed out

  Scenario: An older runtime that cannot sign out asks for an update
    Given the Antigravity runtime does not support sign-out
    When the user signs out
    Then the user is told to update the provider

  Scenario: Disabling Antigravity keeps the sign-in
    Given the user is signed in to Antigravity
    When the user disables Antigravity
    Then its sessions stop
    And the Google sign-in is kept for when it is enabled again

  Scenario: Each Google account is its own instance
    Given two Antigravity instances "work" and "personal"
    When the user signs in to each with a different Google account
    Then each instance uses its own account and the downloaded runtime is shared

  Scenario: A server restart keeps the Google sign-in
    Given the user is signed in to Antigravity
    When the MC restarts
    Then Antigravity still shows the saved account

  Scenario: Reverting an Antigravity thread is not offered
    Given an Antigravity thread with two turns
    When the user tries to revert to the first turn
    Then the revert is refused before any file is touched

  Scenario: Plan mode is not offered for Antigravity
    When the user opens the mode picker in an Antigravity thread
    Then plan mode is not offered

  Scenario Outline: Antigravity attachment limits
    When the user attaches <attachment> to an Antigravity message
    Then the attachment is <outcome>

    Examples:
      | attachment                    | outcome  |
      | a 900 KiB text file           | accepted |
      | a 2 MiB text file             | rejected |
      | a 12 MiB image                | rejected |
      | a 15 MiB audio clip           | accepted |
      | files totalling 60 MiB        | rejected |
      | an unsupported file format    | rejected |

  Scenario: Antigravity reads a file of a kind it does not recognise by its path
    Given the project has a file whose kind Antigravity does not recognise
    When Antigravity asks for that file by its path
    Then Antigravity receives the file's contents

  Scenario: Antigravity cannot leave the workspace
    Given an Antigravity thread works in the project's folder
    When Antigravity asks for a path outside that folder
    Then the request is refused

  Scenario: Antigravity reads project skills from its skill folders in order
    Given the project has the skill "deploy" in both .gemini/skills and .agents/skills
    When the user opens the skill list in an Antigravity thread
    Then "deploy" is offered once, from .gemini/skills

  Scenario: Antigravity subagents are grouped into batches
    When Antigravity starts subagents
    Then their activity is shown as a subagent batch

  Scenario: A model the account lost is explained on resume
    Given an Antigravity thread uses a model the account can no longer use
    When the user sends a message
    Then the user is asked to pick another available model

  Scenario: Antigravity account restrictions are passed on
    When Google reports that a subscription is required
    Then the thread shows Google's message and any retry time

  Scenario: Signing in from the mobile app once the runtime is installed
    Given the Antigravity runtime is installed on the environment
    When the user signs in from the mobile app's provider accounts
    Then Antigravity confirms access

  # Antigravity completes the commands a turn left open, and its subagent batches
  # finish inside the turn, so nothing outlives it.
  Scenario: A command Antigravity leaves running ends with its turn
    When Antigravity ends a turn with a command still running
    Then the command it left running ends with the turn

  @backlog
  Scenario: Checking Antigravity's status does not start the runtime
    Given the Antigravity runtime is installed
    When the MC checks provider status at startup
    Then the runtime is not launched and no Google request is made
    And account access is reported as not checked yet

  @backlog
  Scenario Outline: A model refresh that fails keeps the previous models
    Given Antigravity lists the models it loaded earlier
    When the user refreshes the Antigravity models and <problem>
    Then the user is told "<message>"
    And the earlier models are still listed

    Examples:
      | problem                                   | message                                                                     |
      | the runtime does not answer in 90 seconds | Antigravity model refresh timed out. Try again or check Google sign-in.     |
      | the instance is not signed in             | Sign in to Antigravity in provider settings before refreshing models.       |
      | the refresh fails for another reason      | Could not refresh Antigravity models. The previous model list is unchanged. |

  @backlog
  Scenario: Antigravity's temporary files are removed
    Given an Antigravity session created temporary runtime and session files
    When the session ends
    Then those files are removed
    And files left behind by an MC that was killed are removed the next time Antigravity starts

  @backlog
  Scenario Outline: Antigravity skills are read from its own folders
    Given a skill "deploy" in <folder>
    When the user opens the skill list in an Antigravity thread
    Then "deploy" is <offered>

    Examples:
      | folder                                           | offered     |
      | the user's .gemini/config/skills                 | offered     |
      | the user's .gemini/antigravity-cli/skills        | offered     |
      | the project's .gemini/skills                     | offered     |
      | the project's .agents/skills                     | offered     |
      | the project's .agent/skills                      | offered     |
      | the user's .agents/skills                        | not offered |

  @backlog
  Scenario: A skill without a name in its header is named after its folder
    Given the project has a skill folder "deploy" whose skill file states no name
    When the user opens the skill list in an Antigravity thread
    Then the skill is offered as "deploy"

  @backlog
  Scenario: An Antigravity skill search that is too large is reported instead of cut short
    Given the project's skill folders hold more than 10,000 entries, or more than 8 MB of skill files
    When the MC reads the Antigravity skills
    Then reading fails naming the path where the scan limit was exceeded
    And no partial skill list is offered

  @backlog
  Scenario: A thread's chosen model is applied again after Antigravity restarts
    Given an Antigravity thread uses a model the user picked
    When the Antigravity runtime restarts and the thread continues
    Then the thread still uses that model

  @backlog
  Scenario Outline: Each kind of attachment reaches Antigravity in a form it can use
    When the user sends an Antigravity message with <attachment>
    Then Antigravity receives <form>

    Examples:
      | attachment          | form                                         |
      | a PNG image         | the image itself                             |
      | an audio clip       | the audio itself                             |
      | a PDF               | a link to the file, without its bytes        |
      | a text file         | the file's text                              |
      | a long pasted text  | the text, kept apart from the typed message  |

  @backlog
  Scenario Outline: An attachment Antigravity cannot take is refused with a reason
    When the user sends an Antigravity message with <attachment>
    Then the message is refused with "<message>"

    Examples:
      | attachment                                    | message                                                                                                                                                              |
      | the spreadsheet "q3.xlsx"                     | Antigravity does not support 'q3.xlsx' (application/vnd.openxmlformats-officedocument.spreadsheetml.sheet). Attach a BMP, JPEG, PNG, WebP, PDF, audio, or text file. |
      | "notes.txt" that is not valid UTF-8           | Attachment 'notes.txt' is not a UTF-8 text file.                                                                                                                     |
      | "notes.txt" that holds binary data            | Attachment 'notes.txt' contains binary data.                                                                                                                         |
      | "log.txt" that grew past the limit while read | Attachment 'log.txt' changed while being read and is too large.                                                                                                      |
      | nothing but blank text                        | A turn requires text or supported attachments.                                                                                                                       |

  @backlog
  Scenario Outline: A file Antigravity cannot be given is explained
    When Antigravity asks for the workspace file "data.bin" and <problem>
    Then the request is refused with "<message>"

    Examples:
      | problem                                      | message                                                          |
      | the file does not exist                      | File 'data.bin' not found.                                       |
      | the file is not text or is larger than 8 MiB | File 'data.bin' is not a readable text file under 8388608 bytes. |

  @backlog
  Scenario: Antigravity can read part of a file and write into new folders
    When Antigravity asks for a range of lines of a workspace file
    Then it receives only those lines
    And a workspace file it writes in a folder that does not exist yet is created with its folders

  @backlog
  Scenario: Antigravity's questions are answered by picking one of its options
    When Antigravity asks the user to choose between options
    Then the user is shown the question, or "Choose an option." when Antigravity gave none
    And can pick exactly one of the options and cannot type a different answer
    And an answer that matches no single option leaves the question open

  @backlog
  Scenario: An Antigravity approval offers only the choices Antigravity gives
    Given Antigravity asks for approval and offers only to allow once or to reject
    When the user sees the request
    Then "Allow once", "Deny" and "Cancel" are offered
    And "Allow for this thread" is not

  @backlog
  Scenario: A command that exits with an error is shown with its exit code
    When a command Antigravity ran exits with code 2
    Then the command is shown with its output, its working folder and the exit code 2

  @backlog
  Scenario: An Antigravity turn that will not stop has its process stopped
    Given the user interrupted an Antigravity turn
    When Antigravity has not confirmed the stop after 15 seconds
    Then its process is stopped
    And the user is told "The ACP agent did not finish cancellation. Its process was stopped."

  # AntigravityAdapterV2.ts: what the Antigravity flavour changes in the shared ACP adapter.
  @backlog
  Scenario: Sending /compact alone to Antigravity compacts its conversation
    Given an Antigravity thread with earlier turns
    When the user sends "/compact" with no attachments and the turn completes
    Then the work log shows "Context compacted" once

  @backlog
  Scenario: Antigravity can read a file the user attached although it is outside the workspace
    Given the user attached a file to an Antigravity message
    When Antigravity asks for that file at the path the message names
    Then Antigravity receives the file's contents
    And a path outside both the workspace and HAL-C2's attachments is still refused

  @backlog
  Scenario: An Antigravity subagent batch says what it started
    When Antigravity starts a subagent batch
    Then the batch is titled "Antigravity subagent batch"
    And it shows the batch's own output, or else its detail, or else its title

  @backlog
  Scenario Outline: An Antigravity subagent batch is not finished until its turn is
    Given Antigravity reported that a subagent batch started successfully
    When the turn <ending>
    Then the batch is shown as <state>

    Examples:
      | ending                 | state       |
      | is still running       | running     |
      | completes              | idle        |
      | is stopped by the user | interrupted |
      | fails                  | failed      |

  @backlog
  Scenario: A failed Antigravity subagent batch shows what went wrong
    When an Antigravity subagent batch fails
    Then the batch is shown as failed
    And its output is shown as its result

  @backlog
  Scenario: An Antigravity runtime that cannot be set up fails the turn with the reason
    Given the Antigravity runtime cannot be set up for the instance
    When the user sends a message in an Antigravity thread
    Then the turn fails with the setup problem's own explanation

  # AntigravitySkills.ts: the corners of reading Antigravity's skill folders.
  @backlog
  Scenario Outline: An Antigravity skill found in two folders is offered once, from the folder read first
    Given a skill "deploy" exists in <first> and in <second>
    When the user opens the skill list in an Antigravity thread
    Then "deploy" is offered once, from <first>

    Examples:
      | first                                     | second                                    |
      | the user's .gemini/config/skills          | the project's .gemini/skills              |
      | the project's .gemini/skills              | the user's .gemini/antigravity-cli/skills |
      | the user's .gemini/antigravity-cli/skills | the project's .agents/skills              |
      | the project's .agents/skills              | the project's .agent/skills               |

  @backlog
  Scenario: Antigravity skills are read one folder below a skill folder and no deeper
    Given the project's ".agents/skills" holds the skill "deploy" in "deploy" and the skill "audit" in "team/audit"
    When the user opens the skill list in an Antigravity thread
    Then "deploy" is offered
    And "audit" is not offered

  @backlog
  Scenario: A skill folder that is itself one skill offers only that skill
    Given the project's ".agents/skills" holds a skill file of its own and further skills in folders below it
    When the user opens the skill list in an Antigravity thread
    Then only the skill of the skill folder itself is offered

  @backlog
  Scenario Outline: An Antigravity skill file that does not describe a skill is left out
    Given the project has a skill folder whose skill file <problem>
    When the user opens the skill list in an Antigravity thread
    Then that skill is not offered
    And the other skills are still offered

    Examples:
      | problem                                         |
      | has no header block                             |
      | has a header that is not valid                  |
      | gives a name with a space before or after it    |

  @backlog
  Scenario: An Antigravity skill file is found whatever the letter case of its name
    Given the project has a skill folder "deploy" whose skill file is named "skill.md"
    When the user opens the skill list in an Antigravity thread
    Then the skill of that folder is offered

  @backlog
  Scenario: One Antigravity skill file over 1 MB stops the whole skill search
    Given the project has a skill file larger than 1 MB at "/w/.agents/skills/manual/SKILL.md"
    When the MC reads the Antigravity skills
    Then reading fails with "Antigravity skill discovery exceeded its scan limit at '/w/.agents/skills/manual/SKILL.md'."
    And no partial skill list is offered

  @backlog
  Scenario: Antigravity skill folders that cannot be read are reported instead of skipped
    Given the MC is not allowed to read the project's skill folder "/w/.agents/skills"
    When the user opens the skill list in an Antigravity thread
    Then the list fails with "Could not read Antigravity workspace skills."
    And the reason names "Antigravity could not read skills at '/w/.agents/skills'."
    But a skill folder that does not exist is simply skipped

  # AntigravityDriver.ts: each step of preparing the runtime names itself when it fails.
  @backlog
  Scenario Outline: An Antigravity runtime that cannot be prepared says which step failed
    Given <problem>
    When the MC prepares an Antigravity runtime for the instance
    Then it fails with "<message>"

    Examples:
      | problem                                                     | message                                                 |
      | the instance's temporary folder cannot be created           | Could not create an Antigravity runtime temp directory. |
      | the folder used to check the instance cannot be created     | Could not create an Antigravity setup workspace.        |
      | the instance's status cannot be prepared for another reason | Could not prepare the Antigravity provider status.      |

  # Legacy runs its sign-in helper on Node.js; whether the MC needs Node.js at all is open.
  @backlog
  Scenario: Antigravity sign-in without Node.js on the machine says what to install
    Given Node.js cannot be found on the machine running the MC
    When an Antigravity session is prepared
    Then it fails with "Antigravity sign-in requires Node.js. Install Node.js and make sure node is on PATH, then retry."

  # AntigravityAcpSupport.ts, AntigravityClientFiles.ts, AntigravitySessionFiles.ts: the corners of
  # models, attachments and workspace files.
  @backlog
  Scenario Outline: A thread on Antigravity's default model runs on the model HAL-C2 prefers when the account has it
    Given an Antigravity thread uses the default model
    When a turn starts and <situation>
    Then <outcome>

    Examples:
      | situation                                                | outcome                                             |
      | the account offers the model HAL-C2 ships as its default | the turn runs on that model                         |
      | the account does not offer that model                    | the turn runs on the model Antigravity has selected |
      | Antigravity already has that model selected              | Antigravity is not asked to change its model        |

  @backlog
  Scenario Outline: An attachment Antigravity cannot be sent says what is wrong with it
    When the user sends an Antigravity message with <attachment>
    Then the message is refused with "<message>"
    And the typed text is not sent without the attachment

    Examples:
      | attachment                                                    | message                                                                                                                                               |
      | the 2 MiB text file "big.txt"                                 | Attachment 'big.txt' is too large. Antigravity accepts text files up to 1 MiB, images up to 10 MiB, audio up to 20 MiB, and 50 MiB total attachments. |
      | "notes.txt" whose upload is no longer stored                  | Could not read attachment 'notes.txt'.                                                                                                                |
      | the pasted text "pasted.txt" whose upload is no longer stored | Could not read attachment 'pasted.txt'.                                                                                                               |
      | "notes.txt" whose stored id is not valid                      | Invalid attachment 'notes.txt'.                                                                                                                       |

  @backlog
  Scenario Outline: A workspace file request Antigravity cannot be served says why
    When Antigravity asks to <request> and <problem>
    Then the request is refused with "<message>"

    Examples:
      | request           | problem                           | message                                             |
      | read "/etc/hosts" | the path is outside the workspace | Path '/etc/hosts' is outside the session workspace. |
      | read "/w/app.ts"  | the file cannot be read           | Could not read '/w/app.ts'.                         |
      | write "/w/app.ts" | the file cannot be written        | Could not write '/w/app.ts'.                        |

  @backlog
  Scenario: A link out of the workspace does not let Antigravity read or write outside it
    Given the workspace holds a link to a folder outside it
    When Antigravity asks for a file through that link
    Then the request is refused as outside the session workspace

  @backlog
  Scenario: Antigravity edits workspace files through HAL-C2 only in chat sessions
    When Antigravity is started for a chat thread
    Then it is told HAL-C2 reads and writes workspace files for it, and that HAL-C2 runs no terminals for it
    And an Antigravity started for sign-in, a status check or text generation is told HAL-C2 does neither

  @backlog
  Scenario: Session files of a conversation HAL-C2 did not create are left alone
    Given a temporary Antigravity session ended
    When the conversation stored under its id was recorded for a different folder than the temporary one
    Then that conversation's files are not removed
    And a failure to remove temporary files is logged without failing the session

  @backlog
  Scenario: An Antigravity turn cut off before Antigravity confirms it ended stops the process
    Given an Antigravity turn is running
    When the turn is broken off without Antigravity confirming that it ended
    Then the Antigravity process is stopped
    And the session reports "The ACP prompt stopped before the agent confirmed completion."

  # AntigravityProtocol.ts: the corners of approvals, questions and tool results.
  @backlog
  Scenario: Antigravity's warning about a lasting approval is shown with that choice
    Given Antigravity asks for approval and marks its allow-always choice with a security warning
    When the user sees the request
    Then "Allow for this thread" carries that warning
    And a warning longer than 512 characters is cut and ends with "..."

  @backlog
  Scenario Outline: An answer to an Antigravity question may name an option by its label
    Given Antigravity asks a question with the options <options>
    When a client answers "<answer>"
    Then <outcome>

    Examples:
      | options                              | answer   | outcome                   |
      | "Yes" and "No"                       | Yes      | Antigravity is told "Yes" |
      | two options both labelled "Continue" | Continue | the question stays open   |
      | "Yes" and "No"                       | Maybe    | the question stays open   |

  @backlog
  Scenario: Picking an option that sounds like a refusal answers the question and does not cancel it
    Given Antigravity asks a question and one of its options declines
    When the user picks that option
    Then Antigravity is told which option was picked
    And only cancelling the question tells Antigravity it was cancelled

  @backlog
  Scenario: A request from Antigravity whose options cannot be told apart is not shown as a question
    When Antigravity asks a question whose options share an id or have none
    Then the user is not shown a question to pick from

  @backlog
  Scenario: Long Antigravity questions and option labels are shortened
    When Antigravity asks a question longer than 8,000 characters with an option label longer than 512
    Then the question and the label are cut and end with "..."
    And picking the option still tells Antigravity the option's own id

  @backlog
  Scenario: An Antigravity tool that carries a command is shown as a command
    When Antigravity reports a tool with a command line and no kind
    Then the tool is shown as a command with that command line and its working folder
    And a command that exited with an error code is not shown as a failed tool for that reason alone

  @backlog
  Scenario: Images inside Antigravity tool results are not kept, but a local image is still shown
    When an Antigravity tool result carries an inline image and names a local image file
    Then the inline image is not stored with the thread
    And the local image file is offered as a preview
    And an image named by a web address or a file on another machine is not

  @backlog
  Scenario: Antigravity tool data is bounded before it is stored
    When an Antigravity tool reports very large or deeply nested data
    Then each piece of text keeps its last 8,000 characters under "[Earlier output truncated]"
    And at most 512 entries and 64,000 characters of one tool report are kept
    And what Antigravity writes as its answer is not shortened

  @backlog
  Scenario: A tool of another server that is named like Antigravity's subagent tool is not a subagent batch
    Given an MCP server offers a tool called "start_subagent"
    When Antigravity calls that tool
    Then it is shown as a tool call, not as a subagent batch
