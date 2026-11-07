# Sources:
#   https://github.com/pingdotgg/t3code/pull/10439 (find in thread)
#   https://github.com/pingdotgg/t3code/pull/14658
#   docs/user/thread-sidebar.md (Searching threads)
#   apps/web/src/components/Sidebar.tsx (thread search, result keyboard)
#   apps/web/src/components/Sidebar.logic.ts (title search, content matches)
#   apps/web/src/components/ThreadSearchMatch.tsx, search/HighlightedSearchLine.tsx (the excerpt)
#   packages/shared/src/threadPullRequests.ts (threadPullRequestSearchTerms)
#   apps/tui/src/components/Sidebar.logic.ts (filter)
#   apps/tui/src/commands.ts (Filter threads)
#   apps/desktop-qt/qml/HalC2/Bricks/Sidebar.qml (Search opens the palette)
#   packages/contracts/src/rpc.ts (searchThreads)
#   apps/server-ex/lib/hal_c2/search.ex

Feature: Searching threads
  The user finds a thread by its title or by something said in it, across every connected
  environment.

  Background:
    Given a connected environment with the threads "Fix OAuth loop" and "Add dark mode" in the project "shop"

  @tui
  Scenario: Filtering the thread list by title
    When the user filters the thread list by "oauth"
    Then only "Fix OAuth loop" is listed

  @tui
  Scenario: Filtering the thread list by project name
    Given the project "docs" has the thread "Write guide"
    When the user filters the thread list by "docs"
    Then "Write guide" is listed

  @tui
  Scenario: Clearing the filter shows every thread again
    Given the thread list is filtered by "oauth"
    When the user clears the filter
    Then "Fix OAuth loop" and "Add dark mode" are listed

  @desktop
  Scenario: Searching from the thread list opens the command palette
    When the user starts a search from the thread list
    Then the command palette opens ready to search threads

  @backlog @desktop @mobile
  Scenario: Title search ignores case and project details
    When the user searches threads for "DARK"
    Then "Add dark mode" is found
    And threads are not found only because their project matches

  @mc
  Scenario: Searching what was said in threads
    Given the agent in "Add dark mode" said "the palette now reads prefers-color-scheme"
    When a client searches threads for "prefers-color-scheme"
    Then "Add dark mode" is returned with the matching words in a short excerpt

  @mc
  Scenario: A thread is returned once, preferring what the user wrote
    Given the user and the agent both wrote "rate limit" in "Fix OAuth loop"
    When a client searches threads for "rate limit"
    Then "Fix OAuth loop" is returned once
    And its excerpt comes from the user's message

  @mc
  Scenario: Archived and deleted threads are not searched
    Given "Add dark mode" is archived
    When a client searches threads for "dark"
    Then "Add dark mode" is not returned

  @mc
  Scenario: Messages still being written are not searched
    Given the agent is still writing "flaky test" in "Fix OAuth loop"
    When a client searches threads for "flaky test"
    Then "Fix OAuth loop" is not returned until the message is finished

  @mc
  Scenario: Threads from before search existed are searchable
    Given the environment has threads written before it kept a search index
    When the environment starts
    Then the old threads are indexed once and can be searched

  @mc
  Scenario: Search returns at most fifty threads by default
    Given 80 threads mention "refactor"
    When a client searches threads for "refactor"
    Then 50 threads are returned

  @backlog @desktop @mobile
  Scenario: Message search starts after two characters
    When the user types "d" in the thread search
    Then only titles are matched
    When the user types "da"
    Then threads whose messages contain "da" are added below the title matches

  @backlog @desktop
  Scenario Outline: Threads are found by their linked pull requests
    Given "Fix OAuth loop" is linked to pull request 12 "Rotate refresh tokens" of "acme/app"
    When the user searches threads for "<query>"
    Then "Fix OAuth loop" is found

    Examples:
      | query                               |
      | #12                                 |
      | acme/app#12                         |
      | https://github.com/acme/app/pull/12 |
      | refresh tokens                      |

  @backlog @desktop @mobile
  Scenario Outline: Threads are found by their branch's pull request
    Given "Fix OAuth loop" is on a branch whose pull request is 12 of "acme/app", and is not linked to it
    When the user searches threads for "<query>"
    Then "Fix OAuth loop" is found
    And the result says it matched pull request 12

    Examples:
      | query                               |
      | #12                                 |
      | acme/app#12                         |
      | https://github.com/acme/app/pull/12 |

  @backlog @desktop
  Scenario: Threads matching by title or pull request come before threads matching by message
    Given "Add dark mode" has a message containing "oauth"
    When the user searches threads for "oauth"
    Then "Fix OAuth loop" is listed before "Add dark mode"

  @backlog @desktop
  Scenario: A message match shows who said it and highlights the match
    Given the user wrote "Please add OAuth scopes" in "Add dark mode"
    When the user searches threads for "oauth"
    Then the result for "Add dark mode" shows "You:" and an excerpt with "OAuth" highlighted

  @backlog @desktop
  Scenario: A message match from the agent is attributed to the agent
    Given the agent said "The OAuth client is registered" in "Add dark mode"
    When the user searches threads for "oauth"
    Then the result for "Add dark mode" shows "Agent:" and an excerpt with "OAuth" highlighted

  @backlog @desktop
  Scenario: A search that finds nothing says so once the messages were searched
    When the user searches threads for "zzzzqqq"
    Then the list says "Searching thread messages…" while the messages are searched
    And then says "No threads found"

  @desktop @mobile @backlog-mobile
  Scenario: Searching spans every connected environment
    Given the environment "work" has the thread "Dark mode for admin"
    When the user searches threads for "dark"
    Then "Add dark mode" and "Dark mode for admin" are both found

  @desktop @mobile @backlog-mobile
  Scenario: An offline environment is left out of the search
    Given the environment "work" is offline
    When the user searches threads for "dark"
    Then results from the reachable environments are shown
    And the user can tell "work" was not searched

  @desktop
  Scenario: Moving through search results with the keyboard
    Given the thread search shows three results
    When the user moves down past the last result
    Then the first result is highlighted again
    When the user chooses the highlighted result
    Then that thread opens and the search is cleared

  @desktop
  Scenario: Leaving a search
    Given the user is searching threads
    When the user dismisses the search
    Then the full thread list is shown again

  # Find in thread: searching inside the open thread, not across threads.
  @backlog @desktop
  Scenario: Finding text in the open thread starts at what the user is reading
    Given the open thread mentions "deploy" 30 times
    And the 28th mention is the first one in or below the visible part of the thread
    When the user presses mod+f and types "deploy"
    Then the find bar shows "28/30" and the 28th mention is highlighted
    When the user goes to the next match twice
    Then the find bar shows "1/30"

  @backlog @desktop
  Scenario: Find in thread is offered from the command palette
    When the user chooses "Find in thread" in the command palette
    Then the find bar opens on the open thread

  @backlog @desktop
  Scenario: Going back from the first match wraps to the last
    Given the find bar shows "1/5" for "deploy"
    When the user goes to the previous match
    Then the find bar shows "5/5"

  @backlog @desktop
  Scenario: A match in earlier, unloaded history is revealed in the thread
    Given the open thread's earliest turns are not loaded and one of them is collapsed
    When the user goes to a match in that collapsed turn
    Then earlier history loads until the turn is there
    And the turn unfolds and the thread scrolls to the match, in the normal timeline

  @backlog @desktop
  Scenario: New matches before the selected one do not move the selection
    Given the find bar shows "3/5" for "deploy"
    When the agent writes "deploy" in a message before the selected match
    Then the selected match stays the one the user was on
    And the count grows to 6

  @backlog @desktop
  Scenario: Several quick presses of next all count
    Given the selected match is still loading
    When the user goes to the next match three times
    Then the find bar lands three matches further on

  @backlog @desktop
  Scenario: Closing the find bar keeps the reading position
    Given the user went to a match in a turn that was collapsed
    When the user closes the find bar
    Then the thread stays where it is and the turn stays open

  @backlog @desktop
  Scenario: Find starts afresh after switching environments
    Given the user is finding "deploy" in thread "t1" on "home"
    When the user switches to thread "t1" on "work"
    Then the find bar no longer shows the search from "home"

  @backlog @desktop
  Scenario: Find in thread explains when the MC is too old for it
    Given the environment's MC cannot search within a thread
    When the user presses mod+f in a thread
    Then the user is told the MC needs updating
    And the command palette does not offer "Find in thread"

  @backlog @desktop
  Scenario: Matches follow the text as it is displayed
    Given a message has "**deploy** now" in Markdown
    When the user finds "deploy now"
    Then the message counts as one match

  @backlog @desktop
  Scenario: The colours of find matches come from the theme
    Given a theme sets the find match and selected find match colours
    When the user finds text in a thread
    Then the matches use the theme's colours
