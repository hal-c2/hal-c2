import QtQuick
import QtQuick.Controls.Material
import QtQuick.Layouts
import HalC2.Shell
import HalC2.Bricks

// The shell's menus (`menu`, MenuController: a thread's, a draft's, the
// projects a draft can move to) as a sheet from the bottom edge with rows a
// finger wide, in place of the popup the desktop opens at the pointer. One
// level of children reads as a headed group, as it does there. The choice
// goes back as `menu.select`, and closing the sheet any other way chooses
// nothing.
Popup {
    id: sheet

    readonly property var request: Shell.state.menu ?? null
    readonly property var rows: {
        const out = [];
        for (const item of request !== null ? request.items : []) {
            const children = item.children ?? [];
            out.push(Object.assign({}, item, { header: children.length > 0 }));
            for (const child of children)
                out.push(Object.assign({}, child, { header: false }));
        }
        return out;
    }
    property string shownRequestId: ""
    property bool chosen: false

    function choose(id) {
        if (request !== null)
            Shell.dispatch("menu.select", { requestId: request.requestId, id: id });
    }

    onRequestChanged: {
        if (request === null) {
            close();
        } else if (request.requestId !== shownRequestId) {
            shownRequestId = request.requestId;
            chosen = false;
            open();
        }
    }
    onClosed: {
        if (!chosen)
            choose(null);
    }

    objectName: "mobileMenu"
    modal: true
    // With the keyboard's focus, the system's back closes it.
    focus: true
    x: (parent.width - width) / 2
    y: parent.height - height
    width: Math.min(parent.width, 520)
    height: Math.min(implicitHeight, parent.height - 24)
    padding: 0
    topPadding: 8
    bottomPadding: 8

    background: MobileSurface {}
    Overlay.modal: MobileScrim {}

    contentItem: ListView {
        implicitHeight: contentHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: sheet.rows

        delegate: ItemDelegate {
            id: row

            required property var modelData
            readonly property bool usable: modelData.header !== true && modelData.enabled !== false && modelData.disabled !== true
            readonly property color tint: Theme.palette.color(modelData.destructive === true ? "error" : modelData.header === true ? "textMuted" : "text", "#e4e4e7")

            objectName: "mobileMenuItem:" + modelData.id
            width: ListView.view.width
            height: modelData.header === true ? 36 : 48
            enabled: usable
            Accessible.name: modelData.label
            onClicked: {
                sheet.chosen = true;
                sheet.choose(modelData.id);
            }

            contentItem: RowLayout {
                spacing: 16

                ShellIcon {
                    visible: !row.modelData.header
                    name: row.modelData.icon ?? ""
                    size: 18
                    color: Qt.alpha(row.tint, row.usable ? 0.8 : 0.4)
                }

                Label {
                    Layout.fillWidth: true
                    text: row.modelData.label
                    elide: Text.ElideRight
                    color: Qt.alpha(row.tint, row.usable || row.modelData.header === true ? 1 : 0.5)
                    font.pixelSize: Math.round((row.modelData.header === true ? 13 : 15) * Theme.fontScale)
                    font.weight: row.modelData.header === true ? Font.DemiBold : Font.Normal
                }

                ShellIcon {
                    visible: row.modelData.checked === true
                    name: "check"
                    size: 18
                    color: row.tint
                }
            }
        }
    }
}
