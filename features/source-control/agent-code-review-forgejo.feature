# Sources:
#   plugins/code-review/mc/code_review.ex (the host a review reads and posts on)
#   plugins/code-review/mc/checkout.ex (the plugin's clone, fetched with the account's token)
#   plugins/code-review/plugin.json (the host setting)
#   apps/server-ex/lib/hal_c2/pull_requests/forgejo.ex (detail, activity, trust, submit_review, fetch_access)
#   apps/server-ex/lib/hal_c2/pull_requests.ex (plugin_handle: what only a plugin reads of a Forgejo pull request)
#   apps/server-ex/lib/hal_c2/plugins/host.ex (pull_request_fetch)
#   docs/user/code-review.md
#   https://forgejo.org/docs/latest/user/api-usage/
@plugin-code-review
Feature: Agent code review on Forgejo
  The code-review plugin reviews pull requests on a Forgejo (or Gitea) server as it does
  on GitHub. It reads them and posts its reviews through the server's REST API, as the
  account fj is signed in with, and its clone fetches them over HTTPS with that
  account's token, which git is handed for the fetch and never keeps.

  Background:
    Given an MC running the plugin "code-review" with Forgejo as its host
    And the project "shop" whose remote is "acme/shop" on Forgejo

  @mc
  Scenario: A Forgejo pull request is reviewed in a checkout of its head
    When the user asks for a review of Forgejo pull request #7
    Then its thread works in a checkout of the head of Forgejo pull request #7
    And the plugin fetched it from Forgejo with fj's token
    And the plugin's clone does not keep the token

  @mc
  Scenario Outline: fj's token is not sent where the MC's git configuration would expose it
    Given the MC's git configuration <configuration>
    When the user asks for a review of Forgejo pull request #7
    Then the review of Forgejo pull request #7 fails, saying "<said>"
    And the plugin sent no fetch with fj's token

    Examples:
      | configuration                                     | said                                 |
      | sends the fetch to another server                 | not from the server its token is for |
      | turns off the check of the server's certificate   | configured not to check              |

  @mc
  Scenario: A review is posted to Forgejo with its comments on their lines
    Given "code-review" posts its reviews automatically
    When the user asks for a review of Forgejo pull request #7
    And its agent requests changes with a comment on line 2 of "src/cart.ts"
    Then Forgejo has a review of #7 requesting changes, with that comment on line 2 of the new file
    And the review of Forgejo pull request #7 is marked as published

  @mc
  Scenario: A read that names the account it expects is checked against fj's login
    When the plugin asks which account it acts as on Forgejo
    Then Forgejo answers that it acts as "octocat"
    When the plugin reads Forgejo pull request #7 expecting the account "octocat"
    Then Forgejo serves the read
    When the plugin reads Forgejo pull request #7 expecting the account "someone-else"
    Then Forgejo refuses the read with "The Forgejo account could not be verified before starting the operation."

  @mc
  Scenario: A Forgejo pull request from someone the repository does not trust waits for the user
    Given Forgejo pull request #7 is opened by "stranger", who is no collaborator of "acme/shop"
    When the user asks for a review of Forgejo pull request #7
    Then the user is told to approve Forgejo pull request #7 on the Reviews page first
