# Sources:
#   https://github.com/pingdotgg/t3code/pull/10439 (find in thread)
#   packages/contracts/src/rpc.ts (orchestration.searchThreads)
#   packages/contracts/src/orchestration.ts (OrchestrationSearchThreadsInput, OrchestrationThreadSearchMatch)
#   apps/server-ex/lib/hal_c2/search.ex
#   apps/server/src/orchestration-v2/ (thread search query)
#   docs/user/ (searching threads)
Feature: Searching threads by what was said
  Search finds active threads whose finished user or assistant messages contain
  the query, one match per thread, with a snippet around the match.

  Background:
    Given an MC with a project "demo"

  @mc
  Scenario: A thread matches when a finished message contains the query
    Given thread "t1" has an assistant message "The parser now handles unicode"
    When a client searches for "parser"
    Then "t1" is found with an assistant match

  @mc
  Scenario: Matching ignores letter case
    Given thread "t1" has a user message "Fix the Parser"
    When a client searches for "parser"
    Then "t1" is found

  @mc
  Scenario: A user message is preferred over an assistant message in the same thread
    Given thread "t1" has a user message and an assistant message both containing "cache"
    When a client searches for "cache"
    Then "t1" is found once, with its user message as the match

  @mc
  Scenario Outline: Some threads and messages are never found
    Given <thing> contains "secret-word"
    When a client searches for "secret-word"
    Then nothing is found

    Examples:
      | thing                                  |
      | an archived thread's message           |
      | a deleted thread's message             |
      | an assistant message still streaming   |
      | a tool call's output                   |

  @mc
  Scenario: Wildcard characters in the query are matched literally
    Given thread "t1" has a message "100% done"
    And thread "t2" has a message "1000 done"
    When a client searches for "100%"
    Then only "t1" is found

  @mc
  Scenario: Results are ordered by the threads' latest activity
    Given threads "old" and "new" both mention "deploy" and "new" was active more recently
    When a client searches for "deploy"
    Then "new" comes before "old"

  @mc
  Scenario: Results are limited
    Given 60 threads mention "deploy"
    When a client searches for "deploy"
    Then 50 matches are returned
    And asking with limit 5 returns 5

  @mc
  Scenario: The snippet is centred near the match and marked where it was cut
    Given thread "t1" has a 2,000 character message with "needle" in the middle
    When a client searches for "needle"
    Then the snippet is at most 240 characters with whitespace collapsed
    And it starts shortly before "needle" and is marked with ellipses on both cut ends

  @mc
  Scenario: The snippet shows words, never the ids in HAL-C2's markup
    Given thread "t1" has a user message:
      """
      <delegated_task_result taskId="task-1f2e" title="Review" childThreadId="b29805a8-5d1c-4c1e-9d3a-0f6c2b7e9a11">
      The review found no Vec<String> leaks
      </delegated_task_result>
      """
    When a client searches for "review found"
    Then the snippet reads "The review found no Vec<String> leaks"

  @mc
  Scenario: Markup someone wrote stays in the snippet
    Given thread "t1" has a user message:
      """
      Please use <a href="/docs">the docs</a> for this
      """
    When a client searches for "the docs"
    Then the snippet reads:
      """
      Please use <a href="/docs">the docs</a> for this
      """

  @mc
  Scenario: Messages written before the index existed are found after startup
    Given threads written by an MC that had no search index
    When the MC starts
    Then their finished messages can be searched

  @mc
  Scenario Outline: Queries outside the allowed length are rejected
    When a client searches for <query>
    Then the request is rejected as invalid

    Examples:
      | query                         |
      | "a"                           |
      | "   "                         |
      | a query of 201 characters     |

  @mc
  Scenario: Surrounding whitespace in the query is ignored
    Given thread "t1" has a message "parser"
    When a client searches for "  parser  "
    Then "t1" is found

  @mc
  Scenario: A limit outside 1 to 50 is rejected
    When a client searches for "deploy" with limit 500
    Then the request is rejected as invalid

  # Find in thread: one thread, every occurrence, for a client to move through.
  @backlog @mc
  Scenario: Finding in a thread counts every occurrence the user can see
    Given thread "t1" was forked from "t0", whose messages mention "deploy" twice
    And "t1" mentions "deploy" three times since the fork
    And "t1" was rolled back past one of them
    And a cancelled queued message in "t1" mentions "deploy"
    When a client finds "deploy" in "t1"
    Then the MC answers with 4 matches
    And the answer names the selected match without any message text

  @backlog @mc
  Scenario: An answer a question card folded in is found in its card
    Given the user answered a question in "t1" with "deploy on Friday"
    When a client finds "Friday" in "t1"
    Then the match is the question card

  @backlog @mc
  Scenario: A finished turn changes the count of a find in that thread
    Given a client found "deploy" 3 times in "t1"
    When a turn in "t1" adds a message mentioning "deploy"
    And the client finds "deploy" in "t1" again
    Then the MC answers with 4 matches
