import QtQuick
import HalC2.Shell

// The project's files for an XR panel (FilesPanel on Panel.files), kept loaded
// while it is shown even when the right panel shows another tab.
FilesPanel {
    source: Panel.files

    Component.onCompleted: Panel.setFilesShownElsewhere(true)
    Component.onDestruction: Panel.setFilesShownElsewhere(false)
}
