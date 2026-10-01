# Sources:
#   apps/desktop-qt/src/native/NativeShell.cpp (lent the MC the page's access to environments; dropped)
#   apps/desktop-qt/tests/native/tst_Features.cpp
#   terminal/drawer.feature has the desktop's terminal drawer; this file keeps what was dropped
#   from its placement between the page and the MC.

Feature: The desktop's terminal drawer and the page's environments
  The page's saved environments were once lent to the MC so the drawer could reach them.

  Background:
    Given the desktop's MC "mc-a" serves the environment "env-a"
    And the MC has the project "p1" at "/work/p1"
    And the project "p1" has these scripts:
      | id   | name | command  |
      | test | Test | bun test |
    And the MC has these threads:
      | id | project | title | worktreePath |
      | t1 | p1      | One   |              |
      | t2 | p1      | Two   | /work/p1-wt  |
      | t3 | p9      | Lost  |              |
    And the desktop shell is connected to its MC
    And the user is viewing "env-a:t1"

  Rule: The page lends nothing

    # Lending: the page's saved environments were lent to the MC. Environments outside the
    # cluster are paired as MC links from the shell's Connections settings instead
    # (settings/connections.feature), so the page has nothing to lend.
    @dropped @desktop
    Scenario: A thread on an environment the page has access to has its terminal there
      Given the page has access to "env-c"
      And the page shows "env-c:t7" with its project at "/work/p7"
      When the user toggles the terminal drawer
      Then "env-c" attaches "term-1" of "t7" in "/work/p7"

    @dropped @desktop
    Scenario: The MC keeps the page's access while the page is disconnected there
      Given the page has access to "env-c"
      When the page loses its connection to "env-c"
      Then the MC is linked to "env-c" with the page's access

    @dropped @desktop
    Scenario: The MC gives back the page's access when the page forgets the environment
      Given the page has access to "env-c"
      When the page forgets "env-c"
      Then the MC is not linked to "env-c"
