import QtQuick
import HalC2.Shell

// Makes the window's XR workspace (XrWorkspace.qml) while Shell.state.xr.open
// (XrController, xr.toggle) and drops it after. It is made only then: it draws
// every frame the glasses show, and it needs Qt Quick 3D XR and an OpenXR
// runtime, whose absence it reports with xr.failed.
Item {
    id: host

    // What the workspace shows (ShellWindow.route).
    property var route: null
    readonly property bool open: Shell.state.xr ? Shell.state.xr.open === true : false
    property var workspace: null

    function start() {
        if (workspace)
            return;
        const component = Qt.createComponent(Qt.resolvedUrl("XrWorkspace.qml"));
        if (component.status !== Component.Ready) {
            Shell.dispatch("xr.failed", { message: component.errorString().trim() });
            return;
        }
        workspace = component.createObject(null, { route: Qt.binding(() => host.route) });
        if (!workspace)
            Shell.dispatch("xr.failed", { message: qsTr("The XR workspace could not be created.") });
    }

    function stop() {
        if (!workspace)
            return;
        workspace.destroy();
        workspace = null;
    }

    onOpenChanged: open ? start() : stop()
    Component.onCompleted: if (open) start()
    Component.onDestruction: stop()
}
