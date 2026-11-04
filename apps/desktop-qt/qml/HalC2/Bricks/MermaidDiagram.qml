pragma ComponentBehavior: Bound
import QtQuick
import HalC2.Shell

// A Mermaid diagram the MC draws for `code` in the client's theme
// (MermaidController, the `Diagrams` singleton, which asks once per theme and
// source). Once drawn it is the picture, never wider than it was drawn; until
// then one static line says it is being drawn, or why it cannot be, with a way
// to ask again when the MC failed. Whoever shows it keeps the source on screen
// while `drawn` is false.
Item {
    id: diagram

    property string code: ""
    // Off while the source is still being written: nothing is asked for.
    property bool active: true
    property color textColor: Theme.palette.color("textMuted", "#818181")
    // Which parts it shows: a page shows the picture in place of the block's
    // text and the note under it.
    property bool showPicture: true
    property bool showNote: true
    property real padding: 12

    readonly property var answer: {
        Diagrams.revision;
        return active ? Diagrams.diagram(code, Theme.appearance === "light" ? "light" : "dark") : ({});
    }
    readonly property bool drawn: answer.status === "drawn"
    readonly property string kind: answer.kind ?? ""
    // What the line under the source says.
    readonly property string note: {
        if (answer.status === "drawing")
            return qsTr("Drawing the diagram…");
        const reason = answer.reason ?? "";
        return answer.line > 0 ? qsTr("Line %1: %2").arg(answer.line).arg(reason) : reason;
    }

    implicitWidth: picture.visible ? answer.width + 2 * padding : 0
    implicitHeight: picture.visible ? picture.height + 2 * padding : status.visible ? status.height + 2 * Math.min(padding, 8) : 0

    Image {
        id: picture
        objectName: "mermaidImage"
        visible: diagram.drawn && diagram.showPicture
        x: diagram.padding
        y: diagram.padding
        width: diagram.drawn ? Math.min(diagram.answer.width, diagram.width - 2 * diagram.padding) : 0
        height: diagram.drawn && diagram.answer.width > 0 ? width * diagram.answer.height / diagram.answer.width : 0
        // Drawn once at the size the MC laid it out, then only scaled down.
        sourceSize: diagram.drawn ? Qt.size(Math.ceil(diagram.answer.width), Math.ceil(diagram.answer.height)) : Qt.size(0, 0)
        source: diagram.drawn ? diagram.answer.url : ""
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        Accessible.role: Accessible.Graphic
        Accessible.name: diagram.kind.length > 0 ? qsTr("%1 diagram").arg(diagram.kind) : qsTr("Diagram")
    }

    Row {
        id: status
        visible: !diagram.drawn && diagram.active && diagram.showNote
        x: diagram.padding
        y: Math.min(diagram.padding, 8)
        width: diagram.width - 2 * diagram.padding
        spacing: 8

        Text {
            objectName: "mermaidStatus"
            width: status.width - (retry.visible ? retry.width + status.spacing : 0)
            anchors.verticalCenter: parent.verticalCenter
            text: diagram.note
            wrapMode: Text.Wrap
            color: diagram.textColor
            font.pixelSize: Theme.type.meta.size
        }

        ShellButton {
            id: retry
            objectName: "mermaidRetry"
            visible: diagram.answer.status === "failed"
            subtle: true
            iconName: "refresh-cw"
            implicitHeight: 24
            implicitWidth: 24
            iconSize: 12
            Accessible.name: qsTr("Draw again")
            onClicked: Diagrams.retry(diagram.code, Theme.appearance === "light" ? "light" : "dark")
        }
    }
}
