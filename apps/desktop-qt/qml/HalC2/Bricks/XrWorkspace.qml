import QtQuick
import QtQuick3D
import QtQuick3D.Xr
import HalC2.Shell

// The XR workspace's scene (XrHost makes one while it is open): the user at
// the origin, see-through around the panels (XrPanel) a layout places, turned
// to face the user when they recenter. Black
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
    id: view

    // Counts the user's recenters (xr.recenter, mod+alt+r).
    readonly property int recenterRequest: Shell.state.xr ? Shell.state.xr.recenter ?? 0 : 0

    // Turns the scene about the user so they face its -Z again, as headsets
    // recenter: yaw only, so the floor stays level.
    function recenter() {
        const forward = head.forward;
        const yaw = Math.atan2(-forward.x, -forward.z) * 180 / Math.PI;
        origin.eulerRotation.y -= yaw;
    }

    onRecenterRequestChanged: recenter()
    xrOrigin: origin
    referenceSpace: XrView.ReferenceSpaceLocal
    environment: SceneEnvironment {
        backgroundMode: SceneEnvironment.Color
        clearColor: "black"
    }
    onInitializeFailed: errorString => Shell.dispatch("xr.failed", { message: errorString })

    XrOrigin {
        id: origin

        objectName: "xrOrigin"
        camera: head

        // The user's head, as the glasses track it.
        XrCamera {
            id: head
        }
    }
}
