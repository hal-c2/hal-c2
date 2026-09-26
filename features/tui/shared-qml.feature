# Sources:
#   /home/olafura/dev/opentui-qml/docs/DESIGN.md (goal: the same QML on Qt and in the terminal)
#   apps/desktop-qt/qml/T3/Bricks/Sidebar.qml, SidebarThreadRow.qml
#   apps/desktop-qt/qml/T3/Bricks/Composer.qml
#   apps/desktop-qt/qml/T3/Bricks/SettingsNav.qml
#   apps/tui/src/components/Sidebar.tsx, ChatComposer.tsx, MessagesTimeline.tsx, SettingsView.tsx
#     (the React screens the shared QML replaces)
#   Shared domains: threads/, composer/, timeline/ and settings/ own the behaviour; this file owns
#   only the promise that one QML file drives every surface.

Feature: Shared QML screens on every surface
  The sidebar, composer, timeline and settings are written once in QML. The desktop and
  mobile apps render them with Qt and the terminal client renders them with opentui-qml.

  @backlog @shared
  Scenario Outline: One QML screen renders on Qt and in the terminal
    Given the shared QML screen "<screen>"
    When it is loaded by the desktop app, the mobile app and the terminal client
    Then each surface shows the same <content> from the same file

    Examples:
      | screen       | content                                             |
      | Sidebar      | projects, threads, shelves and status               |
      | Composer     | prompt, attachments and model, effort, mode, access |
      | Timeline     | messages, tool calls, approvals and plans           |
      | Settings     | settings sections and their values                  |

  @backlog @shared
  Scenario: A change to a shared screen reaches every surface
    Given the shared Sidebar gains a new thread action
    When the desktop app, the mobile app and the terminal client are rebuilt
    Then all three offer the new thread action

  @backlog @shared
  Scenario: Shared screens only use elements every runtime supports
    Given a shared QML screen
    When it is checked against the opentui-qml supported element list
    Then it uses no element or property the terminal runtime lacks

  @backlog @shared
  Scenario: A surface-specific detail is chosen at runtime, not by forking the file
    Given the shared Composer
    When it runs in the terminal client
    Then it reads the platform as "tui" and shows key hints instead of hover tooltips

  @backlog @shared
  Scenario: A plugin contribution to a shared slot shows on every surface
    Given a plugin that contributes a status item to the shared Sidebar's footer slot
    Then the status item shows on the desktop app, the mobile app and the terminal client

  @backlog @shared
  Scenario: Removing a plugin restores the shared slot's fallback on every surface
    Given a plugin contributes to the shared Sidebar's footer slot
    When the plugin is removed
    Then every surface shows the slot's fallback content again

  @backlog @shared
  Scenario: Shared screens keep the terminal's keyboard map
    Given the shared Sidebar and Composer run in the terminal client
    Then every chord in the terminal keymap still works

  @backlog @shared
  Scenario: Shared screens are driven by the same headless test in every runtime
    Given a Given/When/Then scenario for the shared Composer
    When it runs against Qt and against the opentui-qml test renderer
    Then both runs pass with the same steps
