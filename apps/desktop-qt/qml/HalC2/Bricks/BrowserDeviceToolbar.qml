pragma ComponentBehavior: Bound
import QtQuick
import HalC2.Shell
import "js/browser.js" as BrowserJs

// The device toolbar above a device-sized browser tab (BrowserPanel): the
// size the page renders at, picked from the presets ("Responsive" keeps the
// size and frees it) or typed (applied on Enter or leaving the fields; a size
// the preview cannot render is not), its aspect ratio locked or not, turned
// on its side, or closed to fill the tab again. Nothing can be used while the
// MC has not confirmed the last size (`page.resizing`).
//
//   BrowserDeviceToolbar { page: page; viewport: root.viewport }
Rectangle {
    id: toolbar

    property BrowserPage page: null
    // The size shown, a drag in progress included.
    property var viewport: ({ _tag: "fill" })
    // Width over height while the aspect ratio is locked, else 0.
    property real ratio: 0
    // What the user is typing ({width, height} as text), until it is applied.
    property var draft: null
    // The size picked and the ratio it changed from and to, until the MC answers.
    property var picking: null
    readonly property bool busy: page ? page.resizing : false
    readonly property int typedWidth: Number(draft ? draft.width : viewport.width)
    readonly property int typedHeight: Number(draft ? draft.height : viewport.height)
    readonly property bool usable: BrowserJs.sizeAllowed(Number(draft ? draft.width : viewport.width), Number(draft ? draft.height : viewport.height))

    objectName: "browserDeviceToolbar"
    implicitHeight: 32
    color: Theme.palette.color("surface", "#0f0f11")

    function apply(next, nextRatio) {
        draft = null;
        picking = { viewport: next, ratio: nextRatio, before: ratio };
        ratio = nextRatio;
        page.setViewport(next);
        answered();
    }

    // A size the MC did not take takes its ratio back with it.
    function answered() {
        if (busy || picking === null)
            return;
        ratio = BrowserJs.ratioAnswered(picking, page.viewport);
        picking = null;
    }

    // What was typed, if it is a size that can be used and not the one shown.
    function applyDraft() {
        if (draft === null)
            return;
        if (!usable || (typedWidth === viewport.width && typedHeight === viewport.height)) {
            draft = null;
            return;
        }
        apply({ _tag: "freeform", width: typedWidth, height: typedHeight }, ratio);
    }

    // The user typed `text` for `axis`: with the ratio locked, the other side
    // follows a side that can be used, and the typed one stays as typed.
    function edit(axis, text) {
        const next = {
            width: axis === "width" ? text : (draft ? draft.width : String(viewport.width)),
            height: axis === "height" ? text : (draft ? draft.height : String(viewport.height))
        };
        const value = Number(text);
        if (ratio > 0 && Number.isInteger(value) && value >= BrowserJs.minSide && value <= BrowserJs.maxSide) {
            const size = BrowserJs.resized(viewport, axis === "width" ? value - viewport.width : 0, axis === "height" ? value - viewport.height : 0, ratio);
            if (axis === "width")
                next.height = String(size.height);
            else
                next.width = String(size.width);
        }
        draft = next;
    }

    function pick(id) {
        if (id === "responsive") {
            if (viewport._tag !== "freeform")
                apply({ _tag: "freeform", width: viewport.width, height: viewport.height }, ratio);
            return;
        }
        const preset = BrowserJs.preset(id);
        apply(BrowserJs.viewportOf(id), ratio > 0 ? preset.width / preset.height : 0);
    }

    function rotate() {
        const typed = usable && (typedWidth !== viewport.width || typedHeight !== viewport.height);
        const source = typed ? { _tag: "freeform", width: typedWidth, height: typedHeight } : viewport;
        const turned = Object.assign({}, source, { width: source.height, height: source.width });
        apply(turned, ratio > 0 ? 1 / ratio : 0);
    }

    function refill() {
        widthField.text = draft ? draft.width : String(viewport.width ?? "");
        heightField.text = draft ? draft.height : String(viewport.height ?? "");
    }

    // Leaving both fields applies what was typed.
    function fieldsLeft() {
        if (!widthField.activeFocus && !heightField.activeFocus)
            applyDraft();
    }

    onBusyChanged: answered()
    onViewportChanged: refill()
    onDraftChanged: refill()
    Component.onCompleted: refill()

    Row {
        anchors.left: parent.left
        anchors.leftMargin: Theme.space.sm
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2

        ShellButton {
            id: presetButton

            objectName: "browserToolbarPreset"
            subtle: true
            enabled: !toolbar.busy
            text: toolbar.viewport._tag === "preset" ? (BrowserJs.preset(toolbar.viewport.presetId)?.label ?? qsTr("Responsive")) : qsTr("Responsive")
            iconName: "chevron-down"
            Accessible.name: qsTr("Device preset")
            onClicked: presetMenu.popup(presetButton, 0, presetButton.height)
        }

        ShellTextField {
            id: widthField

            objectName: "browserToolbarWidth"
            width: 60
            implicitHeight: 24
            horizontalAlignment: TextInput.AlignHCenter
            enabled: !toolbar.busy
            selectByMouse: true
            inputMethodHints: Qt.ImhDigitsOnly
            Accessible.name: qsTr("Viewport width")
            onTextEdited: toolbar.edit("width", text)
            onAccepted: toolbar.applyDraft()
            onActiveFocusChanged: if (!activeFocus)
                Qt.callLater(toolbar.fieldsLeft)
            Keys.onEscapePressed: toolbar.draft = null
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "×"
            color: Theme.palette.color("textMuted", "#8b8b93")
            font.pixelSize: Theme.type.caption.size
        }

        ShellTextField {
            id: heightField

            objectName: "browserToolbarHeight"
            width: 60
            implicitHeight: 24
            horizontalAlignment: TextInput.AlignHCenter
            enabled: !toolbar.busy
            selectByMouse: true
            inputMethodHints: Qt.ImhDigitsOnly
            Accessible.name: qsTr("Viewport height")
            onTextEdited: toolbar.edit("height", text)
            onAccepted: toolbar.applyDraft()
            onActiveFocusChanged: if (!activeFocus)
                Qt.callLater(toolbar.fieldsLeft)
            Keys.onEscapePressed: toolbar.draft = null
        }

        ShellButton {
            objectName: "browserToolbarAspect"
            subtle: true
            checked: toolbar.ratio > 0
            enabled: !toolbar.busy && toolbar.usable
            iconName: toolbar.ratio > 0 ? "lock" : "lock-open"
            Accessible.name: toolbar.ratio > 0 ? qsTr("Unlock aspect ratio") : qsTr("Lock aspect ratio")
            toolTip: Accessible.name
            onClicked: toolbar.ratio = toolbar.ratio > 0 ? 0 : toolbar.typedWidth / toolbar.typedHeight
        }

        ShellButton {
            objectName: "browserToolbarRotate"
            subtle: true
            enabled: !toolbar.busy
            iconName: "rotate-cw"
            Accessible.name: qsTr("Rotate viewport")
            toolTip: Accessible.name
            onClicked: toolbar.rotate()
        }
    }

    ShellButton {
        objectName: "browserToolbarClose"
        anchors.right: parent.right
        anchors.rightMargin: Theme.space.sm
        anchors.verticalCenter: parent.verticalCenter
        subtle: true
        enabled: !toolbar.busy
        iconName: "x"
        Accessible.name: qsTr("Close device toolbar")
        toolTip: Accessible.name
        onClicked: toolbar.apply({ _tag: "fill" }, 0)
    }

    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: Theme.palette.color("border", "#27272a")
    }

    ShellMenu {
        id: presetMenu

        ShellMenuItem {
            objectName: "browserToolbarPreset-responsive"
            text: qsTr("Responsive")
            current: toolbar.viewport._tag === "freeform"
            onTriggered: toolbar.pick("responsive")
        }

        ShellMenuSeparator {}

        Repeater {
            model: BrowserJs.presets

            delegate: ShellMenuItem {
                required property var modelData

                objectName: "browserToolbarPreset-" + modelData.id
                text: modelData.label
                detail: modelData.width + " × " + modelData.height
                current: toolbar.viewport.presetId === modelData.id
                onTriggered: toolbar.pick(modelData.id)
            }
        }
    }
}
