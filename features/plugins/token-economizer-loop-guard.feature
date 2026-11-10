# Sources:
#   plugins/token-economizer/mc/token_economizer.ex (the loop guard: hears turns, redirects, offers a stop, the loopGuard topic)
#   plugins/token-economizer/mc/loop_guard_turn.ex, loop_guard_rules.ex, loop_guard_state.ex (when a turn is stuck)
#   plugins/token-economizer/mc/loop_guard_envelope.ex (what a project's turns that ended green teach)
#   plugins/token-economizer/mc/loop_guard_judge.ex (the paid judge, on the user's text model)
#   plugins/token-economizer/plugin.json (loopGuard, loopGuardLevel, loopGuardNudges, loopGuardThresholds)
#   microsoft/TokenEconomizer@cb42207e3e09 tokeneconomizer/plugin/controller.py, tokeneconomizer/loopguard/ (what this ports)
#   hal-c2/hal-c2#1399 (the TokenEconomizer port)

@plugin-token-economizer
Feature: TokenEconomizer's loop guard
  TokenEconomizer watches each turn's tool calls. When an agent keeps making the same
  edit and getting the same failure, it redirects the agent once and says so in the
  thread; if the turn still looks stuck after that, it offers the person a way to stop
  it, and never stops a turn itself. What counts as stuck is learned per project and
  agent from the turns that ended green, so on a project it has not learned yet it only
  watches. In watch mode it decides as it would and delivers nothing.

  Background:
    Given an MC running the TokenEconomizer plugin

  @mc
  Scenario: A stuck turn is redirected once and the thread says so
    Given a project whose Claude turns that ended green ran 4 tool calls each
    When Claude keeps editing a file and getting the same test failure
    Then Claude is sent a redirect in that turn
    And the turn shows the notice "Loop guard" from TokenEconomizer without a way to stop it
    And TokenEconomizer counts one redirect

  @mc
  Scenario: With no redirects allowed, a stuck turn is offered a stop and goes on until the person stops it
    Given a project whose Claude turns that ended green ran 4 tool calls each
    And TokenEconomizer may send no redirects
    When Claude keeps editing a file and getting the same test failure
    Then the turn shows the notice "Loop guard" from TokenEconomizer, offering to stop the turn
    And the turn is still running and Claude was sent no redirect
    When the person stops the turn
    Then the turn ends interrupted

  @mc
  Scenario: On a project it has not learned, TokenEconomizer only watches
    Given a project TokenEconomizer has not learned
    When Claude keeps editing a file and getting the same test failure until the turn ends
    Then Claude was sent no redirect and the turn shows no notice from TokenEconomizer

  @mc
  Scenario: In watch mode a stuck turn is counted and nothing is delivered
    Given a project whose Claude turns that ended green ran 4 tool calls each
    And TokenEconomizer only watches
    When Claude keeps editing a file and getting the same test failure until the turn ends
    Then TokenEconomizer counts one redirect it did not deliver
    And Claude was sent no redirect and the turn shows no notice from TokenEconomizer

  @mc
  Scenario: Only a turn that ended green teaches the project's envelope
    Given a project TokenEconomizer has not learned
    When a Claude turn that runs one command ends green
    Then the project's envelope has learned one turn of 1 tool call
    When Claude keeps editing a file and getting the same test failure until the turn ends
    Then the project's envelope has still learned one turn

  @mc
  Scenario: A threshold that is not one is refused, naming the ones there are
    When the person pins the threshold "loop_count" to 3
    Then the settings are refused with "loop_count is not a threshold"
