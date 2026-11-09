# Sources:
#   plugins/token-economizer/mc/token_economizer.ex (micro-skills: hears turns, stages facts, microSkills call and topic)
#   plugins/token-economizer/mc/micro_skills_envfacts.ex, micro_skills_observe.ex (what a turn teaches)
#   plugins/token-economizer/mc/micro_skills_lifecycle.ex (a fact's formation, retirement and firing gate)
#   plugins/token-economizer/plugin.json (microSkills, microSkillsMaxFacts, microSkillsMaxTokens, runs:shape)
#   apps/server-ex/test/steps/plugins/token_economizer_micro_skills_steps.exs, apps/server-ex/test/support/fake_claude.py ("repair the test command", "run the tests the working way")
#   microsoft/TokenEconomizer@cb42207e3e09 tokeneconomizer/microskills/{envfacts,observe,lifecycle,stage}.py (what this ports)
#   hal-c2/hal-c2#1399 (the TokenEconomizer port)

@plugin-token-economizer
Feature: TokenEconomizer's micro-skills
  TokenEconomizer learns short facts about a project's environment from the
  turns that run in it: an agent that finds the same way of running the tests
  failing, and the same spelled-out form working, turn after turn, has taught
  it a fact. Once a fact has earned its place it goes ahead of the first
  message of a new conversation in that project, never into one under way.
  The person can see each project's facts with the evidence behind them, drop
  one so it is never staged or learned again, and restore it.

  Background:
    Given an MC running the TokenEconomizer plugin with micro-skills

  @mc
  Scenario: A fact learned from four turns is staged for the next conversation
    When Claude repairs the test command in 4 turns in the thread "Learning"
    Then TokenEconomizer has learned the fact about "pytest", active and staged
    When Claude starts the thread "Next" with "hello"
    Then Claude gets the fact about "pytest" ahead of "hello"
    And nothing before that thread was told the fact

  @mc
  Scenario: A conversation staged before the MC restarts still counts the facts it was given
    Given Claude has repaired the test command in 4 turns in the thread "Learning"
    And Claude starts the thread "Next" with "hello"
    When the MC restarts with TokenEconomizer running
    And Claude runs the tests the working way in the thread "Next"
    Then the fact about "pytest" counts that turn as having been given it

  @mc
  Scenario: A candidate that has not earned its place is not staged
    When Claude repairs the test command in 2 turns in the thread "Learning"
    Then TokenEconomizer still counts the fact about "pytest" as forming
    When Claude starts the thread "Next" with "hello"
    Then Claude is not told anything about "pytest"

  @mc
  Scenario: A dropped fact is not staged again and not learned again until restored
    Given Claude has repaired the test command in 4 turns in the thread "Learning"
    When the person drops the fact about "pytest"
    And Claude repairs the test command in 3 turns in the thread "Again"
    Then TokenEconomizer lists the fact about "pytest" as dropped, with no fact learned
    When Claude starts the thread "Next" with "hello"
    Then Claude is not told anything about "pytest"
    When the person restores the fact about "pytest"
    And Claude repairs the test command in 4 turns in the thread "Relearning"
    And Claude starts the thread "Later" with "hello"
    Then Claude gets the fact about "pytest" ahead of "hello"

  @mc
  Scenario: With micro-skills off, nothing is learned and nothing is staged
    Given micro-skills are off
    When Claude repairs the test command in 4 turns in the thread "Learning"
    Then TokenEconomizer has learned nothing on the project
    When Claude starts the thread "Next" with "hello"
    Then Claude is not told anything about "pytest"

  @mc
  Scenario: A turn the plugin partly missed is learned from the thread's history
    Given micro-skills are off
    And Claude has repaired the test command in 1 turns in the thread "Learning"
    Then TokenEconomizer has learned nothing on the project
    When micro-skills are on
    And the plugin is told it partly missed the thread "Learning"'s last turn
    Then TokenEconomizer still counts the fact about "pytest" as forming

  @mc
  Scenario: A missed turn that cannot be read back teaches nothing
    Given Claude starts the thread "Quiet" with "hello"
    When the plugin is told it partly missed a turn the thread "Quiet" never ran
    Then TokenEconomizer has learned nothing on the project

  @mc
  Scenario: A cap that is not a whole number is refused
    When the person sets the micro-skills' most facts to 1.5
    Then the settings are refused, naming the most facts

  @desktop @mobile @tui @backlog
  Scenario: The person sees a project's learned facts and drops one from the plugin's page
    Given TokenEconomizer has learned a fact on a project
    When the person opens TokenEconomizer's page
    Then the fact is listed with how many turns confirmed it and how often it fires
    When the person drops the fact there
    Then a new conversation in that project is not told the fact
    And the page lists it as dropped, with a way to restore it
