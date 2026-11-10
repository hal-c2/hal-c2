# Sources:
#   plugins/token-economizer/mc/token_economizer.ex (micro-skills: hears turns, stages facts, microSkills call and topics)
#   plugins/token-economizer/mc/micro_skills_envfacts.ex, micro_skills_observe.ex (what a turn teaches)
#   plugins/token-economizer/mc/micro_skills_lifecycle.ex (a fact's formation, retirement and firing gate)
#   plugins/token-economizer/mc/micro_skills_distiller.ex (the facts a model proposes, held to the turns they cite)
#   plugins/token-economizer/plugin.json (microSkills, microSkillsMaxFacts, microSkillsMaxTokens, microSkillsProposeEvery, runs:shape, textGeneration)
#   apps/server-ex/test/steps/plugins/token_economizer_micro_skills_steps.exs, apps/server-ex/test/support/fake_claude.py ("repair the test command", "run the tests the working way"), apps/server-ex/test/support/fake_text_cli.py (the model)
#   microsoft/TokenEconomizer@cb42207e3e09 tokeneconomizer/microskills/{envfacts,observe,lifecycle,stage,distiller}.py (what this ports)
#   plugins/token-economizer/ui/TokenEconomizerPage.qml, apps/desktop-qt/tests/native/features/TokenEconomizerSteps.cpp (the plugin's page)
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

  With micro-skills on, every few turns the person's text generation model
  is also shown a digest of the project's recent turns (commands, failures
  and file names, never file contents) and may propose facts of its own. Each
  comes with a check the plugin runs itself, and is kept only if that check
  holds on two of the turns it cites; from then on it earns its place like
  any other fact.

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
  Scenario: A turn whose end the feed lost is learned from the thread's history
    Given micro-skills are off
    And Claude has repaired the test command in 1 turns in the thread "Learning"
    Then TokenEconomizer has learned nothing on the project
    When micro-skills are on
    And the plugin heard the thread "Learning"'s last turn start and look around, then nothing more
    And the plugin sweeps twice for turns whose run has ended
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

  @mc
  Scenario: A fact the model proposes is kept when its check holds on the turns it cites
    Given micro-skills ask the model for facts every 4 turns
    And Claude has repaired the test command in 2 turns in the thread "Learning"
    And the model will propose that the tests run as a module, citing the thread "Learning"'s last 2 turns
    When Claude repairs the test command in 1 turns in the thread "Learning"
    And the model has answered 1 times
    Then TokenEconomizer lists the proposed fact "tests-as-module" with its check

  @mc
  Scenario: A proposed fact whose check holds on fewer than two cited turns is not kept
    Given micro-skills ask the model for facts every 4 turns
    And Claude has repaired the test command in 2 turns in the thread "Learning"
    And the model will propose that the tests run as a module, citing the thread "Learning"'s last 1 turns
    When Claude repairs the test command in 1 turns in the thread "Learning"
    And the model has answered 1 times
    Then TokenEconomizer has kept no fact from the model

  @mc
  Scenario: A dropped proposed fact is not kept again until restored
    Given micro-skills ask the model for facts every 4 turns
    And Claude has repaired the test command in 2 turns in the thread "Learning"
    And the model will propose that the tests run as a module, citing the thread "Learning"'s last 2 turns
    And Claude has repaired the test command in 1 turns in the thread "Learning"
    And the model has answered 1 times
    When the person drops the fact "tests-as-module"
    And Claude repairs the test command in 4 turns in the thread "Learning"
    And the model has answered 2 times
    Then TokenEconomizer lists "tests-as-module" as dropped, with no fact kept from the model
    When the person restores the fact "tests-as-module"
    And Claude repairs the test command in 3 turns in the thread "Learning"
    And the model will propose that the tests run as a module, citing the thread "Learning"'s last 2 turns
    And Claude repairs the test command in 1 turns in the thread "Learning"
    And the model has answered 3 times
    Then TokenEconomizer lists the proposed fact "tests-as-module" with its check

  @mc
  Scenario: A reply that is not the facts asked for keeps nothing
    Given micro-skills ask the model for facts every 4 turns
    When Claude repairs the test command in 4 turns in the thread "Learning"
    And the model has answered 1 times
    Then TokenEconomizer has kept no fact from the model
    And TokenEconomizer has learned the fact about "pytest", active and staged

  @mc
  Scenario: A model that fails is asked again only when the next proposal is due
    Given micro-skills ask the model for facts every 4 turns
    And asking the model fails
    When Claude repairs the test command in 6 turns in the thread "Learning"
    And the model has answered 1 times
    Then the model was asked for facts 1 times
    When Claude repairs the test command in 1 turns in the thread "Learning"
    And the model has answered 2 times
    Then the model was asked for facts 2 times
    And TokenEconomizer has kept no fact from the model

  @mc
  Scenario: With micro-skills learning only environment facts, no model is asked
    When Claude repairs the test command in 4 turns in the thread "Learning"
    Then the model was asked for facts 0 times

  @mc
  Scenario: A project whose saved micro-skills cannot be read is held, not started afresh
    Given micro-skills ask the model for facts every 4 turns
    And the project's saved micro-skills are not valid JSON
    When Claude repairs the test command in 4 turns in the thread "Learning"
    Then TokenEconomizer holds the project's micro-skills, saying its file is not valid JSON and naming it
    And the project's saved micro-skills are as they were
    And the model was asked for facts 0 times
    And the person cannot drop a fact on the project, being told it is held

  @mc
  Scenario: Turns between proposals that are not a whole number are refused
    When the person sets the turns between the model's proposals to 0
    Then the settings are refused, naming the turns between proposals

  @desktop @mobile @tui @backlog-mobile @backlog-tui
  Scenario: The person sees a project's learned facts and drops one from the plugin's page
    Given TokenEconomizer has learned a fact on a project
    When the person opens TokenEconomizer's page
    Then the fact is listed with how many turns confirmed it and how often it fires
    When the person drops the fact there
    Then a new conversation in that project is not told the fact
    And the page lists it as dropped, with a way to restore it

  @desktop @mobile @tui @backlog-mobile @backlog-tui
  Scenario: A project that learns its first fact while the plugin's page is open shows up there
    Given the person opens TokenEconomizer's page
    And the page says nothing is learned yet
    When TokenEconomizer has learned a fact on a project
    Then the fact is listed with how many turns confirmed it and how often it fires

  @desktop @mobile @tui @backlog-mobile @backlog-tui
  Scenario: The plugin's page shows a held project with why and where, and reads it again once repaired
    Given TokenEconomizer holds a project's micro-skills, its saved file not being valid JSON
    When the person opens TokenEconomizer's page
    Then the page shows the project as held, saying why and naming its file
    And the page offers no way to drop or forget there
    When the person repairs the file and reads it again from the page
    Then the fact is listed with how many turns confirmed it and how often it fires
