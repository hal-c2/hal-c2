import QtQuick
import QtQuick3D
import QtQuick3D.Xr
import HalC2.Shell

// The XR workspace's scene (XrHost makes one while it is open): the user at
// the origin, see-through around the panels (XrPanel) a layout places. Black
// is see-through on optical see-through glasses such as XREAL's.
// DefaultXrWorkspace is the stock layout; a rice sets ShellWindow.xrWorkspace
// to its own (it needs Qt Quick 3D XR):
//
//   xrWorkspace: Component {
//       XrWorkspace {
//           XrPanel { CentreHost { anchors.fill: parent; kind: root.route?.kind ?? "" } }
//           XrPanel { elevation: -25; height: 45; XrTerminal { anchors.fill: parent } }
//       }
//   }
XrView {
    xrOrigin: origin
    referenceSpace: XrView.ReferenceSpaceLocal
    environment: SceneEnvironment {
        backgroundMode: SceneEnvironment.Color
        clearColor: "black"
    }
    onInitializeFailed: errorString => Shell.dispatch("xr.failed", { message: errorString })

    XrOrigin {
        id: origin
    }
}
