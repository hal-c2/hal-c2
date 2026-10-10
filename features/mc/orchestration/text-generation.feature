# Sources:
#   apps/server-ex/lib/hal_c2/text_generation.ex (model selection, fallback, thread titles,
#     branch names, output normalization)
#   apps/server-ex/lib/hal_c2/text_generation/prompts.ex, style.ex
#   apps/server/src/textGeneration/ (TextGeneration.ts, TextGenerationPolicy.ts,
#     ThreadTitleLinks.ts, ThreadTitleContext.ts, PiTextGeneration.ts,
#     AntigravityTextGeneration.ts)
#   apps/server/src/textGeneration/TextGenerationUtils.ts (JSON title unwrapping, CLI-not-on-PATH message)
#   apps/server/src/textGeneration/ThreadTitleContext.ts (title context caps, user-first selection, markers, attachments)
#   apps/server/src/textGeneration/ClaudeTextGeneration.ts, CodexTextGeneration.ts, CursorTextGeneration.ts,
#     OpenCodeTextGeneration.ts (per-provider isolation, model lookup, CLI failure text)
#   apps/server/src/textGeneration/ClaudeTextGeneration.test.ts (config dir, slash-command text, thinking setting,
#     custom alias, verbose output reading and rejection)
#   packages/shared/src/assistantCitations.ts (assistantCitationsToPlainText)
#   apps/server/src/textGeneration/TextGenerationPrompts.ts (staged patch cap)
#   apps/server/src/sourceControl/PrTemplateDetection.ts (template lookup order, size cap, plain files only)
#   apps/server/src/sourceControl/SourceControlProviderRegistry.ts, GitHubSourceControlProvider.ts, GitLabSourceControlProvider.ts (resolveLink)
#   apps/server-ex/lib/hal_c2/git_actions.ex (Style.policy, Style.pr_template for commits and PRs)
#   apps/server-ex/lib/hal_c2/settings.ex (project-scoped textGenerationModelSelection,
#     sourceControlWriterModelSelection, sourceControlWritingStyle)
#   The commit flow and writing style instructions are covered in
#   source-control/commit-and-generated-messages.feature; here only who writes and PR templates.
Feature: Generated titles, branch names and source control text
  The engine asks a coding agent for short structured text: a thread's title from
  its first message, a branch name for a new worktree, and commit and pull request
  text. It never gives that agent tools.

  Background:
    Given an MC with a project "demo"

  @mc
  Scenario: Titles use the text generation model
    Given the text generation model is "claude-haiku-4-5" on "claudeAgent"
    When a title is generated for "Fix the login redirect loop"
    Then "claudeAgent" writes it with "claude-haiku-4-5"

  @mc
  Scenario: The default text generation model
    Given no text generation model is chosen
    Then titles are written by "gpt-6-luna" on "codex" with low reasoning effort

  @mc
  Scenario: Branch names use the source control writer when it is usable
    Given the source control writer is "claudeAgent" and the text model is "codex"
    When a branch name is generated
    Then "claudeAgent" writes it

  @mc
  Scenario Outline: Source control text uses the source control writer
    Given the source control writer is "claudeAgent" and the text model is "codex"
    When <text> is generated
    Then "claudeAgent" writes it

    Examples:
      | text                                |
      | a commit message                    |
      | a pull request title and body       |
      | a branch name                       |

  @mc
  Scenario: A project's own model choices override the environment's
    Given the environment's source control writer is "codex"
    And project "demo" overrides the source control writer with "claudeAgent"
    When a commit message is generated for "demo"
    Then "claudeAgent" writes it

  @mc
  Scenario: An unusable writer falls back to the text model
    Given the source control writer is a disabled provider and the text model is "codex"
    When a branch name is generated
    Then "codex" writes it

  @mc
  Scenario Outline: An unusable text model falls back to the first usable provider with its default model
    Given the text model's provider cannot be used and only <provider> is installed and enabled
    When a title is generated
    Then <provider> writes it with <model>

    Examples:
      | provider      | model              |
      | "codex"       | "gpt-6-luna"       |
      | "claudeAgent" | "claude-haiku-4-5" |
      | "cursor"      | "composer-2"       |
      | "grok"        | "grok-build"       |
      | "opencode"    | "openai/gpt-5"     |

  @mc
  Scenario: No usable provider at all
    Given no provider that can write text is installed and enabled
    When a title is generated
    Then it fails with "No text generation provider is available. Install Claude Code or Codex, or enable another provider."

  @backlog @mc
  Scenario: A writing CLI missing from PATH is named in the failure
    Given the text model is "codex" and the codex CLI is not on PATH
    When a title is generated
    Then it fails saying the codex CLI is required but not available on PATH

  @mc
  Scenario Outline: The writing agent gets no tools
    When <provider> writes a title
    Then it runs <how>

    Examples:
      | provider      | how                                                              |
      | "claudeAgent" | as a one-shot prompt with a JSON answer schema and no tools      |
      | "codex"       | as a one-shot exec in a read-only sandbox                        |
      | "opencode"    | as one prompt in an empty folder with every tool request refused |

  # Legacy: apps/server/src/textGeneration/ClaudeTextGeneration.ts (disableAllHooks, --strict-mcp-config, temp folder)
  # Likely already implemented: apps/server-ex/lib/hal_c2/text_generation.ex (claude args, isolate)
  @backlog @mc
  Scenario: Claude writes in an empty folder with no hooks, commands or MCP servers
    When "claudeAgent" writes a title
    Then it runs in a new temporary folder that is removed afterwards
    And the user's hooks, slash commands and MCP servers are not loaded

  # Legacy: apps/server/src/textGeneration/ClaudeTextGeneration.test.ts ("runs Claude text generation with the configured CLAUDE_CONFIG_DIR")
  # Likely already implemented: apps/server-ex/lib/hal_c2/text_generation.ex (claude_command per instance)
  @backlog @mc
  Scenario: Claude writes with the home of the instance chosen for text generation
    Given the text model is on a Claude instance with its own home folder
    When a title is generated
    Then Claude is run with that instance's home as its configuration folder

  # Legacy: apps/server/src/textGeneration/ClaudeTextGeneration.test.ts ("generates branch names from skill prompts without executable capabilities")
  @backlog @mc
  Scenario: A message that looks like a slash command is text for the writer, not a command
    Given a first message "/call-script"
    When a branch name is generated
    Then the writer is given "/call-script" as text to name
    And no script or skill runs

  # Legacy: apps/server/src/textGeneration/ClaudeTextGeneration.test.ts ("forwards Claude thinking settings without passing unsupported effort")
  # Uncertain: the legacy test names a model whose effort is unsupported; the exact capability rule was not reread.
  @backlog @mc
  Scenario: A model's thinking choice is passed as a setting and unsupported effort is left out
    Given the text model has a thinking switch turned off and an effort chosen
    And the model does not take an effort option
    When a commit message is generated
    Then Claude is run with thinking turned off in its settings
    And no effort option is passed

  # Legacy: apps/server/src/textGeneration/ClaudeTextGeneration.test.ts ("keeps a configured custom alias opaque to the Claude CLI")
  @backlog @mc
  Scenario: A custom model alias is passed to Claude unchanged
    Given the text model is a custom alias the user configured
    When a title is generated
    Then Claude is run with the alias exactly as configured

  # Legacy: apps/server/src/textGeneration/ClaudeTextGeneration.test.ts (verbose output rejection cases)
  @backlog @mc
  Scenario Outline: Claude output without a final structured result gives no title
    When "claudeAgent" writes a title and its output is <output>
    Then text generation fails

    Examples:
      | output                                                                   |
      | an empty list of messages                                                |
      | messages with no final result                                            |
      | a final result whose title is not text                                   |
      | a final result with no answer after an earlier result that had one       |

  # Legacy: apps/server/src/textGeneration/ClaudeTextGeneration.test.ts (verbose output with init, assistant and rate-limit messages)
  @backlog @mc
  Scenario: A title is read from Claude's final result among other messages
    When "claudeAgent" writes a title and its output holds start-up, assistant and rate-limit messages before the result
    Then the title is taken from the final result

  # Legacy: apps/server/src/textGeneration/CursorTextGeneration.ts (plan mode, temp folder, sandbox.json refusal)
  # Likely already implemented: apps/server-ex/lib/hal_c2/text_generation.ex (cursor)
  @backlog @mc
  Scenario: Cursor writes in plan mode in an empty folder
    When "cursor" writes a title
    Then it runs in plan mode in a new temporary folder
    And it is stopped if it does not answer in 3 minutes

  # Legacy: apps/server/src/textGeneration/CursorTextGeneration.ts (the SDK loads sandbox.json on its own)
  # Likely already implemented: apps/server-ex/lib/hal_c2/text_generation.ex (sandbox.json check)
  @backlog @mc
  Scenario: Cursor does not write text when the user's sandbox file would loosen isolation
    Given the user has a custom "~/.cursor/sandbox.json"
    When "cursor" is asked to write a title
    Then it fails saying Cursor text generation cannot enforce workspace isolation with that file and to use another provider

  # Legacy: apps/server/src/textGeneration/AntigravityTextGeneration.ts (global hooks and MCP refusal, tool work refused)
  # Likely already implemented: apps/server-ex/lib/hal_c2/text_generation.ex (Antigravity refusals)
  @backlog @mc @plugin-antigravity
  Scenario Outline: Antigravity does not write text where its own configuration could act first
    Given the Antigravity profile <config>
    When "antigravity" is asked to write a title
    Then it fails saying text generation is unavailable for that profile and to select another system model

    Examples:
      | config                              |
      | has global hooks                    |
      | has MCP servers configured          |

  # Legacy: apps/server/src/textGeneration/AntigravityTextGeneration.ts (default mode, tool and file requests stop the run)
  # Likely already implemented: apps/server-ex/lib/hal_c2/text_generation.ex
  @backlog @mc @plugin-antigravity
  Scenario: Antigravity is stopped when it reaches for a tool or a file
    When "antigravity" writes a title and asks to run a command or read a file
    Then the run is stopped and text generation fails

  # Legacy: apps/server/src/textGeneration/PiTextGeneration.ts (no tools, no extensions), OpenCodeTextGeneration.ts (provider/model format)
  # Likely already implemented: apps/server-ex/lib/hal_c2/text_generation.ex (Pi provider/model)
  @backlog @mc
  Scenario Outline: A writing model that is not a provider/model pair is refused
    Given the text model is "sonnet" on a <provider> instance
    When a title is generated
    Then it fails saying the model must use the provider/model format

    Examples:
      | provider   |
      | "opencode" |
      | "pi"       |

  # Legacy: apps/server/src/textGeneration/CodexTextGeneration.ts (model slug lookup before exec)
  @backlog @mc
  Scenario: A Codex family name is written with the family's first installed model
    Given the text model names a Codex model family rather than a model Codex lists
    And Codex lists a built-in model of that family
    When a title is generated
    Then Codex is run with that listed model
    And a name that matches no listed model is passed to Codex as written

  # Legacy: apps/server/src/textGeneration/ClaudeTextGeneration.ts, CodexTextGeneration.ts (exit code failure text)
  @backlog @mc
  Scenario Outline: A writing CLI that fails says what it printed
    When "<provider>" writes a title and its CLI exits with code 1 <printing>
    Then it fails naming the operation and saying "<message>"

    Examples:
      | provider      | printing           | message                                |
      | claudeAgent   | after printing "x" | Claude CLI command failed: x           |
      | claudeAgent   | with no output     | Claude CLI command failed with code 1. |
      | codex         | after printing "x" | Codex CLI command failed: x            |
      | codex         | with no output     | Codex CLI command failed with code 1.  |

  # Legacy: apps/server/src/textGeneration/TextGenerationUtils.ts (normalizeCliError), TextGenerationPrompts.test.ts
  @backlog @mc
  Scenario: A failure that is not the CLI's own output does not show its details
    When a commit message is generated and the writer's process fails with an error that holds an access token
    Then the failure says "Failed to generate a commit message"
    And the token is not in the failure

  # Legacy: apps/server/src/textGeneration/CursorTextGeneration.ts (run status checks, credential lookup), CursorTextGeneration.test.ts
  @backlog @mc
  Scenario Outline: A Cursor run that did not finish well gives no title even if it printed one
    When "cursor" writes a title and the run ends <ending> after printing a valid title
    Then it fails with "<message>"

    Examples:
      | ending            | message                                    |
      | with an error     | Cursor SDK request finished with an error. |
      | cancelled         | Cursor SDK request was cancelled.          |

  # Legacy: apps/server/src/textGeneration/CursorTextGeneration.ts (requires a key or sign-in), CursorTextGeneration.test.ts
  @backlog @mc
  Scenario: Cursor is not asked to write text without a sign-in or key
    Given Cursor is not signed in and has no API key
    When "cursor" is asked to write a title
    Then it fails saying to sign in with Cursor or add CURSOR_API_KEY in provider settings
    And Cursor is not called

  # Legacy: apps/server/src/textGeneration/CursorTextGeneration.test.ts ("resolves the browser credential for every request after an account change")
  @backlog @mc
  Scenario: Cursor writes with the account that is signed in now
    Given Cursor wrote a title while one account was signed in
    When the user signs in with another account and a title is generated
    Then Cursor is called with the other account's credential

  # Legacy: apps/server/src/textGeneration/CursorTextGeneration.ts (timeouts of 5 seconds on cancel and dispose)
  @backlog @mc
  Scenario: A Cursor run that times out is cancelled and its resources released
    Given a Cursor title run does not finish within 3 minutes
    Then the run is cancelled
    And the SDK's resources are released even if they only become available late

  # Legacy: apps/server/src/textGeneration/OpenCodeTextGeneration.ts (image parts only), OpenCodeTextGeneration.test.ts
  @backlog @mc
  Scenario: Only images are sent with a title request to OpenCode
    Given a message with an image and a PDF attached
    When "opencode" writes a title
    Then the writer receives the message and the image
    And the PDF is not sent

  # Legacy: apps/server/src/textGeneration/OpenCodeTextGeneration.ts (warm server, idle TTL), OpenCodeTextGeneration.test.ts
  @backlog @mc
  Scenario: OpenCode's server is kept warm between requests and closed when idle
    Given OpenCode writes text on a server the MC started
    When two commit messages are generated one after the other
    Then both use the same server
    When the server has been idle for a while
    Then it is closed
    And the next request starts a new one

  # Legacy: apps/server/src/textGeneration/OpenCodeTextGeneration.ts (configured server URL, auth), OpenCodeTextGeneration.test.ts
  @backlog @mc
  Scenario: A configured OpenCode server is used as is and never closed by the MC
    Given OpenCode is set up with the URL of a server the user runs
    When commit messages are generated
    Then they use that server without starting another
    And it is not closed when idle
    And a password that is only in the MC's environment is not sent to it
    And the password saved in the OpenCode settings is

  # Legacy: apps/server/src/textGeneration/OpenCodeTextGeneration.ts (connection check before the session), OpenCodeTextGeneration.test.ts
  @backlog @mc
  Scenario: An OpenCode server that is too old is refused before a session is created
    Given a configured OpenCode server older than the supported version
    When a commit message is generated
    Then it fails saying the version is too old and which version to upgrade to
    And no session is created

  # Legacy: apps/server/src/textGeneration/AntigravityTextGeneration.ts (rejects a helper that writes files in its temporary workspace)
  # Likely already implemented: apps/server-ex/lib/hal_c2/text_generation.ex ("Antigravity wrote files during text generation.")
  @backlog @mc @plugin-antigravity
  Scenario: Antigravity that left files in its temporary folder does not give a title
    When "antigravity" writes a title and leaves a file in its working folder
    Then it fails saying Antigravity wrote files during text generation
    And the folder and the session it made are removed

  # Legacy: apps/server/src/textGeneration/GrokTextGeneration.ts, GrokTextGeneration.test.ts
  @backlog @mc
  Scenario Outline: Grok's answer must hold the JSON that was asked for
    When "grok" writes a title and answers <answer>
    Then <outcome>

    Examples:
      | answer                                           | outcome                                |
      | a JSON object inside conversational text         | the object is used                     |
      | nothing                                          | text generation fails                  |
      | text that holds no valid JSON                    | text generation fails                  |

  # Legacy: apps/server/src/textGeneration/CodexTextGeneration.ts (image inputs by attachment id)
  # Likely already implemented: apps/server-ex/lib/hal_c2/text_generation.ex (images/1)
  @backlog @mc
  Scenario: Codex gets each attached image as an image input and skips missing ones
    Given a message with two images attached and one of them no longer stored
    When "codex" writes a title
    Then Codex receives the stored image as an image input
    And the missing one is left out without failing

  @backlog @mc
  Scenario: A very large change is cut before the commit writer sees it
    Given the staged change is far larger than the writer's prompt limit
    When a commit message is generated
    Then the writer receives only the first 40,000 characters of the staged patch

  @mc
  Scenario: A writing agent that does not answer in time is stopped
    Given the writing agent does not answer within 3 minutes
    Then text generation fails and the agent's process is stopped

  @mc
  Scenario Outline: Titles are cleaned up
    When the writing agent answers the title <raw>
    Then the title is <title>

    Examples:
      | raw                                  | title                                        |
      | "  Fix login loop  "                 | "Fix login loop"                             |
      | a first line and a second line       | the first line                               |
      | wrapped in quotes or backticks       | the text without the quotes                  |
      | with runs of spaces and tabs         | the text with single spaces                  |
      | 200 characters long                  | the first 117 characters followed by "..."   |
      | empty                                | "New thread"                                 |

  @backlog @mc
  Scenario: A title the writer wraps in a JSON object is unwrapped
    When the writing agent answers the title as a JSON object with a "title" field
    Then the title is the text of that field

  @mc
  Scenario: The agent can ask for the title to be refined later
    When the writing agent answers a title and says it needs refinement
    Then the title result says it needs refinement

  @backlog @mc
  Scenario: A long thread gives the title writer only its recent context
    Given a thread whose messages together run past 8,000 characters
    When a title is generated for that thread
    Then the writer is given at most 8,000 characters of messages
    And each message is cut to 2,000 characters

  # Legacy: apps/server/src/textGeneration/ThreadTitleContext.ts (formatThreadTitleContext), ThreadTitleContext.test.ts
  # Likely already implemented: apps/server-ex/lib/hal_c2/text_generation/prompts.ex (thread_context)
  @backlog @mc
  Scenario: Long assistant output cannot push out what the user asked
    Given a thread whose assistant replies are each far longer than 2,000 characters
    And the user changed the scope of the task in a late message
    When a title is generated for that thread
    Then the first user message and the user's later messages are all in the context
    And the assistant replies take only the space the user's messages left

  # Legacy: apps/server/src/textGeneration/ThreadTitleContext.ts (OMITTED and TRUNCATED markers)
  # Likely already implemented: apps/server-ex/lib/hal_c2/text_generation/prompts.ex
  @backlog @mc
  Scenario: A cut message keeps both of its ends and says it was cut
    Given a user message longer than the space it is given
    When a title is generated for that thread
    Then the writer sees the start and the end of the message with "[Content truncated]" between them
    And when messages were left out the context begins with "[Earlier content truncated]"

  # Legacy: apps/server/src/textGeneration/ThreadTitleContext.ts (system and reasoning roles dropped)
  # Likely already implemented: apps/server-ex/lib/hal_c2/text_generation/prompts.ex
  @backlog @mc
  Scenario: Reasoning traces and system notes are not part of a title's context
    Given a thread with user messages, assistant replies, reasoning traces and system notes
    When a title is generated for that thread
    Then only the user and assistant messages are given to the writer
    And each is labelled "USER:" or "ASSISTANT:"

  # Legacy: apps/server/src/textGeneration/ThreadTitleContext.ts (attachment names, first plus last three)
  # Likely already implemented: apps/server-ex/lib/hal_c2/text_generation/prompts.ex
  @backlog @mc
  Scenario: Attachments are named and at most four are sent
    Given a thread whose first message has an image and whose later messages have five more
    When a title is generated for that thread
    Then each message lists its attachments by name as "[Attachments: ...]"
    And the writer receives the first message's image and the three most recent ones

  # Legacy: apps/server/src/textGeneration/ThreadTitleContext.ts (assistantCitationsToPlainText), packages/shared/src/assistantCitations.ts
  @backlog @mc
  Scenario: A quoted reply the user commented on is given to the title writer as plain text
    Given a user message that cites part of an assistant reply and adds a comment
    When a title is generated for that thread
    Then the writer sees the cited words followed by "Comment:" and the comment
    And no citation link syntax is in the context

  @mc
  Scenario: GitHub links in a message give the title writer context
    When a title is generated for a message linking a github.com pull request and an issue
    Then the writer is given each linked item's title and the start of its body

  @mc
  Scenario: At most two linked items are looked up, each within 3 seconds
    When a title is generated for a message linking four github.com issues and one is slow
    Then only the first two are looked up
    And a lookup that takes longer than 3 seconds is reported as unavailable

  @mc
  Scenario: Links to other hosts are never looked up
    When a title is generated for a message linking a pull request on another host
    Then no credentials are used to look it up

  # Legacy: apps/server/src/sourceControl/SourceControlProviderRegistry.ts (resolveLink), GitHubSourceControlProvider.ts, GitLabSourceControlProvider.ts (resolveLink)
  # Legacy: apps/server/src/textGeneration/ThreadTitleLinks.ts (resolveThreadTitleLinks)
  @mc @backlog
  Scenario Outline: Only a link to a pull request, merge request or issue is looked up
    When a title is generated for a message linking <link>
    Then <outcome>

    Examples:
      | link                                                       | outcome                                                    |
      | a github.com repository page                               | nothing is looked up                                       |
      | a gitlab.com merge request or issue in a nested group      | its title and description are looked up                    |
      | a github.com pull request over plain http                  | nothing is looked up                                       |
      | a github.com pull request whose link carries a user name   | nothing is looked up                                       |
      | a github.com pull request number that is zero              | nothing is looked up                                       |

  # Legacy: apps/server/src/textGeneration/ThreadTitleLinks.ts (providers select supported links before the budget)
  @mc @backlog
  Scenario: Links that cannot be looked up do not use up the two lookups
    When a title is generated for a message linking a repository page, a pull request on another host and then two github.com issues
    Then both issues are looked up

  @mc
  Scenario: Attached images go to the title writer
    When a title is generated for a message with an image attachment
    Then the writer receives the image

  @mc
  Scenario Outline: Branch names are made safe
    When the writing agent answers the branch <raw>
    Then the branch fragment is <fragment>

    Examples:
      | raw                          | fragment                 |
      | "Fix Login Loop"             | "fix-login-loop"         |
      | "feature/'quoted' name"      | "feature/quoted-name"    |
      | "a//b--c"                    | "a/b-c"                  |
      | "--leading and trailing--"   | "leading-and-trailing"   |
      | 100 letters                  | the first 64 letters     |
      | "!!!"                        | "update"                 |

  @mc @plugin-pi
  Scenario: Pi can write titles and branch names
    Given the text model is on a "pi" instance
    When a title is generated
    Then "pi" writes it

  @mc @plugin-antigravity
  Scenario: Antigravity can write titles and branch names
    Given the text model is on an "antigravity" instance
    When a title is generated
    Then "antigravity" writes it

  @mc
  Scenario: A pull request follows the repository's template
    Given the project follows pull request templates
    And the base branch has ".github/pull_request_template.md"
    When pull request text is generated
    Then the writer is given that template for the body

  @mc
  Scenario Outline: No template is given when none can be chosen
    Given <situation>
    When pull request text is generated
    Then the writer is given no template

    Examples:
      | situation                                                            |
      | the project does not follow pull request templates                   |
      | the base branch has two templates in ".github/PULL_REQUEST_TEMPLATE" |
      | the template exists only in the working copy, not the base branch    |

  # Legacy: apps/server/src/sourceControl/PrTemplateDetection.ts (TEMPLATE_PATHS, TEMPLATE_DIRECTORIES)
  # Likely already implemented: apps/server-ex/lib/hal_c2/text_generation/style.ex
  @mc @backlog
  Scenario Outline: The first template in the usual places is the one used
    Given the base branch has <templates>
    When pull request text is generated
    Then the writer is given <chosen> for the body

    Examples:
      | templates                                                                            | chosen                                      |
      | ".github/pull_request_template.md" and "docs/pull_request_template.md"               | ".github/pull_request_template.md"          |
      | "PULL_REQUEST_TEMPLATE.md" and "docs/PULL_REQUEST_TEMPLATE.md"                       | "PULL_REQUEST_TEMPLATE.md"                  |
      | only one markdown file in ".github/PULL_REQUEST_TEMPLATE"                            | that file                                   |
      | a file in ".github/PULL_REQUEST_TEMPLATE" and "pull_request_template.md"             | "pull_request_template.md"                  |

  # Legacy: apps/server/src/sourceControl/PrTemplateDetection.ts (readTemplateBlob, parseTemplateTreeEntries)
  # Likely already implemented: apps/server-ex/lib/hal_c2/text_generation/style.ex
  @mc @backlog
  Scenario: A very long template is cut and says so
    Given the base branch has a pull request template of 20,000 characters
    When pull request text is generated
    Then the writer is given the first 8,000 bytes of it followed by "[truncated]"

  # Legacy: apps/server/src/sourceControl/PrTemplateDetection.ts (parseTemplateTreeEntries, readTemplateBlob)
  # Likely already implemented: apps/server-ex/lib/hal_c2/text_generation/style.ex
  @mc @backlog
  Scenario Outline: A template that is not a plain file in the base branch is passed over
    Given the base branch has <entry> at ".github/pull_request_template.md"
    When pull request text is generated
    Then the writer is given no template from that path

    Examples:
      | entry                  |
      | a symbolic link        |
      | an empty file          |
      | a file with only blank lines |

  # Legacy: apps/server/src/git/GitManager.ts (runPrStep: templates are read for GitHub only)
  @mc @backlog
  Scenario: Templates are followed only on a host that has them
    Given the project follows pull request templates
    And the base branch has ".github/pull_request_template.md"
    And the project's remote is on GitLab, Forgejo, Azure DevOps or Bitbucket
    When pull request text is generated
    Then the writer is given no template
