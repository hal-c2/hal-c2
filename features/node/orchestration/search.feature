# Sources:
#   packages/contracts/src/rpc.ts (orchestration.searchThreads)
#   packages/contracts/src/orchestration.ts (OrchestrationSearchThreadsInput, OrchestrationThreadSearchMatch)
#   apps/server-ex/lib/hal_c2/search.ex
#   apps/server/src/orchestration-v2/ (thread search query)
#   docs/user/ (searching threads)
Feature: Searching threads by what was said
  Search finds active threads whose finished user or assistant messages contain
  the query, one match per thread, with a snippet around the match.

  Background:
    Given a node with a project "demo"

  @node
  Scenario: A thread matches when a finished message contains the query
    Given thread "t1" has an assistant message "The parser now handles unicode"
    When a client searches for "parser"
    Then "t1" is found with an assistant match

  @node
  Scenario: Matching ignores letter case
    Given thread "t1" has a user message "Fix the Parser"
    When a client searches for "parser"
    Then "t1" is found

  @node
  Scenario: A user message is preferred over an assistant message in the same thread
    Given thread "t1" has a user message and an assistant message both containing "cache"
    When a client searches for "cache"
    Then "t1" is found once, with its user message as the match

  @node
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

  @node
  Scenario: Wildcard characters in the query are matched literally
    Given thread "t1" has a message "100% done"
    And thread "t2" has a message "1000 done"
    When a client searches for "100%"
    Then only "t1" is found

  @node
  Scenario: Results are ordered by the threads' latest activity
    Given threads "old" and "new" both mention "deploy" and "new" was active more recently
    When a client searches for "deploy"
    Then "new" comes before "old"

  @node
  Scenario: Results are limited
    Given 60 threads mention "deploy"
    When a client searches for "deploy"
    Then 50 matches are returned
    And asking with limit 5 returns 5

  @node
  Scenario: The snippet is centred near the match and marked where it was cut
    Given thread "t1" has a 2,000 character message with "needle" in the middle
    When a client searches for "needle"
    Then the snippet is at most 240 characters with whitespace collapsed
    And it starts shortly before "needle" and is marked with ellipses on both cut ends

  @node
  Scenario: Messages written before the index existed are found after startup
    Given threads written by a node that had no search index
    When the node starts
    Then their finished messages can be searched

  @node
  Scenario Outline: Queries outside the allowed length are rejected
    When a client searches for <query>
    Then the request is rejected as invalid

    Examples:
      | query                         |
      | "a"                           |
      | "   "                         |
      | a query of 201 characters     |

  @node
  Scenario: Surrounding whitespace in the query is ignored
    Given thread "t1" has a message "parser"
    When a client searches for "  parser  "
    Then "t1" is found

  @node
  Scenario: A limit outside 1 to 50 is rejected
    When a client searches for "deploy" with limit 500
    Then the request is rejected as invalid
