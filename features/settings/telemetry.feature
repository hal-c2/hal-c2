# Sources:
#   docs/user/telemetry.md
#   docs/internals/product-analytics.md
#   apps/server/src/telemetry (PostHog delivery, not present in apps/server-ex)
#   apps/server/src/telemetry/AnalyticsService.ts (project key gate, buffer, retry)
#   apps/server/src/telemetry/Identify.ts (account then installation identity, hashed)

# Blocked: should the fork send product telemetry at all, and to which analytics project?
# The backend sends none today.
@blocked
Feature: Product telemetry
  The server sends anonymous product events so maintainers can see which
  providers and models are used. Content never leaves the machine, and the
  user can turn collection off.

  @backlog @mc
  Scenario: A finished turn sends one anonymous event
    Given telemetry is on
    When a turn finishes
    Then an event records the provider, model, effort, permission mode, result, duration and token totals
    And the event is tied to a hashed account or installation id

  @backlog @mc
  Scenario: Events never carry content
    Given telemetry is on
    When a turn with prompts, file edits and child agents finishes
    Then no event contains prompts, responses, file contents, conversation ids or child agent output

  @backlog @mc
  Scenario: The user turns telemetry off
    Given the MC is started with telemetry disabled
    When a turn finishes
    Then no event is sent

  @backlog @mc
  Scenario: Client events are only accepted from signed in connections
    Given an unauthenticated connection
    When it reports client use
    Then no event is sent for it

  @backlog @mc
  Scenario: Bad client details do not block a connection
    Given a client that sends malformed device details
    When it connects
    Then the connection is accepted
    And the unknown details are left out of events

  @backlog @mc
  Scenario: Telemetry sends nothing until the server is given an analytics project
    Given the MC has telemetry switched on but no analytics project configured
    When a turn finishes
    Then no event is sent

  @backlog @mc
  Scenario: Events that cannot be delivered are kept and sent later
    Given the analytics service cannot be reached
    When turns finish
    Then their events are kept and sent once it is reachable again
    But when more than 1,000 events are waiting the oldest are dropped

  @backlog @mc
  Scenario: An event is tied to the Codex account, then the Claude account, then an installation id
    Given the user is signed in to Codex on this machine
    When a turn finishes
    Then the event is tied to a hash of the Codex account id
    But without a Codex sign-in it is tied to a hash of the Claude user id, and without that to a random installation id
