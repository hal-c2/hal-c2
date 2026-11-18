# Sources:
#   apps/server-ex/lib/hal_c2/pull_requests/forgejo.ex (summaries over Forgejo's REST API)
#   apps/server-ex/lib/hal_c2/pull_requests.ex (summaries/1 routes Forgejo links to it)
#   apps/server-ex/lib/hal_c2/pull_requests/wakes.ex (describe/2: tea commands for a Forgejo link)
#   https://forgejo.org/docs/latest/user/api-usage/
Feature: A thread hears about a pull request it owns on Forgejo

  A pull request linked on a Forgejo (or Gitea) host is read over the server's REST API,
  signed in with fj's or tea's token: its state, its reviews and their inline comments,
  its comments, and the commit statuses of its head, which Forgejo Actions writes. Its
  thread is woken as a GitHub pull request's would be, and told how to read the news
  with `tea`. Forgejo has no native stacks, so the link has none.

  Background:
    Given an MC with a project "shop" on Forgejo "acme/shop"
    And thread "fix" in "shop" links Forgejo pull request "acme/shop#7", which the MC has read once

  @mc
  Scenario: Failing checks on a Forgejo pull request wake its thread
    When its checks start failing and the MC reads it again
    Then the agent of "fix" is woken about "acme/shop#7: checks failing"
    And the message says "Checks are failing."
    And the message says "`https://codeberg.org/api/v1/repos/acme/shop/commits/<head sha>/status`"
    And the message does not say "tea "
    And the message does not say "gh "

  @mc
  Scenario: A collaborator's review wakes the thread; a stranger's comment does not
    When a stranger comments and the MC reads it again
    Then the agent of "fix" is not woken
    When collaborator "maint" requests changes and the MC reads it again
    Then the agent of "fix" is woken about "acme/shop#7: new review"
    And the message says "New review from maint (changes requested)."

  @mc
  Scenario: A merged Forgejo pull request settles its thread instead of waking it
    When it is merged and the MC reads it again
    Then thread "fix" settles
    And the agent of "fix" is not woken

  @mc
  Scenario: A Forgejo pull request has no stack
    Then thread "fix" shows "acme/shop#7" as open with no stack
