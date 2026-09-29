# Sources:
#   docs/user/thread-sidebar.md (Searching threads)
#   apps/web/src/components/Sidebar.tsx (thread search, result keyboard)
#   apps/web/src/components/Sidebar.logic.ts (title search, content matches)
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

  @desktop @backlog-desktop
  Scenario: Searching from the thread list opens the command palette
    When the user starts a search from the thread list
    Then the command palette opens ready to search threads

  @backlog @desktop @mobile
  Scenario: Title search ignores case and project details
    When the user searches threads for "DARK"
    Then "Add dark mode" is found
    And threads are not found only because their project matches

  @node
  Scenario: Searching what was said in threads
    Given the agent in "Add dark mode" said "the palette now reads prefers-color-scheme"
    When a client searches threads for "prefers-color-scheme"
    Then "Add dark mode" is returned with the matching words in a short excerpt

  @node
  Scenario: A thread is returned once, preferring what the user wrote
    Given the user and the agent both wrote "rate limit" in "Fix OAuth loop"
    When a client searches threads for "rate limit"
    Then "Fix OAuth loop" is returned once
    And its excerpt comes from the user's message

  @node
  Scenario: Archived and deleted threads are not searched
    Given "Add dark mode" is archived
    When a client searches threads for "dark"
    Then "Add dark mode" is not returned

  @node
  Scenario: Messages still being written are not searched
    Given the agent is still writing "flaky test" in "Fix OAuth loop"
    When a client searches threads for "flaky test"
    Then "Fix OAuth loop" is not returned until the message is finished

  @node
  Scenario: Threads from before search existed are searchable
    Given the environment has threads written before it kept a search index
    When the environment starts
    Then the old threads are indexed once and can be searched

  @node
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

  @backlog @desktop @mobile
  Scenario: Searching spans every connected environment
    Given the environment "work" has the thread "Dark mode for admin"
    When the user searches threads for "dark"
    Then "Add dark mode" and "Dark mode for admin" are both found

  @backlog @desktop @mobile
  Scenario: An offline environment is left out of the search
    Given the environment "work" is offline
    When the user searches threads for "dark"
    Then results from the reachable environments are shown
    And the user can tell "work" was not searched

  @backlog @desktop
  Scenario: Moving through search results with the keyboard
    Given the thread search shows three results
    When the user moves down past the last result
    Then the first result is highlighted again
    When the user chooses the highlighted result
    Then that thread opens and the search is cleared

  @backlog @desktop
  Scenario: Leaving a search
    Given the user is searching threads
    When the user dismisses the search
    Then the full thread list is shown again
