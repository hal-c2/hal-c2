# Sources:
#   /home/olafura/dev/opentui-qml/README.md
#   /home/olafura/dev/opentui-qml/docs/DESIGN.md (v1 scope and non-goals)
#   /home/olafura/dev/opentui-qml/docs/opentui-api-notes.md
#   /home/olafura/dev/opentui-qml/src/cli.ts
#   /home/olafura/dev/opentui-qml/src/components/ (text, rectangle, layouts, inputs, lists, containers,
#     misc, keymap, key-dispatcher, slot, window)
#   /home/olafura/dev/opentui-qml/src/runtime/ (engine, reactive, scope, qt, builtins, plugins)
#   /home/olafura/dev/opentui-qml/test/ (api, components, keymap, plugins, runtime-core, runtime-builtins,
#     runtime-engine, parser)
#   /home/olafura/dev/opentui-qml/examples/ (counter, todo, dashboard, plugin-host)
#   Shared domain: plugins/ owns the plugin model; this file is the terminal QML runtime's contract.

Feature: The opentui-qml runtime
  The terminal client's screens are QML documents rendered by opentui-qml. The runtime
  implements the part of QML those screens need, and says clearly what it does not.

  @tui
  Scenario: A QML file renders in the terminal
    Given a QML file whose root is a Rectangle with a titled border and a Text child
    When the user runs "opentui-qml" on it
    Then the terminal shows the bordered box with its title and the text

  @tui
  Scenario Outline: The command line reports its outcome with an exit code
    When the user runs "opentui-qml" <arguments>
    Then it exits with status <status>

    Examples:
      | arguments                      | status |
      | with "--help"                  | 0      |
      | with no arguments              | 2      |
      | with an unknown option         | 2      |
      | with a missing file            | 1      |
      | with a file that fails to load | 1      |

  @tui
  Scenario: Context values reach QML and are parsed as JSON when possible
    When the user runs "opentui-qml app.qml --context count=3 --context name=demo"
    Then QML sees "count" as the number 3 and "name" as the string "demo"

  @tui
  Scenario: A syntax error is reported with file and position before anything draws
    Given a QML file with an unterminated string on line 4
    When the user runs "opentui-qml" on it
    Then the error names the file, line and column
    And the terminal is left as it was

  @tui
  Scenario: A document whose root is not visual is rejected
    Given a QML file whose root is a QtObject
    When it is loaded
    Then loading fails and everything created so far is torn down

  @tui
  Scenario: Quitting from QML closes the renderer without killing the process
    Given a running QML document
    When it calls Qt.quit()
    Then the renderer is destroyed and the terminal is restored
    And the host process decides when to exit

  @tui
  Scenario Outline: Visual elements render their properties
    Given a QML document with <element>
    Then the terminal shows <result>

    Examples:
      | element                                   | result                                      |
      | a Text with bold and a wrap mode          | wrapped bold text                           |
      | a Rectangle with a radius                 | a box with rounded borders                  |
      | a Column and a Row of children            | children stacked and lined up               |
      | a Grid of children                        | children wrapping into rows                 |
      | a RowLayout child with Layout.fillWidth   | that child growing to fill the row          |
      | an item with visible set to false         | nothing for that item                       |
      | a TabBar with three tabs                  | the three tab labels                        |
      | an AsciiText                              | large ASCII lettering                       |
      | a Markdown block                          | styled Markdown                             |
      | a Code block with a file type             | highlighted code                            |

  @tui
  Scenario: Layout results are readable from QML
    Given an item anchored to fill its parent
    Then its x, y, layout width and layout height match the parent's content area

  @tui
  Scenario: A binding updates the terminal when its inputs change
    Given a Text whose text is bound to a counter property
    When the counter changes
    Then the next frame shows the new value
    And the Text's onTextChanged handler runs

  @tui
  Scenario: Assigning a bound property breaks the binding until Qt.binding restores it
    Given a property bound to another property
    When a handler assigns it a plain value
    Then it stops following the other property
    And assigning Qt.binding makes it follow again

  @tui
  Scenario: A failing binding keeps the previous value and logs once
    Given a binding that throws after its first evaluation
    Then the property keeps its last good value
    And the error is logged once with the file and line

  @tui
  Scenario: A binding loop is logged instead of crashing
    Given two properties bound to each other
    Then the loop is logged and the document keeps running

  @tui
  Scenario: Names resolve through the QML scope chain
    Given a delegate that reads a name defined on itself, its parent, a document id and a context value
    Then each name resolves to the nearest definition in that order

  @tui
  Scenario: Signals carry named parameters to handlers
    Given a signal "moved(int x, int y)"
    When it is emitted with 3 and 4
    Then a block handler sees "x" as 3 and "y" as 4

  @tui
  Scenario: A handler that throws does not stop other handlers
    Given two handlers connected to the same signal and the first throws
    When the signal is emitted
    Then the second handler still runs

  @tui
  Scenario: Component.onCompleted runs bottom-up after bindings settle
    Given a parent and a child that both handle Component.onCompleted
    Then the child's handler runs before the parent's
    And both see their bound values

  @tui
  Scenario: A sibling QML file is usable as a type
    Given "Card.qml" next to "main.qml"
    When "main.qml" uses "Card" with its own bindings
    Then the user's bindings win over Card's defaults
    And Card's internal ids stay private

  @tui
  Scenario: A Repeater inserts its delegates where it stands
    Given a Column with a Text, a Repeater of three delegates, and another Text
    Then the three delegates render between the two Texts

  @tui
  Scenario: A Repeater follows its ListModel
    Given a Repeater over a ListModel with two rows
    When a row is appended and another moved
    Then the rendered delegates match the model's rows and order

  @tui
  Scenario: Destroying a Repeater destroys its delegates
    Given a Repeater with delegates on screen
    When the Repeater is destroyed
    Then its delegates disappear from the terminal

  @tui
  Scenario: A ListView is navigated with the arrow keys
    Given a focused ListView over three items
    When the user presses "Down" and then "Enter"
    Then currentIndex is 1 and the activated signal fires for it

  @tui
  Scenario: A Loader creates its item synchronously and removes it when inactive
    Given a Loader with a sourceComponent
    Then its item exists immediately
    And setting active to false destroys the item

  @tui
  Scenario: A Timer fires on its interval and stops when told
    Given a repeating Timer with an interval of 100 ms
    When 300 ms pass
    Then it has fired three times
    And stopping it prevents further triggers

  @tui
  Scenario: Connections follow a changing target
    Given Connections attached to one object
    When its target changes to another object
    Then handlers run for the new target's signals only

  @tui
  Scenario: The root sees every key and focused items see theirs
    Given a root Keys.onPressed handler and a focused child with its own handler
    When the user presses "a"
    Then the child's handler runs first
    And the root handler does not run if the child accepted the key

  @tui
  Scenario: Typing in a focused text input updates its text
    Given a focused TextField
    When the user types "hello" and presses "Enter"
    Then the text is "hello"
    And the textEdited and accepted signals fire

  @tui
  Scenario: Setting a text input's text from QML does not count as editing
    Given a TextField
    When QML assigns its text
    Then textEdited does not fire

  @tui
  Scenario: Shortcuts and keymaps dispatch by priority then document order
    Given two keymaps bound to "Ctrl+S" with different priorities
    When the user presses "Ctrl+S"
    Then only the higher-priority binding runs

  @tui
  Scenario: A binding can let a key pass through
    Given a keymap binding for "Ctrl+S" whose handler sets accepted to false
    When the user presses "Ctrl+S"
    Then the next binding for "Ctrl+S" also runs

  @tui
  Scenario: Printable keys go to a focused text input before shortcuts
    Given a shortcut bound to "q" and a focused TextField
    When the user types "q"
    Then "q" is typed into the field and the shortcut does not fire

  @tui
  Scenario: Disabled or destroyed shortcuts do nothing
    Given a Shortcut for "Ctrl+Q" that is disabled
    When the user presses "Ctrl+Q"
    Then nothing happens

  @tui
  Scenario Outline: A keymap JSON file overrides bindings at startup
    Given the document has <keymap>
    When the user runs "opentui-qml app.qml --keymap keys.json" with <override>
    Then <result>

    Examples:
      | keymap                     | override                               | result                                  |
      | an unnamed keymap          | "save" bound to "Ctrl+W"               | "Ctrl+W" runs save                      |
      | a keymap named "editor"    | "editor" with "save" bound to "Ctrl+W" | "Ctrl+W" runs save in "editor"          |
      | an unnamed keymap          | "save" set to null                     | save has no key                         |

  @tui
  Scenario: A keymap describes its bindings for help screens
    Given a keymap with bindings
    Then describe() lists each action with its keys

  @tui
  Scenario: An invalid key sequence warns instead of failing
    Given a Shortcut with the sequence "Ctrl+"
    Then a warning is logged and the document still runs

  @tui
  Scenario Outline: A slot's mode decides what it shows
    Given a Slot in <mode> mode with fallback children and <contributions>
    Then it shows <shown>

    Examples:
      | mode          | contributions         | shown                                    |
      | replace       | no contributions      | its fallback children                    |
      | replace       | two contributions     | both contributions without the fallback  |
      | append        | two contributions     | the fallback followed by both            |
      | single_winner | two contributions     | only the first contribution by order     |

  @tui
  Scenario: A slot's fallback returns when its last plugin is removed
    Given a Slot showing a plugin's contribution
    When that plugin is unregistered
    Then the Slot shows its fallback children again

  @tui
  Scenario: Contributions are ordered by plugin order and re-sort live
    Given two plugins contributing to the same Slot
    When the second plugin's order is lowered below the first
    Then the Slot shows the second plugin's contribution first

  @tui
  Scenario: A managed contribution keeps its instance while slot data changes
    Given a managed contribution in a Slot
    When the Slot's data changes
    Then the same delegate instance shows the new data

  @tui
  Scenario: Plugins in a directory load before the document
    When the user runs "opentui-qml app.qml --plugins ./plugins"
    Then every file there whose root is Plugin is loaded before "app.qml"
    And helper types in that directory are not treated as plugins

  @tui
  Scenario Outline: Plugin failures are isolated and reported
    Given a plugins directory with a good plugin and <failure>
    When the document loads
    Then the good plugin's contribution renders
    And the document's pluginError signal receives the failure

    Examples:
      | failure                                        |
      | a plugin file with a syntax error              |
      | a plugin whose delegate fails to render        |
      | a second plugin with the same pluginId         |
      | a plugin whose contribution is not visual      |

  @backlog @tui
  Scenario Outline: v1 non-goals of the QML runtime
    Given a QML document that uses <feature>
    When it is loaded
    Then it behaves as it does in Qt

    Examples:
      | feature                                  |
      | States and Transitions                   |
      | anchors other than fill and centerIn     |
      | an asynchronous Loader                   |
      | a qmldir module import                   |
      | a .js file import                        |
      | ListView delegates                       |
      | MouseArea                                |
