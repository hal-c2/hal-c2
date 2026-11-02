# Sources:
#   the maintainer: "we should reuse the prompt from the timeline in the spaces"
#   features/space/agent-in-page.feature (what an ask is, and how its agent ends)
#   features/composer/model-and-mode.feature, attachments.feature, context-references.feature,
#     drafting-and-sending.feature and editors-and-keys.feature (what the timeline's prompt does)
#   packages/contracts/src/space.ts (space.page.askAgent, space.page.agentTarget)
#   apps/server-ex/lib/hal_c2/space/page_agent.ex
#   apps/desktop-qt/qml/HalC2/Bricks/SpacePage.qml and Composer.qml,
#     apps/desktop-qt/src/native/ComposerController.h (drafts, stash and their targets)
#   apps/mobile-qt/qml/HalC2/Mobile/SpaceScreen.qml (the phone's ask)
#   apps/tui/src/host/spaceState.ts (space.askAgent), apps/tui/src/host/composerState.ts

Feature: A page's prompt is the timeline's prompt
  A page is written from the same prompt a thread is. On a page it still does what the
  page's own prompt did: plain words write a block, `/` picks the kind of block,
  `/visualize` asks for a chart, and words to `@agent` ask an agent about the page.
  An ask takes what the prompt gives a turn: the model and its effort, the mode,
  attachments, mentions and skills. It runs in the project the user last worked in
  unless they pick another, and the prompt says which before it is sent. An ask that
  names none of these is the ask an older client sends, and runs as it always has.

  A page leaves out what belongs to a thread. Its agent runs in the project's own
  checkout, as there is no branch to pick for a page; the thread can go elsewhere after.
  It has one agent at a time, so it asks one model, never several, and has no queue or
  steering: more words for a working agent go to its thread. The agent's approvals,
  questions and plans are asked in its thread. Terminal excerpts, notes on a diff and
  quoted replies come from a thread's terminal, diff and replies, which a page has none of.

  Background:
    Given a connected environment with the thread "Work" in the project "shop"
    And the Space "Research" with the page "Roadmap"
    And "Roadmap" has the blocks "Draft"

  @mc
  Rule: What an ask may choose

    Scenario: An ask runs on the model and effort the user chose
      When the user asks "tidy this" on the page "Roadmap" with another model at high effort
      Then the agent's thread of "Roadmap" uses the model and effort the user chose

    Scenario: An ask runs in the mode the user chose
      When the user asks "tidy this" on the page "Roadmap" planning, with approval for each action
      Then the agent's thread of "Roadmap" plans, with approval for each action

    Scenario: An ask runs in the project the user picked
      Given the project "docs"
      When the user asks "tidy this" on the page "Roadmap" in the project "docs"
      Then the agent's thread of "Roadmap" is in the project "docs"

    Scenario: An ask carries the user's attachments
      When the user asks "tidy this" on the page "Roadmap" with the image "sketch.png"
      Then the agent's thread of "Roadmap" has a message with the image "sketch.png"

    Scenario: An ask carries the user's mentions and skills
      When the user asks "tidy this" on the page "Roadmap" mentioning the file "README.md"
      Then the agent's thread of "Roadmap" has a message that references the file "README.md"

    Scenario: A project that is not on this MC cannot be asked in
      When the user asks "tidy this" on the page "Roadmap" in a project that is not on this MC
      Then the page request is refused with "project"
      And "Roadmap" says nothing about an agent

    Scenario: A model whose provider cannot run is refused, not swapped
      When the user asks "tidy this" on the page "Roadmap" on a model whose provider is turned off
      Then the page request is refused with "turned off"
      And "Roadmap" says nothing about an agent

    Scenario: A picked project with the HAL-C2 tools off cannot be asked to edit a page
      Given the project "docs"
      And the project "docs" keeps agents away from the HAL-C2 tools
      When the user asks "tidy this" on the page "Roadmap" in the project "docs"
      Then the page request is refused with "HAL-C2 tools"

    Scenario: A refused ask leaves its attachments behind
      Given the user asks "tidy this and wait" on the page "Roadmap"
      When the user asks "and wait again" on the page "Roadmap" with the image "sketch.png"
      Then the page request is refused
      And no attachment of the refused ask is kept

  @mc
  Rule: Where an ask would run

    Scenario: The MC says where an ask would run
      Then an ask from a page would run in the project "shop"

    Scenario: Where an ask would run follows the user to another project
      Given the user worked in the thread "Notes" of the project "docs" since
      Then an ask from a page would run in the project "docs"

    Scenario: With no project, the MC says an ask has nowhere to run
      Given no project is left on this MC
      Then an ask from a page would have nowhere to run

  @shared @backlog-mobile @backlog-tui
  Rule: The prompt on a page

    Scenario: Plain words on a page's prompt write a block
      When the user sends "First idea" from the prompt of "Roadmap"
      Then the blocks of "Roadmap" read "Draft, First idea"

    Scenario: A slash on a page's prompt picks the kind of block
      When the user types "/" in the prompt of "Roadmap"
      Then the user is offered the kinds of block, and "Visualize"

    Scenario: Words to @agent on a page's prompt ask an agent
      When the user sends "@agent tidy this" from the prompt of "Roadmap"
      Then "Roadmap" says its agent is working on "tidy this"

    Scenario: The prompt says where an ask would run before it is sent
      When the user starts an ask on "Roadmap"
      Then the prompt of "Roadmap" says the ask runs in the project "shop" on the model of "Work"

    Scenario Outline: An ask from a page's prompt takes what the user chose
      Given the user starts an ask on "Roadmap"
      And the user chooses <choice> in the prompt of "Roadmap"
      When the user sends "tidy this" from the prompt of "Roadmap"
      Then the agent's thread of "Roadmap" has <choice>

      Examples:
        | choice                        |
        | another model                 |
        | high effort                   |
        | planning                      |
        | approval for each action      |
        | the project "docs"            |
        | the image "sketch.png"        |
        | the file "notes.pdf"          |
        | a mention of "README.md"      |
        | the skill "review"            |

      @backlog-desktop @backlog-mobile
      Examples:
        | choice                         |
        | a mention of the thread "Work" |

    Scenario Outline: An ask can be started from anywhere the page is
      When the user asks an agent about "Roadmap" from <entry>
      Then the prompt of "Roadmap" is ready to ask an agent

      Examples:
        | entry              |
        | the page's menu    |
        | the command palette |
        | its keybinding     |

    Scenario: Starting an ask keeps what the user had written
      Given the user typed "tidy this" in the prompt of "Roadmap"
      When the user asks an agent about "Roadmap" from the page's menu
      Then the prompt of "Roadmap" reads "@agent tidy this"

    Scenario: Taking @agent back out writes a block again
      Given the user starts an ask on "Roadmap"
      When the user takes "@agent" out of the prompt of "Roadmap" and sends "Just a note"
      Then the blocks of "Roadmap" read "Draft, Just a note"
      And "Roadmap" says nothing about an agent

    Scenario: The page's prompt stops its agent as a thread's prompt stops a turn
      Given the user asks "@agent tidy this and wait" on the page "Roadmap"
      When the user stops from the prompt of "Roadmap"
      Then "Roadmap" says its agent was stopped

    Scenario: Each page keeps its own draft
      Given the page "Notes" in the Space "Research"
      And the user typed "half a thought" in the prompt of "Roadmap"
      When the user opens "Notes" and comes back to "Roadmap"
      Then the prompt of "Roadmap" reads "half a thought"
      And the prompt of "Notes" is empty

    Scenario: A page's draft is not a thread's
      Given the user typed "half a thought" in the prompt of "Roadmap"
      When the user opens the thread "Work"
      Then the prompt of "Work" does not read "half a thought"

    Scenario: A page's draft can be stashed and brought back
      Given the user typed "half a thought" in the prompt of "Roadmap"
      When the user stashes the prompt of "Roadmap"
      And the user brings "half a thought" back from the stash
      Then the prompt of "Roadmap" reads "half a thought"

    Scenario Outline: The page's prompt edits as the thread's prompt does
      Given the user turned on <editing>
      When the user opens "Roadmap"
      Then the prompt of "Roadmap" edits with <editing>

      Examples:
        | editing   |
        | vim keys  |
        | rich text |

    Scenario: A refused ask keeps the user's words and attachments
      Given the MC refuses the next ask
      And the user attached the image "sketch.png" in the prompt of "Roadmap"
      When the user sends "@agent tidy this" from the prompt of "Roadmap"
      Then the prompt of "Roadmap" reads "@agent tidy this" with the image "sketch.png"
