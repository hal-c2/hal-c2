import QtQuick
import HalC2.Shell

// Who else is on the open page (Spaces.viewers): the user's other devices and
// the agents working on it. Takes no room when nobody else is.
Text {
    readonly property var names: {
        const agents = Array.from(Spaces.viewers.agents ?? []).map(title => qsTr("the agent of “%1”").arg(title));
        return Array.from(Spaces.viewers.devices ?? []).concat(agents);
    }

    objectName: "spaceViewers"
    visible: names.length > 0
    text: qsTr("Also here: %1").arg(names.join(", "))
    color: Theme.palette.color("textMuted", "#a1a1aa")
    font.pixelSize: Theme.type.meta.size
    elide: Text.ElideRight
}
