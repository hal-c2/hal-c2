# Sources:
#   apps/desktop-ljos/qml/Main.qml (a ShellLoader: the user's shell.qml, else DefaultShell built ahead)
#   apps/desktop-ljos/shell/src/runtime.rs (the user's shell, its error and its fallback, from the ShellLoader)
#   apps/desktop-ljos/shell/src/main.rs (the shell's QML built ahead, the user's files over it while it runs)
#   apps/desktop-ljos/shell/build.rs, src/assets.rs (the fonts, pictures and models beside the QML, built in)
#   apps/desktop-ljos/shell/tests/features (runs these scenarios against a fake MC)
#   Shared domain: navigation/layout.feature has the user's shell layout on every desktop.

Feature: The desktop's shell layout follows the user's file while it runs
  The HAL-C2 home may hold the user's own shell layout (`shell.qml`). The desktop shows it in
  place of the built-in layout, and follows the file while it runs: a saved change is applied to
  the window with what the window holds kept, a change that does not load leaves the layout shown
  and says why, and removing the file gives the window back to the built-in layout, working as it
  does at start. The built-in layout is built with the app, with the fonts, pictures and models
  it loads, so a start without the user's file compiles no QML and finds every file it loads.

  Background:
    Given the desktop's MC "mc-a" serves the environment "env-a"
    And the MC has these threads:
      | id | project | title |
      | t1 | p1      | One   |
    And the MC has the project "p1" titled "proj-1"

  Rule: The user's shell layout follows its file while the app runs

    @desktop
    Scenario: A shell layout change applies without restarting, with what the window holds kept
      Given the app is using the user's own shell layout
      And the user has typed "half a thought" without sending it
      And the user has scrolled down to read further
      When the user saves a change to their shell layout
      Then the window shows the change
      And what the user typed still reads "half a thought"
      And the user is still as far down as they had read
      And the window was not opened again

    @desktop
    Scenario: A shell layout change that does not load leaves the layout shown and says why
      Given the app is using the user's own shell layout
      When the user saves a change to their shell layout that does not load
      Then the window still shows the user's layout as it was
      And the shell layout's error is shown to the user
      When the user saves a change to their shell layout that loads
      Then the window shows the change
      And no shell layout error is shown to the user

    @desktop
    Scenario: Removing the user's shell layout gives the window back to the built-in one, working
      Given the app is using the user's own shell layout
      And the user has saved changes to it 5 times
      When the user removes their shell layout
      Then the built-in layout is used
      And the sidebar lists the threads of the MC
      And the window was not opened again
      And no script error was logged

  Rule: The built-in layout is built with the app

    @desktop
    Scenario: The released app starts its built-in layout without compiling it
      Given the HAL-C2 home has no shell layout of the user's
      When the released app starts
      Then the built-in layout is used
      And no QML was compiled while it started

    @desktop
    Scenario: The released app finds every file its built-in layout loads
      Given the HAL-C2 home has no shell layout of the user's
      When the released app starts
      Then the built-in layout is used
      And every file the built-in layout loads besides its QML is there
