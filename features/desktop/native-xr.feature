# Sources:
#   apps/desktop-qt/src/native/XrController.cpp (the window's XR workspace)
#   apps/desktop-qt/qml/HalC2/Bricks/XrHost.qml (starts and stops it)
#   Shared domain: desktop/xr-workspace.feature owns what the workspace shows and how a rice
#   lays it out; this file owns opening and closing it.
#   apps/desktop-qt/src/native/Keybindings.cpp (mod+alt+r, the desktop's own default)
#   packages/contracts/src/keybindings.ts (xr.toggle, xr.recenter)
#   apps/desktop-qt/tests/native/tst_Features.cpp (runs these scenarios against a fake node)

Feature: The desktop shows its window in XR glasses
  With XR glasses and an OpenXR runtime, the user can open an XR workspace that shows what the
  window shows on a panel in front of them. The glasses need a new frame for every head
  movement, so the workspace draws continuously and is only open while the user asks for it.
  The laptop keeps the keyboard and pointer.

  Background:
    Given the desktop's node "node-a" serves the environment "env-a"
    And the desktop shell is connected to its node

  @desktop
  Scenario: A new window starts without the XR workspace
    Then the XR workspace is closed

  @desktop
  Scenario: The user opens the XR workspace from the palette
    When the user runs "Toggle XR workspace" from the palette
    Then the XR workspace is open

  @desktop
  Scenario: The user closes the XR workspace
    Given the XR workspace is open
    When the user toggles the XR workspace
    Then the XR workspace is closed

  @desktop
  Scenario: The XR workspace cannot start
    Given the XR workspace is open
    When the XR workspace fails to start because "No OpenXR runtime is installed"
    Then the XR workspace is closed
    And the user sees an "error" toast "XR workspace unavailable" saying "No OpenXR runtime is installed"

  @desktop
  Scenario: The user recenters the XR workspace from the palette
    Given the XR workspace is open
    When the user runs "Recenter XR workspace" from the palette
    Then the XR workspace turns to face where the user is looking

  @desktop
  Scenario: The user recenters the XR workspace with its shortcut
    Given the XR workspace is open
    When the user presses mod+alt+r
    Then the XR workspace turns to face where the user is looking

  @desktop
  Scenario: Recentering does nothing while the XR workspace is closed
    When the user runs "Recenter XR workspace" from the palette
    Then the XR workspace does not turn
