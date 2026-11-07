# Sources:
#   https://github.com/pingdotgg/t3code/pull/18454 (prompt links: parser in packages/shared/promptLinks,
#     resolvers in packages/client-runtime/prompt-links, docs/user/prompt-links.md)
#   Cross-domain: mobile/navigation-and-deep-links.feature owns the phone's link schemes;
#   desktop/shell-host.feature owns registering the hal-c2:// handler; source-control/
#   owns checking out a pull request and the threads linked to one.
#
# Upstream's links also had a hosted form on app.t3.codes with a landing page. HAL-C2 has no
# hosted web app, so only the app's own hal-c2:// links are carried.

Feature: Sharing a prompt as a link
  A link opens HAL-C2 with a prompt written in the composer, so a prompt can be shared in a
  post or a pull request comment. The link only fills in a draft: the user reads it and
  sends it, and it never changes the thread's access, branch or worktree.

  Background:
    Given the user's client is connected to "My MacBook"
    And "My MacBook" has the project "shop" from the repository github.com/acme/shop

  @backlog @desktop @mobile
  Scenario: A prompt link opens a draft and never sends it
    When the user opens the link "hal-c2://new?prompt=Add%20a%20dark%20mode&repo=acme/shop"
    Then a new thread draft in "shop" holds "Add a dark mode"
    And nothing is sent until the user sends it

  @backlog @desktop @mobile
  Scenario Outline: A prompt link cannot change how the thread runs
    When the user opens a prompt link for "acme/shop" that also asks for <setting>
    Then the draft keeps the user's own <kept>

    Examples:
      | setting                 | kept             |
      | full access             | access mode      |
      | the branch "release"    | branch           |
      | a new worktree          | workspace choice |

  @backlog @desktop @mobile
  Scenario: A prompt link picks the matching project the user worked in last
    Given "My MacBook" and "Office Mac" both have a project from github.com/acme/shop
    And the user worked in the one on "Office Mac" last
    When the user opens a prompt link for "acme/shop"
    Then the draft is in "shop" on "Office Mac"

  @backlog @desktop @mobile
  Scenario: A fork matches a prompt link only for its own owner
    Given "My MacBook" has the project "shop-fork" from github.com/alice/shop
    When the user opens a prompt link for "alice/shop"
    Then the draft is in "shop-fork"
    When the user opens a prompt link for "bob/shop"
    Then no project is matched

  @backlog @desktop @mobile
  Scenario Outline: A prompt link for a repository the user does not have keeps the prompt
    When the user opens a prompt link for "acme/docs" with the prompt "Fix the typo"
    Then the user is offered to clone "acme/docs" or go on without a project
    When the user chooses to <choice>
    Then <result>
    And the draft holds "Fix the typo"

    Examples:
      | choice                  | result                                       |
      | clone it                | the draft is in the cloned "docs" project    |
      | go on without a project | the draft is under "No project"              |

  @backlog @desktop @mobile
  Scenario: A prompt link without a repository opens on the machine the user used last
    Given the user last worked on "Office Mac"
    When the user opens a prompt link with only a prompt
    Then the draft is under "No project" on "Office Mac"

  @backlog @desktop @mobile
  Scenario Outline: The model a prompt link names is a request
    Given the user's default model is "<default>"
    When the user opens a prompt link for "acme/shop" naming <named>
    Then the draft uses <used>
    And <told>

    Examples:
      | default  | named                                    | used                        | told                                         |
      | Opus 5.5 | the provider "codex" and model "gpt-5.5" | gpt-5.5 on the user's Codex | the user is not told anything                |
      | Opus 5.5 | a provider the user has not set up       | Opus 5.5                    | the user is told the default is used instead |

  @backlog @desktop @mobile
  Scenario: A pull request link opens the thread linked to that pull request
    Given a thread on "Office Mac" is linked to pull request 123 of "acme/shop"
    When the user opens the link "hal-c2://new?pr=acme/shop/123&prompt=Address%20the%20review"
    Then that thread opens with "Address the review" in its composer

  @backlog @desktop
  Scenario: A pull request link with no linked thread asks before checking anything out
    Given no thread is linked to pull request 123 of "acme/shop"
    When the user opens a prompt link for pull request 123 of "acme/shop"
    Then the user is asked "Check out acme/shop#123?" before anything is checked out
    And a checkout opens a thread on it with the prompt in its composer

  # The phone has no confirmation step: nothing runs until Send.
  @backlog @mobile
  Scenario: On the phone a pull request link drafts a worktree that checks out on send
    Given no thread is linked to pull request 123 of "acme/shop"
    When the user opens a prompt link for pull request 123 of "acme/shop"
    Then a new worktree draft for pull request 123 holds the prompt
    And the pull request is checked out only when the user sends it

  @backlog @desktop @mobile
  Scenario: A prompt link to a thread puts the prompt in that thread's composer
    Given "My MacBook" has the thread "Fix checkout"
    When the user opens a link to "Fix checkout" with the prompt "Also cover refunds"
    Then "Fix checkout" opens with "Also cover refunds" in its composer

  @backlog @desktop @mobile
  Scenario: A prompt link asks before replacing what the user already wrote
    Given the user has written "Half a thought" in the composer of "Fix checkout"
    When the user opens a link to "Fix checkout" with the prompt "Also cover refunds"
    Then the user is asked before "Half a thought" is replaced
    When the user declines
    Then the composer still holds "Half a thought"

  @backlog @desktop @mobile
  Scenario: Hidden characters in a linked prompt are removed and warned about
    When the user opens a prompt link whose prompt hides 3 zero-width or direction characters
    Then the draft holds the prompt without them
    And the user is warned that 3 hidden characters were removed and the prompt may be malicious

  @backlog @desktop
  Scenario Outline: The user copies a link to a prompt
    Given the user has written "Add a dark mode" in a thread of "shop"
    When the user chooses "<command>" from the command palette
    Then a link that opens "Add a dark mode" <scope> is on the clipboard

    Examples:
      | command                              | scope                                  |
      | Copy prompt link                     | with no project                        |
      | Copy prompt link with repo and model | in "acme/shop" with the thread's model |

  @backlog @desktop
  Scenario: Copying a prompt link with its repository is offered only for GitHub projects
    Given the thread is in a project with no GitHub repository
    When the user opens the command palette
    Then "Copy prompt link with repo and model" is not offered

  @backlog @desktop @mobile
  Scenario: A sent message can be shared as a prompt link
    Given the user sent "Add a dark mode" in a thread
    When the user copies a prompt link from that message
    Then a link that opens "Add a dark mode" is on the clipboard

  # Upstream's hosted landing page let a browser open the app, continue in the browser or get
  # the app. HAL-C2 has no hosted web app.
  @dropped @desktop
  Scenario: A prompt link opened in a browser offers to open the app
    When the user opens a hosted prompt link in a web browser
    Then the page offers to open it in the app, continue in the browser, or get HAL-C2
