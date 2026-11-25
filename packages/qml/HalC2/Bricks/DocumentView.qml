pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Pdf
import HalC2.Bricks
import HalC2.Shell

// A PDF the user can page through. `source` is a local file, which is all Qt PDF
// opens. Loaded by a Loader, so a machine without Qt PDF only loses this view.
// `failed` says the file is not a document it can read.
FocusScope {
    id: root

    objectName: "documentView"
    property url source
    readonly property int pageCount: document.pageCount
    readonly property int currentPage: pages.currentPage
    signal failed(url source)

    function goTo(page) {
        pages.goToPage(Math.max(0, Math.min(pageCount - 1, page)));
    }

    Keys.onPressed: event => {
        if (event.key === Qt.Key_PageDown)
            goTo(currentPage + 1);
        else if (event.key === Qt.Key_PageUp)
            goTo(currentPage - 1);
        else
            return;
        event.accepted = true;
    }

    PdfDocument {
        id: document

        source: root.source
        onStatusChanged: if (status === PdfDocument.Error)
            root.failed(root.source)
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 8

        PdfMultiPageView {
            id: pages

            Layout.fillWidth: true
            Layout.fillHeight: true
            document: document
        }
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 8

            ShellButton {
                objectName: "documentPrevious"
                subtle: true
                enabled: root.currentPage > 0
                text: qsTr("Previous")
                onClicked: root.goTo(root.currentPage - 1)
            }
            Text {
                objectName: "documentPage"
                text: qsTr("Page %1 of %2").arg(root.currentPage + 1).arg(root.pageCount)
                color: Theme.palette.color("textMuted", "#a1a1aa")
                font.pixelSize: Theme.type.meta.size
            }
            ShellButton {
                objectName: "documentNext"
                subtle: true
                enabled: root.currentPage < root.pageCount - 1
                text: qsTr("Next")
                onClicked: root.goTo(root.currentPage + 1)
            }
        }
    }
}
