pragma Singleton
import QtQuick

// The native terminal drawer's controller (TerminalController), as state a
// test sets directly. `addTab` adds a terminal whose session records what the
// Terminal writes and prints nothing. The native layout tests register this
// file too (qmlRegisterSingletonType).
QtObject {
    id: terminals

    property bool available: false
    property bool open: false
    property int height: 280
    property string activeTerminalId: ""
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

    signal focusRequested

    function addTab(terminalId, label) {
        tabs.append({
            terminalId: terminalId,
            label: label,
            busy: false,
            session: sessionComponent.createObject(terminals)
        });
    }

    function reset() {
        available = false;
        open = false;
        height = 280;
        activeTerminalId = "";
        tabs.clear();
    }
}
