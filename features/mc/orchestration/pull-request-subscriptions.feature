# Sources:
#   apps/server-ex/lib/hal_c2/mcp/tools/pull_requests.ex (subscribe_pull_request,
#     unsubscribe_pull_request, list_pull_request_subscriptions)
#   apps/server-ex/lib/hal_c2/pull_requests/wakes.ex (subscribed/1, event/1: a link's notify)
#   apps/server-ex/lib/hal_c2/orchestration.ex (thread.pull-request-link.notify)
Feature: An agent chooses which news of a pull request wakes it

  A linked pull request wakes its thread for every kind of news: reviews, comments,
  checks failing (or passing after failing), merge conflicts, leaving the merge queue,
  and being merged or closed. An agent can subscribe its thread to only some of them,
  unsubscribe, and list what it is subscribed to, on GitHub and Forgejo alike.
  Subscribing links the pull request if it is not linked yet; unsubscribing keeps the
  link, so its status still shows and still settles the thread. News of a kind the
  thread is not subscribed to is heard without a wake, and is not told later when it
  subscribes again.

  Background:
    Given an MC with a project "shop" on Forgejo "acme/shop"
    And thread "fix" in "shop" links Forgejo pull request "acme/shop#7", which the MC has read once

  @mc
  Scenario: A thread subscribed to reviews is not woken by failing checks
    When the agent of "fix" subscribes to "acme/shop#7" for "reviews"
    And its checks start failing and the MC reads it again
    Then the agent of "fix" is not woken
    When collaborator "maint" requests changes and the MC reads it again
    Then the agent of "fix" is woken about "acme/shop#7: new review"
    And the message does not say "Checks are failing."

  @mc
  Scenario: Unsubscribing from everything keeps the link quiet, and news it missed is not replayed
    When the agent of "fix" unsubscribes from "acme/shop#7"
    And its checks start failing and the MC reads it again
    Then the agent of "fix" is not woken
    And the agent of "fix" lists no pull request subscriptions
    And thread "fix" shows "acme/shop#7" as open with no stack
    When the agent of "fix" subscribes to "acme/shop#7"
    And the MC reads it again
    Then the agent of "fix" is not woken

  @mc
  Scenario: An agent lists what it is subscribed to
    When the agent of "fix" subscribes to "acme/shop#7" for "merged, reviews"
    And the agent of "fix" unsubscribes from "acme/shop#7" for "merged"
    Then the agent of "fix" lists "acme/shop#7" on "codeberg.org" subscribed to "reviews"

  @mc
  Scenario: A kind of news HAL-C2 does not know is refused
    When the agent of "fix" subscribes to "acme/shop#7" for "pushes"
    Then the subscription is refused with "Unknown events pushes"

  @mc
  Scenario: A merge still settles a thread that is not subscribed to it
    When the agent of "fix" subscribes to "acme/shop#7" for "reviews"
    And it is merged and the MC reads it again
    Then thread "fix" settles

  # The reverse state of an agent's subscription: the user sees and changes it too.
  @backlog @shared
  Scenario: A linked pull request's menu shows and changes which news wakes its thread
    Given the agent of "fix" subscribed to "acme/shop#7" for "reviews"
    When the user opens the menu of "acme/shop#7" in the thread's pull requests
    Then the menu shows "reviews" as waking the thread and the other kinds as not
    When the user turns on "checks" there
    Then failing checks on "acme/shop#7" wake the thread
