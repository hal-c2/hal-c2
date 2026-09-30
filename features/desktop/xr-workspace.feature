# Sources:
#   apps/desktop-qt/qml/HalC2/Bricks/DefaultXrWorkspace.qml (the stock layout)
#   apps/desktop-qt/qml/HalC2/Bricks/XrWorkspace.qml, XrPanel.qml, XrTerminal.qml, XrFiles.qml (the bricks a rice lays out)
#   apps/desktop-qt/qml/HalC2/Bricks/ShellWindow.qml (xrWorkspace)
#   apps/desktop-qt/tests/native/tst_ShellExamples.cpp (these scenarios, by name; skipped without
#   Qt Quick 3D XR; not run by tst_Features)
#   Shared domain: desktop/native-xr.feature owns opening and closing the workspace; this file
#   owns what it shows.

Feature: The XR workspace surrounds the user with the window's panels
  In the XR workspace the window's parts float around the user: what they are working on in
  front, the rest a turn or a glance away. The layout is part of the shell, so a rice can
  rearrange it like the rest of the window.

  Background:
    Given the XR workspace is open

  @desktop
  Scenario: The stock workspace puts the thread in front of the user
    Then the user sees the thread in front of them
    And the user sees the thread list to their left
    And the user sees the thread's terminal below the thread
    And the user sees the project's files to their right

  @desktop
  Scenario: The workspace's terminal follows the thread's without taking it over
    When the thread's terminal prints output
    Then the workspace's terminal shows it
    And the thread's terminal keeps its size and the keyboard

  @desktop
  Scenario: The project's files stay loaded while the workspace shows them
    Given the right panel shows another tab
    Then the workspace's files are loaded
    When the XR workspace closes
    Then the files are loaded only when the right panel shows them again

  @desktop
  Scenario: A rice lays out its own workspace
    Given the user's shell places its own panels in the XR workspace
    Then the user sees the rice's panels instead of the stock ones
