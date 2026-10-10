import QtQuick
import Ghostty
import HalC2.Shell

// An agent's login terminal: draws the
// output the environment sends, `{output, offset}` where `offset` counts every
// character the terminal has printed and `output` is the latest of them, and
// sends keystrokes and sizes back through `providerSettings.signInTerminal`.
//
//   Loader { source: "ProviderAuthTerminal.qml"; onLoaded: item.instanceId = … }
Rectangle {
    id: root

    property string instanceId: ""
    property var terminal: null
    // How far the Terminal has drawn, in the environment's count.
    property real written: 0

    function draw() {
        if (!root.terminal)
            return;
        const output = root.terminal.output;
        const delta = root.terminal.offset - root.written;
        if (delta > 0 && delta <= output.length)
            screen.write(output.slice(output.length - delta));
        else if (delta !== 0) {
            screen.reset();
            screen.write(output);
        }
        root.written = root.terminal.offset;
    }

    objectName: "signInTerminal"
    implicitHeight: 256
    radius: 6
    color: Theme.palette.color("canvas", "#09090b")
    border.color: Theme.palette.color("border", "#27272a")
    clip: true
    Accessible.name: qsTr("Provider sign-in terminal")
    onTerminalChanged: draw()

    Terminal {
        id: screen

        objectName: "HalC2Terminal"
        anchors.fill: parent
        anchors.margins: 1
        padding: 6
        focus: true
        // A whole font: the Terminal's default carries a point size, which a
        // pixel size set over it warns about.
        font: Qt.font({
            family: Theme.fontTerminal.length > 0 ? Theme.fontTerminal : "monospace",
            pixelSize: Theme.fontSizeTerminal
        })
        backgroundColor: root.color
        foregroundColor: Theme.palette.color("text", "#e4e4e7")
        cursorColor: Theme.palette.color("text", "#e4e4e7")
        selectionColor: Qt.alpha(Theme.palette.color("accent", "#2563eb"), 0.35)
        Keys.onPressed: event => menu.keyPressed(event)
        onInput: data => Shell.dispatch("providerSettings.signInTerminal", {
            instanceId: root.instanceId,
            data: data
        })
        onResized: (columns, rows) => {
            if (screen.width > 0 && screen.height > 0)
                Shell.dispatch("providerSettings.signInTerminal", {
                    instanceId: root.instanceId,
                    data: "",
                    columns: columns,
                    rows: rows
                });
        }
        Component.onCompleted: root.draw()

        // No draft here to add a selection to: copy and paste only.
        TapHandler {
            acceptedButtons: Qt.RightButton
            onTapped: eventPoint => menu.popup(eventPoint.position.x, eventPoint.position.y)
        }

        TerminalMenu {
            id: menu

            terminal: screen
        }
    }
}
