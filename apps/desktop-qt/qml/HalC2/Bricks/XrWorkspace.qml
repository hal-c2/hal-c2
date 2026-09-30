import QtQuick
import QtQuick3D
import QtQuick3D.Xr
import HalC2.Shell

// The XR workspace XrHost makes: the window's centre (CentreHost) on a panel
// in front of the user, in whatever glasses the OpenXR runtime drives. Only
// the laptop takes input; the panel follows what the window shows.
XrView {
    id: view

    // The route to show (ShellWindow.route).
    property var route: null

    xrOrigin: origin
    referenceSpace: XrView.ReferenceSpaceLocal
    // Black is see-through on optical see-through glasses such as XREAL's.
    environment: SceneEnvironment {
        backgroundMode: SceneEnvironment.Color
        clearColor: "black"
    }
    onInitializeFailed: errorString => Shell.dispatch("xr.failed", { message: errorString })

    XrOrigin {
        id: origin
    }

    // 1.2 m by 0.75 m, 1.5 m ahead at eye height (scene units are centimetres).
    XrItem {
        width: 120
        height: 75
        x: -width / 2
        y: height / 2
        z: -150
        color: Theme.palette.color("chrome", "#0b0b0d")
        contentItem: CentreHost {
            width: 1280
            height: 800
            kind: view.route ? view.route.kind : ""
        }
    }
}
