import QtQuick
import Ghostty
import HalC2.Shell

// The welcome wizard's setup terminal: `Onboarding.terminal`, the session the
// MC runs as the provider instance, with the install or sign-in command
// typed and waiting for Enter. Loaded by WelcomeWizard only while it is ready,
// so the QML tests never need Ghostty.
Rectangle {
    id: root

    readonly property QtObject session: Onboarding.terminal

    objectName: "onboardingTerminal"
    implicitHeight: 256
    radius: 6
    color: Theme.palette.color("canvas", "#09090b")
    border.color: Theme.palette.color("border", "#27272a")
    clip: true
    Accessible.name: qsTr("Agent setup terminal")

    Terminal {
        id: screen

        anchors.fill: parent
        anchors.margins: 1
        padding: 6
        focus: true
        font.family: Theme.fontTerminal.length > 0 ? Theme.fontTerminal : "monospace"
        font.pixelSize: Theme.fontSizeTerminal
        backgroundColor: root.color
        foregroundColor: Theme.palette.color("text", "#e4e4e7")
        cursorColor: foregroundColor
        selectionColor: Qt.alpha(Theme.palette.color("accent", "#2563eb"), 0.35)
        Keys.onPressed: event => menu.keyPressed(event)
        onInput: data => {
            if (root.session)
                root.session.write(data);
        }
        onResized: (columns, rows) => {
            if (root.session && screen.width > 0 && screen.height > 0)
                root.session.resize(columns, rows);
        }
        Component.onCompleted: {
            if (!root.session)
                return;
            screen.restore(root.session.transcript());
            if (screen.width > 0 && screen.height > 0)
                root.session.resize(screen.columns, screen.rows);
        }

        // No draft here to add a selection to: copy and paste only.
        TapHandler {
            acceptedButtons: Qt.RightButton
            onTapped: eventPoint => menu.popup(eventPoint.position.x, eventPoint.position.y)
        }

        TerminalMenu {
            id: menu

            terminal: screen
        }

        Connections {
            target: root.session
            function onOutput(data) {
                screen.write(data);
            }
            function onReplaced(history) {
                screen.reset();
                screen.restore(history);
            }
        }
    }
}
