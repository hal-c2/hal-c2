# Sources:
#   features/space/beyond-pages.feature ("The user asks an agent from inside a page")
#   spaces-feature-bdd-tests branch, features/space/collaboration-agents-and-dots.feature and
#     apps/server-ex/lib/hal_c2/space/agent_runner.ex (the prototype; read for ideas only)
#   packages/contracts/src/space.ts (space.page.askAgent, space.page.stopAgent,
#     space.page.dismissAgent, the pageAgent entity)
#   apps/server-ex/lib/hal_c2/space/page_agent.ex
#   features/space/self-updating-pages.feature (where an ask meets a page's own update)
#   features/space/prompt.feature (what an ask may choose)

Feature: An agent in a page
  From an open page the user asks an agent to do something to it. The agent runs in an
  ordinary thread, visible in the sidebar, in the project the user last worked in and on
  the model a new thread there would use, or the one last used if none is set, unless the
  page's prompt chose others (`features/space/prompt.feature`). Its edits
  are the hal_c2_page_* tools' edits: they land live on every client and page history
  names the thread. A page has one such agent at a time, and
  the page says what it is doing. Every edit is in the page's history, so asking needs
  no approval of its own beyond what the provider's mode requires, and anything the
  agent did can be undone by restoring a version.

  Background:
    Given a connected environment with the thread "Work" in the project "shop"
    And the Space "Research" with the page "Roadmap"
    And "Roadmap" has the blocks "Draft"

  @mc @desktop @mobile @tui
  Rule: Asking and following

    Scenario: The page says its agent is working and links to its thread
      When the user asks "@agent tidy this and wait" on the page "Roadmap"
      Then "Roadmap" says its agent is working on "tidy this and wait"
      And "Roadmap" links to its agent's thread

    Scenario: The agent's edits land live and name its thread
      Given a second client watching the Space "Research"
      And the user asks "tidy this and wait" on the page "Roadmap"
      When the agent of "Roadmap" adds the block "Agent note"
      Then the second client sees the block "Agent note"
      And the block "Agent note" was written by the agent of "Roadmap"

    Scenario: The page says when its agent has finished
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the agent of "Roadmap" adds the block "Agent note"
      When the agent of "Roadmap" finishes
      Then "Roadmap" says its agent finished and changed the page

    Scenario: An agent that changed nothing says so
      Given the user asks "tidy this and wait" on the page "Roadmap"
      When the agent of "Roadmap" finishes
      Then "Roadmap" says its agent finished without changing the page

    Scenario: The user stops the agent, and the page stays as it last wrote it
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the agent of "Roadmap" adds the block "Agent note"
      When the user stops the agent of "Roadmap"
      Then "Roadmap" says its agent was stopped
      And the blocks of "Roadmap" read "Draft, Agent note"

    Scenario: A failure shows on the page and leaves it as the agent last wrote it
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the agent of "Roadmap" adds the block "Agent note"
      When the agent of "Roadmap" fails with "out of credits"
      Then "Roadmap" says its agent failed with "out of credits"
      And the blocks of "Roadmap" read "Draft, Agent note"

    Scenario: The user clears what the page says once its agent is done
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the agent of "Roadmap" finishes
      When the user dismisses the agent of "Roadmap"
      Then "Roadmap" says nothing about an agent

    Scenario: A deleted thread ends what the page says, and the page says why
      Given the user asks "tidy this and wait" on the page "Roadmap"
      When the thread of the agent of "Roadmap" is deleted
      Then "Roadmap" says its agent stopped because "its thread was deleted"

    Scenario: A page that updates itself says what its agent and its update are doing apart
      Given "Roadmap" updates itself with "Summarise yesterday's threads" every 2 hours
      When the user asks "@agent tidy this and wait" on the page "Roadmap"
      Then "Roadmap" says its agent is working on "tidy this and wait"
      And "Roadmap" shows the instruction "Summarise yesterday's threads"
      And "Roadmap" shows when it next runs

  @desktop @mobile @tui
  Rule: Following an agent from a client

    Scenario: Following an agent whose thread is gone says so
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the agent of "Roadmap" names a thread this client does not have
      When the user follows the agent of "Roadmap" to its thread
      Then the user is told the agent's thread is not available

  @desktop @mobile @tui
  Rule: The user's way out of an ask

    Scenario: An agent slow to stop can be stopped again
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the agent of "Roadmap" does not stop when asked
      When the user stops the agent of "Roadmap"
      Then "Roadmap" says its agent is stopping
      And the user can stop the agent of "Roadmap" again

    Scenario: A refused ask keeps the user's words
      Given the MC refuses the next ask
      When the user asks "tidy this" on the page "Roadmap"
      Then the words "tidy this" are kept to ask again

  @mc
  Rule: What an ask is

    Scenario: The agent's thread is an ordinary thread of the last project worked in
      When the user asks "tidy this and wait" on the page "Roadmap"
      Then the agent's thread of "Roadmap" is in the project "shop"
      And the agent's thread of "Roadmap" uses the model of "Work"
      And the agent's thread of "Roadmap" has a message naming "Roadmap", "Research" and the page tools

    Scenario Outline: A thread started in the background is not where the user last worked
      Given <starter> started a newer thread in the project "lab"
      When the user asks "tidy this and wait" on the page "Roadmap"
      Then the agent's thread of "Roadmap" is in the project "shop"
      And the agent's thread of "Roadmap" uses the model of "Work"

      Examples:
        | starter  |
        | a plugin |
        | an agent |

    Scenario: A project's model on a turned off provider gives way
      Given the project "shop" overrides its model with one on a turned off provider
      When the user asks "tidy this and wait" on the page "Roadmap"
      Then the agent's thread of "Roadmap" uses the model of "Work"

    Scenario: A model the project keeps itself gives way when its provider is turned off
      Given the project "shop" keeps a model of its own on a turned off provider
      When the user asks "tidy this and wait" on the page "Roadmap"
      Then the agent's thread of "Roadmap" uses the model of "Work"

    Scenario: The model last used gives way when its provider is turned off
      Given the thread "Work" last used a model on a turned off provider
      When the user asks "tidy this and wait" on the page "Roadmap"
      Then the agent's thread of "Roadmap" is on a provider that can run

    Scenario: The word @agent is not part of what is asked
      When the user asks "@agent   tidy this and wait" on the page "Roadmap"
      Then "Roadmap" says its agent is working on "tidy this and wait"

    Scenario: A blank ask is refused
      When the user asks "@agent  " on the page "Roadmap"
      Then the page request is refused
      And "Roadmap" says nothing about an agent

    Scenario: A second ask waits for the first
      Given the user asks "tidy this and wait" on the page "Roadmap"
      When the user asks "and wait again" on the page "Roadmap"
      Then the page request is refused
      And "Roadmap" says its agent is working on "tidy this and wait"

    Scenario: A new ask replaces what the page said about the last one
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the agent of "Roadmap" finishes
      When the user asks "and wait again" on the page "Roadmap"
      Then "Roadmap" says its agent is working on "and wait again"

    Scenario: A page in the trash cannot be asked
      Given the page "Roadmap" is in the trash
      When the user asks "tidy this and wait" on the page "Roadmap"
      Then the page request is refused

    Scenario: With no project there is nothing to run in, and the ask says so
      Given no project is left on this MC
      When the user asks "tidy this and wait" on the page "Roadmap"
      Then the page request is refused with "project"

    Scenario: A project with the HAL-C2 tools off cannot be asked to edit a page
      Given the project "shop" keeps agents away from the HAL-C2 tools
      When the user asks "tidy this and wait" on the page "Roadmap"
      Then the page request is refused with "HAL-C2 tools"

    Scenario: A thread that cannot start shows as a failure on the page
      Given no provider can start a thread
      When the user asks "tidy this and wait" on the page "Roadmap"
      Then "Roadmap" says its agent failed

  @mc
  Rule: A page that updates itself
    An agent and the page's own update work side by side. A run writes only the
    generated part, which the agent cannot edit, so neither waits for the other or
    replaces it, and what a run wrote is not the agent's change.

    Background:
      Given text generation writes "Three threads moved forward"
      And "Roadmap" updates itself with "Summarise yesterday's threads" every 2 hours

    Scenario: The page's update runs while its agent works
      Given the user asks "tidy this and wait" on the page "Roadmap"
      When the user runs the update of "Roadmap" now
      Then the generated part of "Roadmap" reads "Three threads moved forward"
      And "Roadmap" says its agent is working on "tidy this and wait"

    Scenario: A page can be asked while its update runs
      Given a run of "Roadmap" is under way
      When the user asks "tidy this and wait" on the page "Roadmap"
      And the run of "Roadmap" comes back
      Then the generated part of "Roadmap" reads "Three threads moved forward"
      And "Roadmap" says its agent is working on "tidy this and wait"

    Scenario: What the update wrote is not the agent's change
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the user runs the update of "Roadmap" now
      When the agent of "Roadmap" finishes
      Then "Roadmap" says its agent finished without changing the page

    Scenario: The agent cannot rewrite what the update wrote
      Given the update of "Roadmap" has run
      And the user asks "tidy this and wait" on the page "Roadmap"
      When the agent of "Roadmap" tries to edit the generated part
      Then the agent is refused
      And the generated part of "Roadmap" reads "Three threads moved forward"

  @mc
  Rule: How an agent ends

    Scenario: A turn the provider fails says why on the page
      When the user asks "fail at this" on the page "Roadmap"
      Then "Roadmap" says its agent failed with "the turn failed"

    Scenario: A stop does not wait for a command the agent left running
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the agent of "Roadmap" leaves a command running in the background
      And the run of the agent of "Roadmap" ends
      And "Roadmap" says its agent is working on "tidy this and wait"
      When the user stops the agent of "Roadmap"
      Then "Roadmap" says its agent was stopped

    Scenario: Stopping a run still only queued settles the page too
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the user sends "and later" to the agent of "Roadmap" behind its run
      When the user stops the agent of "Roadmap"
      Then "Roadmap" says its agent was stopped
      And the agent's thread of "Roadmap" has no run left to do

    Scenario: A message the user adds keeps the page saying it is working
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the user sends "and later wait" to the agent of "Roadmap" behind its run
      When the agent of "Roadmap" finishes its turn
      Then "Roadmap" says its agent is working on "tidy this and wait"

    Scenario: What the thread does after the page has settled does not touch the page
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the agent of "Roadmap" finishes
      And the user dismisses the agent of "Roadmap"
      When the user sends "say more" to the agent of "Roadmap"
      Then "Roadmap" says nothing about an agent

    Scenario: A message the user took back does not change how the agent ended
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the user sends "and later" to the agent of "Roadmap" behind its run
      And the user cancels the message behind the run of the agent of "Roadmap"
      When the agent of "Roadmap" finishes
      Then "Roadmap" says its agent finished without changing the page

    Scenario: A thread being stopped and then deleted says it was stopped
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the user stops the agent of "Roadmap"
      When the thread of the agent of "Roadmap" is deleted
      Then "Roadmap" says its agent was stopped

    Scenario: A crash before the thread started fails on the page at the next start
      Given the MC goes down before an agent's thread can start
      And the user asks "tidy this" on the page "Roadmap"
      When the MC restarts
      Then "Roadmap" says its agent failed with "before its thread could start"

    Scenario: A report lost to a crash settles the page at the next start
      Given the page is never told how its agent's run ended
      And the user asks "tidy this" on the page "Roadmap"
      When the MC restarts
      Then "Roadmap" says its agent finished without changing the page

    Scenario: A message held behind a restart does not keep the page working
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the user sends "and later" to the agent of "Roadmap" behind its run
      And the agent's thread of "Roadmap" does not continue after a restart
      When the MC restarts
      Then "Roadmap" says its agent stopped because "its run was interrupted"

    Scenario: A restart that ends the run settles the page
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the agent's thread of "Roadmap" does not continue after a restart
      When the MC restarts
      Then "Roadmap" says its agent stopped because "its run was interrupted"

    Scenario: A restart the agent's thread continues from keeps the page working
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the agent's thread of "Roadmap" continues after a restart
      When the MC restarts
      Then the agent's thread of "Roadmap" continues its work
      And "Roadmap" says its agent is working on "tidy this and wait"

    Scenario: A restart does not undo a stop by continuing the thread
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the agent's thread of "Roadmap" continues after a restart
      And the MC goes down as the user stops the agent of "Roadmap"
      When the MC restarts
      Then "Roadmap" says its agent was stopped
      And the agent's thread of "Roadmap" did not go on

    Scenario: A restart does not undo a stop by starting a run from the queue
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the provider never got the run of the agent of "Roadmap"
      And the MC goes down as the user stops the agent of "Roadmap"
      When the MC restarts
      Then "Roadmap" says its agent was stopped
      And the agent's thread of "Roadmap" did not go on

    Scenario: A continuation that cannot start settles the page
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the agent's thread of "Roadmap" continues after a restart
      And the provider the agent's thread of "Roadmap" ran on is gone
      When the MC restarts
      Then "Roadmap" says its agent stopped because "its run was interrupted"

    Scenario: What the page says outlives a restart
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the agent of "Roadmap" finishes
      When the MC restarts
      Then "Roadmap" says its agent finished without changing the page

    Scenario: A finished note cannot be cleared while the agent works
      Given the user asks "tidy this and wait" on the page "Roadmap"
      When the user dismisses the agent of "Roadmap"
      Then the page request is refused
      And "Roadmap" says its agent is working on "tidy this and wait"

    Scenario: There is nothing to stop on a page with no agent
      When the user stops the agent of "Roadmap"
      Then the page request is refused

    Scenario: An agent's edits to a page in the trash are refused, and it can still be stopped
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the page "Roadmap" is in the trash
      When the agent of "Roadmap" tries to add a block
      Then the agent is refused
      When the user stops the agent of "Roadmap"
      Then "Roadmap" says its agent was stopped

    Scenario: A page deleted for good takes what it said about its agent with it
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the agent of "Roadmap" finishes
      And the page "Roadmap" is in the trash
      When the user deletes the page "Roadmap" for good
      Then no Space entity speaks of an agent

    Scenario: An agent's thread ending after its page is deleted leaves the Space alone
      Given the user asks "tidy this and wait" on the page "Roadmap"
      And the page "Roadmap" is in the trash
      And the user keeps the agent's thread of "Roadmap"
      And the user deletes the page "Roadmap" for good
      When the kept agent's thread finishes
      Then no Space entity speaks of an agent

  @mc
  Rule: What each provider can do

    # Codex, Claude, Cursor, Grok, Kimi and the registry ACP agents, Antigravity, a local
    # OpenCode and Pi all get the hal-c2 MCP server, and with it the hal_c2_page_* tools.
    Scenario: An agent on a provider with the tools gets them
      When the user asks "tidy this and wait" on the page "Roadmap"
      Then the agent's thread of "Roadmap" can call the page tools

  @backlog @mc @priority-low
  Rule: Providers that may not get the page tools

    # `features/providers/opencode.feature`: the hal-c2 server is offered only to a local
    # OpenCode. Today such an agent ends with "finished without changing the page".
    Scenario: An external OpenCode server says it cannot edit pages
      Given the project "shop" uses an external OpenCode server
      When the user asks "tidy this" on the page "Roadmap"
      Then "Roadmap" says its agent cannot reach the page tools

    # Muse only takes the server when the host grants `sessionMcp`. Today such an agent
    # ends with "finished without changing the page".
    Scenario: A Muse host without session tools says it cannot edit pages
      Given the project "shop" uses a Muse host that does not grant session tools
      When the user asks "tidy this" on the page "Roadmap"
      Then "Roadmap" says its agent cannot reach the page tools

  @backlog @mc @shared
  Rule: Still to come

    Scenario: The page says when its agent waits for the user
      Given the agent of "Roadmap" asks the user for an approval
      Then "Roadmap" says its agent is waiting for the user and links to the question

    Scenario: The user asks an agent from a comment
      Given the comment "@agent reword this" on the block "Draft"
      Then an agent answers in the comment's thread and edits the block

    Scenario: An agent edits a slide deck
      When the user asks "tighten these slides" on the slide deck "Launch"
      Then an agent edits the deck and its edits name its thread
