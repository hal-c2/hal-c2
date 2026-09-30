import QtQuick
import HalC2.Shell

// Makes the window's XR workspace while Shell.state.xr.open (XrController,
// xr.toggle) and drops it after: `layout` (ShellWindow.xrWorkspace), or
// DefaultXrWorkspace.qml when a rice sets none. It is made only then: it draws
// every frame the glasses show, and it needs Qt Quick 3D XR and an OpenXR
// runtime, whose absence it reports with xr.failed.
Item {
    id: host

    // The rice's XrWorkspace, or null for the stock one.
    property Component layout: null
    readonly property bool open: Shell.state.xr ? Shell.state.xr.open === true : false
    property var workspace: null

    function start() {
        if (workspace)
            return;
        const component = layout ?? Qt.createComponent(Qt.resolvedUrl("DefaultXrWorkspace.qml"));
        if (component.status !== Component.Ready) {
            Shell.dispatch("xr.failed", { message: component.errorString().trim() });
            return;
        }
        workspace = component.createObject(null);
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
