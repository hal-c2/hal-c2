pragma Singleton
import QtQuick

// The native terminals' controller (TerminalController), as state a test sets
// directly. `addTab` adds a terminal whose session records what the Terminal
// writes and prints nothing; `options` places it in a split or panel group. The native layout tests register this
// file too (qmlRegisterSingletonType).
QtObject {
    id: terminals

    // Whether the build has a terminal at all; the desktop's always does.
    readonly property bool supported: true
    property bool available: false
    property bool open: false
    property int height: 280
    property string activeTerminalId: ""
    property string activeGroup: ""
    property var groupSizes: ({})
    property int drawerCount: 0
    property var focused: []
    property ListModel tabs: ListModel {}

    property Component sessionComponent: Component {
        QtObject {
            property var written: []

            signal output(string data)
            signal replaced(string history)

            function transcript() {
                return "";
            }
            function report(message) {
            }
            function write(data) {
                written.push(data);
            }
            function resize(columns, rows) {
            }
        }
    }

    signal focusRequested(string terminalId)

    function focusTerminal(terminalId) {
        focused.push(terminalId);
    }

    function terminalFont(family, pixelSize, pointSize) {
        const name = family.length > 0 ? family : "monospace";
        return pointSize > 0 ? Qt.font({ family: name, pointSize: pointSize }) : Qt.font({ family: name, pixelSize: pixelSize });
    }

    function addTab(terminalId, label, options) {
        const place = options ?? {};
        if (!(place.panel ?? false))
            drawerCount += 1;
        tabs.append({
            terminalId: terminalId,
            label: label,
            busy: false,
            session: sessionComponent.createObject(terminals),
            group: place.group ?? terminalId,
            panel: place.panel ?? false,
            slot: place.slot ?? 0,
            span: place.span ?? 1,
            vertical: place.vertical ?? false,
            current: place.current ?? false
        });
    }

    function reset() {
        available = false;
        open = false;
        height = 280;
        activeTerminalId = "";
        activeGroup = "";
        groupSizes = {};
        drawerCount = 0;
        focused = [];
        tabs.clear();
    }
}
