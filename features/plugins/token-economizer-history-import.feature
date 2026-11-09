# Sources:
#   plugins/token-economizer/mc/micro_skills_history.ex (the first fold from history: plan, pages, held-back live turns, envelope seeding)
#   plugins/token-economizer/mc/token_economizer.ex (starts, reads and folds it; microSkills.forget)
#   plugins/token-economizer/plugin.json (historyImport, historyDays, historyMaxThreads)
#   apps/server-ex/lib/hal_c2/plugins/host.ex (project_threads/2, history/3 after:)
#   apps/server-ex/test/steps/plugins/token_economizer_micro_skills_steps.exs
#   microsoft/TokenEconomizer@cb42207e3e09 tokeneconomizer/plugin/history.py (what this ports)
#   plugins/token-economizer/ui/TokenEconomizerPage.qml, apps/desktop-qt/tests/native/features/TokenEconomizerSteps.cpp (the plugin's page)
#   hal-c2/hal-c2#1399 (the TokenEconomizer port)

@plugin-token-economizer
Feature: TokenEconomizer learns from a project's earlier threads
  With the history import on, the first conversation in a project whose
  micro-skills have learned nothing yet first learns from the project's
  earlier threads, oldest first, as if their turns had just ended. No model is
  asked and nothing is said in any thread. The turns that end in the project
  meanwhile are learned from after the import, in order, and no turn is learned
  from twice. A project that already learned from its turns is never imported
  into. Forgetting what a project learned takes the import back out, and runs
  it again while it is on.

  Background:
    Given an MC running the TokenEconomizer plugin with micro-skills

  @mc
  Scenario: The first conversation with the import on learns from the project's earlier threads
    Given micro-skills are off
    And Claude has repaired the test command in 4 turns in the thread "Earlier"
    When micro-skills are on
    And the history import is on
    And Claude starts the thread "Next" with "hello"
    Then TokenEconomizer's history import is done, the project having learned from 5 turns
    And TokenEconomizer has learned the fact about "pytest", active and staged
    And the import left the loop guard's envelope as it was, having learned already
    When Claude starts the thread "Later" with "hello"
    Then Claude gets the fact about "pytest" ahead of "hello"

  @mc
  Scenario: The import's green turns seed a loop guard envelope that has learned nothing yet
    Given the loop guard is off
    And micro-skills are off
    And Claude ran 4 turns repairing the test command in the thread "Earlier", with nothing listening
    When the loop guard only watches
    And micro-skills are on
    And the history import is on
    And Claude starts the thread "Next" with "hello"
    Then TokenEconomizer's history import is done, the project having learned from 5 turns
    And the import seeded the loop guard's envelope with 4 turns

  @mc
  Scenario: A project that already learned from its turns is not imported into
    Given Claude has repaired the test command in 1 turns in the thread "Learning"
    When the history import is on
    And Claude starts the thread "Next" with "hello"
    Then TokenEconomizer skipped the history import, the project having learned already

  @mc
  Scenario: Forgetting what a project learned runs the import again while it is on
    Given Claude has repaired the test command in 4 turns in the thread "Learning"
    And the history import is on
    When the person forgets what TokenEconomizer learned on the project
    Then TokenEconomizer's history import is done, the project having learned from 4 turns
    And TokenEconomizer has learned the fact about "pytest", active and staged

  @mc
  Scenario: Forgetting with the import off forgets for good
    Given Claude has repaired the test command in 4 turns in the thread "Learning"
    When the person forgets what TokenEconomizer learned on the project
    Then TokenEconomizer has learned nothing on the project and imported nothing
    When Claude starts the thread "Next" with "hello"
    Then Claude is not told anything about "pytest"

  @mc
  Scenario: An import left under way by an MC that stopped, with the import turned off since, stops and still learns from the turns that end
    Given TokenEconomizer's history import on the project was under way when the MC stopped
    And the history import was turned off before the MC started again
    When Claude starts the thread "Next" with "hello"
    Then TokenEconomizer's history import stopped, the import having been turned off, the project having learned from 1 turns

  @mc
  Scenario: The import's settings take whole numbers
    When the person sets "historyDays" to 0
    Then the settings are refused, naming "historyDays"

  @desktop @mobile @tui @backlog-mobile @backlog-tui
  Scenario: The person sees a project's import and forgets what it learned from the plugin's page
    Given TokenEconomizer's history import on a project is under way
    When the person opens TokenEconomizer's page
    Then the project shows how many threads the import read of how many, and what it left out
    When the person forgets what the project learned there
    Then the page shows the project having learned nothing, its import running again
