import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// What the composer says while notices wait behind the one in front
// (Shell.state.noticeStack, NoticeStackController): asking for them draws
// them all, Escape or asking again leaves only the front one.
RowLayout {
    id: peek

    readonly property var stack: Shell.state.noticeStack ?? null
    readonly property int behind: stack ? stack.behind ?? 0 : 0
    readonly property bool expanded: stack?.expanded === true

    objectName: "noticeStackPeek"
    visible: behind > 0
    spacing: 6

    ShellButton {
        id: toggle

        objectName: "noticeStackToggle"
        subtle: true
        iconName: "layers"
        text: peek.expanded ? qsTr("Hide other notices") : peek.behind === 1 ? qsTr("1 other notice") : qsTr("%1 other notices").arg(peek.behind)
        Accessible.name: peek.expanded ? qsTr("Hide other notices") : qsTr("Show other notices")
        onClicked: {
            Shell.dispatch(peek.expanded ? "noticeStack.collapse" : "noticeStack.expand", {});
            forceActiveFocus();
        }

        Keys.onEscapePressed: event => {
            if (!peek.expanded)
                return;
            event.accepted = true;
            Shell.dispatch("noticeStack.collapse", {});
        }
    }

    Item {
        Layout.fillWidth: true
    }
}
