import QtQuick
import HalC2.Shell

// The stock XR layout (ShellWindow.xrWorkspace unset): the thread in front,
// its terminal a glance below, the thread list to the left and the project's
// files to the right. At 1.5 m the 1.2 x 0.75 m thread spans about 44 x 28
// degrees, most of the ~50 x 30 degree view of XREAL One glasses; the others
// sit just past its edges.
XrWorkspace {
    XrPanel {
        objectName: "xrThreads"
        angle: 34
        width: 45

        Sidebar {
            anchors.fill: parent
            showBrand: true
        }
    }

    XrPanel {
        objectName: "xrThread"

        CentreHost {
            anchors.fill: parent
            kind: Shell.state.route?.kind ?? ""
        }
    }

    XrPanel {
        objectName: "xrTerminal"
        elevation: -25
        height: 45

        XrTerminal {
            anchors.fill: parent
        }
    }

    XrPanel {
        objectName: "xrFiles"
        angle: -42
        width: 90

        XrFiles {
            anchors.fill: parent
        }
    }
}
