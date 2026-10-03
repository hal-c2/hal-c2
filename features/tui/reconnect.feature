# Sources:
#   apps/tui/src/connection.ts (loopback supervisor, ticket re-mint, warm thread cache, HTTP history)
#   apps/tui/src/index.tsx (mintSocketUrl IPC timeout and parent disconnect)
#   apps/tui/src/staleRequest.ts
#   apps/tui/src/components/ChatView.tsx (stale versus transient request failures)
#   apps/tui/src/features.backlog.test.ts (environment-connections: disconnect and restart)
#   Shared domain: connections/ owns reconnect semantics for every client.

Feature: Reconnecting and stale requests in the terminal client
  The terminal client survives server restarts and network blips without losing the
  thread the user is on, and it tells stale work apart from work worth retrying.

  Background:
    Given the terminal client is connected and showing a thread

  @tui
  Scenario: A dropped connection reconnects with a fresh socket ticket
    When the connection to the server drops
    Then the client asks its launcher for a new socket ticket
    And it reconnects without the user doing anything

  @tui
  Scenario: The thread the user was on comes back after a reconnect
    Given the connection dropped and came back
    Then the same thread is selected
    And its timeline catches up to the server's state

  @tui
  Scenario: A ticket request that gets no answer fails after ten seconds
    Given the launcher does not answer a socket ticket request
    Then the request fails after 10 seconds
    And the client keeps trying to reconnect

  @tui
  Scenario: Losing the launcher fails every pending ticket request
    Given ticket requests are waiting on the launcher
    When the launcher process goes away
    Then every waiting ticket request fails at once

  @tui
  Scenario: Recently opened threads re-open instantly
    Given the user opened the thread "Fix login" a moment ago
    When the user switches away and back to "Fix login"
    Then "Fix login" shows immediately from the warm cache
    And it refreshes from the server in the background

  # Eviction itself happens inside makeTuiClient's warm thread state; the fake
  # client stands in for the cache, so this checks what the user sees.
  @tui
  Scenario: A thread deleted elsewhere leaves the warm cache
    Given the thread "Old spike" is in the warm cache
    When another client deletes "Old spike"
    Then switching threads never shows "Old spike" again

  @tui
  Scenario: Older history loads over HTTP when the user asks for earlier turns
    Given the thread has more history than the latest page
    When the user asks to load earlier turns
    Then the timeline says it is loading earlier turns
    And the next older page appears above the current one

  @tui
  Scenario: A request the provider reports as stale closes its prompt
    Given an approval prompt is open
    When the user answers it and the provider reports the request as stale or unknown
    Then the approval prompt closes

  @tui
  Scenario: Any other answer failure keeps the prompt open for retry
    Given an approval prompt is open
    When the user answers it and the provider reports a failure that is not about a stale request
    Then the approval prompt stays open so the user can answer again

  @tui
  Scenario: A server restart is reported and the workflow resumes
    When the server restarts
    Then the status line reports the restart
    And the thread, draft and open panels are the same once it is back
