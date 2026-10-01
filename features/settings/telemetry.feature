# Sources:
#   docs/user/telemetry.md
#   docs/internals/product-analytics.md
#   apps/server/src/telemetry (PostHog delivery, not present in apps/server-ex)

# Blocked: should the fork send product telemetry at all, and to which analytics project?
# The backend sends none today.
@blocked
Feature: Product telemetry
  The server sends anonymous product events so maintainers can see which
  providers and models are used. Content never leaves the machine, and the
  user can turn collection off.

  @backlog @node
  Scenario: A finished turn sends one anonymous event
    Given telemetry is on
    When a turn finishes
    Then an event records the provider, model, effort, permission mode, result, duration and token totals
    And the event is tied to a hashed account or installation id

  @backlog @node
  Scenario: Events never carry content
    Given telemetry is on
    When a turn with prompts, file edits and child agents finishes
    Then no event contains prompts, responses, file contents, conversation ids or child agent output

  @backlog @node
  Scenario: The user turns telemetry off
    Given the node is started with telemetry disabled
    When a turn finishes
    Then no event is sent

  @backlog @node
  Scenario: Client events are only accepted from signed in connections
    Given an unauthenticated connection
    When it reports client use
    Then no event is sent for it

  @backlog @node
  Scenario: Bad client details do not block a connection
    Given a client that sends malformed device details
    When it connects
    Then the connection is accepted
    And the unknown details are left out of events
