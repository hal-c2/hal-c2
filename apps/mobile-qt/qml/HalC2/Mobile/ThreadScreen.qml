import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// A thread, or a new thread's draft: the way back and its title, the route's
// centre (the timeline, or the draft's opening line that picks its project),
// and the composer, which carries the thread's approvals and questions.
// Files dropped anywhere on the centre or the composer join the draft.
Item {
    id: screen

    readonly property var route: Shell.state.route ?? null

    signal backRequested

    objectName: "threadScreen"

    ColumnLayout {
        id: column

        anchors.fill: parent
        spacing: 0

        MobileBar {
            Layout.fillWidth: true
            canGoBack: true
            title: screen.route !== null && screen.route.title ? screen.route.title : qsTr("Thread")
            onBackRequested: screen.backRequested()

            MobileIconButton {
                objectName: "threadMenu"
                iconName: "ellipsis"
                label: qsTr("Thread actions")
                // The menu the desktop's title opens: the thread's, or a draft's.
                onClicked: {
                    const point = mapToItem(null, width, height);
                    Shell.dispatch("workspace.titleMenu", { x: point.x, y: point.y });
                }
            }
        }

        CentreHost {
            id: centre

            objectName: "centreHost"
            Layout.fillWidth: true
            Layout.fillHeight: true
            kind: screen.route?.kind ?? ""
        }

        Composer {
            id: composerView

            objectName: "composer"
            Layout.fillWidth: true
            visible: ready
            conversationScrolled: centre.conversationScrolled
        }
    }

    ConversationDrop {
        y: centre.y
        width: column.width
        height: composerView.y + composerView.height - centre.y
        visible: composerView.visible
        composer: composerView
    }
}
