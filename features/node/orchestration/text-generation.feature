# Sources:
#   apps/server-ex/lib/t3/text_generation.ex (model selection, fallback, thread titles,
#     branch names, output normalization)
#   apps/server-ex/lib/t3/text_generation/prompts.ex, style.ex
#   apps/server/src/textGeneration/ (TextGeneration.ts, TextGenerationPolicy.ts,
#     ThreadTitleLinks.ts, ThreadTitleContext.ts, PiTextGeneration.ts,
#     AntigravityTextGeneration.ts)
#   apps/server-ex/lib/t3/git_actions.ex (Style.policy, Style.pr_template for commits and PRs)
#   apps/server-ex/lib/t3/settings.ex (project-scoped textGenerationModelSelection,
#     sourceControlWriterModelSelection, sourceControlWritingStyle)
#   The commit flow and writing style instructions are covered in
#   source-control/commit-and-generated-messages.feature; here only who writes and PR templates.
Feature: Generated titles, branch names and source control text
  The engine asks a coding agent for short structured text: a thread's title from
  its first message, a branch name for a new worktree, and commit and pull request
  text. It never gives that agent tools.

  Background:
    Given a node with a project "demo"

  @node
  Scenario: Titles use the text generation model
    Given the text generation model is "claude-haiku-4-5" on "claudeAgent"
    When a title is generated for "Fix the login redirect loop"
    Then "claudeAgent" writes it with "claude-haiku-4-5"

  @node
  Scenario: The default text generation model
    Given no text generation model is chosen
    Then titles are written by "gpt-6-luna" on "codex" with low reasoning effort

  @node
  Scenario: Branch names use the source control writer when it is usable
    Given the source control writer is "claudeAgent" and the text model is "codex"
    When a branch name is generated
    Then "claudeAgent" writes it

  @node
  Scenario Outline: Source control text uses the source control writer
    Given the source control writer is "claudeAgent" and the text model is "codex"
    When <text> is generated
    Then "claudeAgent" writes it

    Examples:
      | text                                |
      | a commit message                    |
      | a pull request title and body       |
      | a branch name                       |

  @node
  Scenario: A project's own model choices override the environment's
    Given the environment's source control writer is "codex"
    And project "demo" overrides the source control writer with "claudeAgent"
    When a commit message is generated for "demo"
    Then "claudeAgent" writes it

  @node
  Scenario: An unusable writer falls back to the text model
    Given the source control writer is a disabled provider and the text model is "codex"
    When a branch name is generated
    Then "codex" writes it

  @node
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

  @node
  Scenario: No usable provider at all
    Given no provider that can write text is installed and enabled
    When a title is generated
    Then it fails with "No text generation provider is available. Install Claude Code or Codex, or enable another provider."

  @node
  Scenario Outline: The writing agent gets no tools
    When <provider> writes a title
    Then it runs <how>

    Examples:
      | provider      | how                                                              |
      | "claudeAgent" | as a one-shot prompt with a JSON answer schema and no tools      |
      | "codex"       | as a one-shot exec in a read-only sandbox                        |
      | "opencode"    | as one prompt in an empty folder with every tool request refused |

  @node
  Scenario: A writing agent that does not answer in time is stopped
    Given the writing agent does not answer within 3 minutes
    Then text generation fails and the agent's process is stopped

  @node
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

  @node
  Scenario: The agent can ask for the title to be refined later
    When the writing agent answers a title and says it needs refinement
    Then the title result says it needs refinement

  @node
  Scenario: GitHub links in a message give the title writer context
    When a title is generated for a message linking a github.com pull request and an issue
    Then the writer is given each linked item's title and the start of its body

  @node
  Scenario: At most two linked items are looked up, each within 3 seconds
    When a title is generated for a message linking four github.com issues and one is slow
    Then only the first two are looked up
    And a lookup that takes longer than 3 seconds is reported as unavailable

  @node
  Scenario: Links to other hosts are never looked up
    When a title is generated for a message linking a pull request on another host
    Then no credentials are used to look it up

  @node
  Scenario: Attached images go to the title writer
    When a title is generated for a message with an image attachment
    Then the writer receives the image

  @node
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

  @node @backlog @plugin:pi
  Scenario: Pi can write titles and branch names
    Given the text model is on a "pi" instance
    When a title is generated
    Then "pi" writes it

  @node @backlog @plugin:antigravity
  Scenario: Antigravity can write titles and branch names
    Given the text model is on an "antigravity" instance
    When a title is generated
    Then "antigravity" writes it

  @node
  Scenario: A pull request follows the repository's template
    Given the project follows pull request templates
    And the base branch has ".github/pull_request_template.md"
    When pull request text is generated
    Then the writer is given that template for the body

  @node
  Scenario Outline: No template is given when none can be chosen
    Given <situation>
    When pull request text is generated
    Then the writer is given no template

    Examples:
      | situation                                                            |
      | the project does not follow pull request templates                   |
      | the base branch has two templates in ".github/PULL_REQUEST_TEMPLATE" |
      | the template exists only in the working copy, not the base branch    |
