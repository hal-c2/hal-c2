pragma Singleton
import QtQuick

// The native terminals' controller (TerminalController), as state a test sets
// directly. `addTab` adds a terminal whose session records what the Terminal
// writes and prints nothing; `options` places it in a split or panel group. The native layout tests register this
// file too (qmlRegisterSingletonType).
QtObject {
    id: terminals

    property bool available: false
    property bool open: false
    property int height: 280
    property string activeTerminalId: ""
    property string activeGroup: ""
    property var groupSizes: ({})
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

    function addTab(terminalId, label, options) {
        const place = options ?? {};
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
        focused = [];
        tabs.clear();
    }
}
