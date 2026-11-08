pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/modelPicker.js" as Picker

// The composer's model picker:
// the trigger shows the chosen model with its provider's icon, and the popup
// has the provider rail (ModelPickerSidebar) beside a searchable model list
// (ModelPickerContent, ModelListRow). The catalogue is Shell.state.modelPicker;
// choosing a model or starring it is dispatched to the shell.
AbstractButton {
    id: control

    // The composer's current choice.
    property var selectedInstanceId: null
    property var selectedModel: null

    // Set to choose for something other than the composer: only these instance
    // ids are offered, and a choice is only said (chosen).
    property var onlyInstances: null
    readonly property var catalogue: Shell.state.modelPicker ?? null
    // Whether models can be starred: not where the picker offers what is not a
    // chat model, such as a Space's image models.
    readonly property bool favorites: catalogue?.favorites ?? true
    readonly property var instances: {
        const all = catalogue ? catalogue.instances : [];
        return onlyInstances === null ? all : all.filter(instance => onlyInstances.includes(instance.instanceId));
    }
    readonly property var activeInstance: Picker.findInstance(instances, selectedInstanceId)
    // The instance the rail is looking at, when it cannot be used but the MC
    // can set it up: its panel offers the setup instead of models.
    readonly property var setupInstance: {
        const looked = Picker.findInstance(instances, view);
        return looked && !looked.isAvailable && looked.canSetUp === true ? looked : null;
    }
    readonly property var activeModel: Picker.findModel(activeInstance, selectedModel)
    // The models a new thread's prompt goes to, once more than one is chosen.
    readonly property var multiple: onlyInstances === null ? (catalogue?.multiple ?? null) : null
    readonly property string triggerTitle: multiple !== null ? qsTr("%1 models").arg(multiple.length) : activeModel ? Picker.displayName(activeModel, true) : (catalogue?.noProviderLabel ? catalogue.noProviderLabel : (selectedModel ? selectedModel : qsTr("Choose model")))

    function inMultiple(instanceId, model) {
        return multiple !== null && multiple.some(entry => entry.instanceId === instanceId && entry.model === model);
    }
    readonly property string triggerLabel: activeModel && activeModel.isUnavailable ? triggerTitle + qsTr(" (Unavailable)") : triggerTitle
    readonly property bool mac: Qt.platform.os === "osx" || Qt.platform.os === "macos"
    readonly property alias popup: popup

    signal chosen(string instanceId, string model)

    // The popup's state: the rail entry ("favorites" or an instance id), the
    // search, and the keyboard highlight in the list.
    property string view: Picker.FAVORITES
    property string query: ""
    property var expandedLegacy: ({})
    property int highlightedIndex: -1
    readonly property bool searching: query.trim().length > 0
    readonly property bool showRail: !searching && instances.length > 0
    readonly property var rows: popup.visible ? Picker.rows(instances, view, query, expandedLegacy) : []

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color overlay: Theme.palette.color("surfaceOverlay", "#18181b")
    readonly property color mutedSurface: Theme.palette.color("muted", "#27272a")
    readonly property color highlight: Theme.palette.color("accentSurface", "#27272a")
    // Scales a theme colour's own alpha, like Tailwind's `bg-muted/40`: dark
    // themes publish translucent roles, and Qt.alpha would replace their alpha.
    function fade(value, factor) {
        const base = Qt.color(value);
        return Qt.alpha(base, base.a * factor);
    }

    readonly property color divider: control.fade(Theme.palette.color("border", "#27272a"), 0.7)
    readonly property string fontFamily: Theme.fontUi.length > 0 ? Theme.fontUi : Application.font.family

    function open() {
        if (enabled && !popup.visible)
            popup.open();
    }

    function close() {
        popup.close();
    }

    function selectView(next) {
        view = next;
        highlightedIndex = firstSelectableRow(0, 1);
        search.forceActiveFocus();
    }

    function selectable(row) {
        return row && (row.kind === "legacy" || row.model.disabledReason === null);
    }

    function firstSelectableRow(from, step) {
        for (let index = from; index >= 0 && index < rows.length; index += step) {
            if (selectable(rows[index]))
                return index;
        }
        return -1;
    }

    function moveHighlight(step) {
        const next = firstSelectableRow(highlightedIndex < 0 ? (step > 0 ? 0 : rows.length - 1) : highlightedIndex + step, step);
        if (next >= 0) {
            highlightedIndex = next;
            list.positionViewAtIndex(next, ListView.Contain);
        }
    }

    // A model that says why it cannot be used is never sent.
    function choose(instanceId, model) {
        const entry = Picker.findModel(Picker.findInstance(instances, instanceId), model);
        if (!entry || entry.disabledReason !== null)
            return;
        if (onlyInstances !== null) {
            chosen(instanceId, model);
            popup.close();
            return;
        }
        Shell.dispatch("composer.model.select", {
            instanceId: instanceId,
            model: model
        });
        popup.close();
    }

    function activate(index) {
        const row = rows[index];
        if (!row)
            return;
        if (row.kind === "legacy") {
            toggleLegacy(row.instanceId);
            return;
        }
        choose(row.instance.instanceId, row.model.slug);
    }

    function toggleLegacy(instanceId) {
        const next = Object.assign({}, expandedLegacy);
        next[instanceId] = !next[instanceId];
        expandedLegacy = next;
    }

    function toggleFavorite(instanceId, model) {
        Shell.dispatch("composer.model.favorite.toggle", {
            instanceId: instanceId,
            model: model
        });
    }

    // The chords the catalogue carries for the open picker: previous/next
    // provider and the numbered jumps.
    function chordFor(event) {
        if (!catalogue)
            return null;
        if (Picker.matches(catalogue.previousProvider, event, mac))
            return {
                provider: -1
            };
        if (Picker.matches(catalogue.nextProvider, event, mac))
            return {
                provider: 1
            };
        for (let index = 0; index < catalogue.jump.length; index += 1) {
            if (Picker.matches(catalogue.jump[index], event, mac))
                return {
                    jump: index
                };
        }
        return null;
    }

    function handleChord(event) {
        const chord = chordFor(event);
        if (chord === null)
            return false;
        if (chord.provider !== undefined) {
            query = "";
            selectView(Picker.adjacentView(instances, view, chord.provider));
        } else {
            const row = rows.find(candidate => candidate.kind === "model" && candidate.jumpIndex === chord.jump);
            if (row)
                choose(row.instance.instanceId, row.model.slug);
        }
        return true;
    }

    function jumpLabel(row) {
        if (!catalogue || row.jumpIndex < 0)
            return "";
        const key = catalogue.jump[row.jumpIndex];
        return key ? key.label : "";
    }

    function focusRail() {
        const target = rail.buttonFor(view) ?? rail.firstEnabled();
        if (target)
            target.forceActiveFocus();
        return target !== null;
    }

    implicitHeight: Math.max(Theme.control.md, topPadding + contentItem.implicitHeight + bottomPadding)
    implicitWidth: leftPadding + contentItem.implicitWidth + rightPadding
    leftPadding: Theme.space.sm
    rightPadding: Theme.space.sm + Theme.icon.sm + Theme.space.xs
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    opacity: enabled ? 1 : 0.64
    font.family: fontFamily
    font.pixelSize: Theme.type.body.size
    font.weight: Theme.type.body.weight
    Accessible.role: Accessible.ComboBox
    Accessible.name: triggerLabel

    ToolTip.visible: hovered && !popup.visible
    ToolTip.delay: 500
    ToolTip.text: catalogue && catalogue.shortcut ? triggerLabel + " · " + catalogue.shortcut : triggerLabel

    onClicked: popup.visible ? popup.close() : popup.open()

    background: Rectangle {
        id: triggerBackground

        readonly property color labelColor: control.hovered || control.pressed || popup.visible ? control.foreground : Theme.palette.color("inkSecondary", "#b8bdc7")
        readonly property color fill: Theme.palette.color("surfaceRaised", "#1c1f24")

        // The composer's ghost chip: no fill at rest, the raised surface under the pointer.
        radius: Theme.radiusMd
        color: control.pressed || control.hovered || popup.visible ? fill : "transparent"
        // Borderless like the composer's other pickers, so the keyboard's
        // arrival is the ring; pointer focus stays quiet.
        border.color: control.visualFocus ? Theme.palette.color("focus", "#3b82f6") : "transparent"
        border.width: control.visualFocus ? 1 : 0

        ShellChevron {
            x: parent.width - width - Theme.space.sm
            y: (parent.height - height) / 2
            direction: "down"
            size: Theme.icon.sm
            color: Theme.palette.color("iconMuted", "#8b8b93")
        }
    }

    contentItem: RowLayout {
        spacing: Theme.space.sm

        ProviderIcon {
            objectName: "modelPickerIcon"
            visible: control.activeInstance !== null
            size: Theme.icon.md
            driverKind: control.activeInstance ? control.activeInstance.driverKind : ""
            initials: control.activeInstance ? control.activeInstance.initials : ""
            accentColor: control.activeInstance ? control.activeInstance.accentColor : null
            iconUrl: control.activeInstance ? control.activeInstance.iconUrl : null
            showBadge: control.activeInstance ? control.activeInstance.showBadge : false
            indicatorBackground: Theme.palette.color("input", "#27272a")
        }

        Text {
            objectName: "modelPickerTitle"
            Layout.fillWidth: true
            text: control.triggerTitle
            font: control.font
            color: triggerBackground.labelColor
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
        }

        Badge {
            visible: control.activeModel !== null && control.activeModel.isUnavailable
            text: qsTr("Unavailable")
        }
    }

    Popup {
        id: popup

        // Above the trigger, and
        // flipped below it when the window has no room above.
        property bool below: false

        scale: Shell.state.layout?.zoom ?? 1
        transformOrigin: Item.TopLeft
        x: 0
        y: below ? control.height + 4 : -height - 4
        // ljos-allow(layout-fixed-size): the rail and the list scroll inside it, and a size that followed the search's results would move the rows under the pointer as one types
        width: 360
        // The search row, then six whole rows (46 tall, 2 apart) between the
        // list's margins: the list never stops on a sliced row.
        height: 40 + 2 * Theme.space.sm + 6 * 46 + 5 * 2
        padding: 0
        margins: 8
        focus: true
        // Escape is handled by the search field and the rail. A popup that
        // closes on Escape blocks every window shortcut, and the model
        // picker keybinding must still reach the shell to close it again.
        // Pressing the trigger closes it through onClicked.
        closePolicy: Popup.CloseOnPressOutsideParent
        onAboutToShow: {
            below = control.mapToItem(null, 0, 0).y < (height + 4) * scale + margins;
            control.query = "";
            control.expandedLegacy = control.activeModel && control.activeModel.isLegacy ? {
                [control.selectedInstanceId]: true
            } : {};
            control.view = Picker.initialView(control.instances, control.selectedInstanceId, control.catalogue?.locked === true);
        }
        // The keymap's modelPickerOpen.
        onVisibleChanged: Keybindings.modelPickerOpen = visible
        onOpened: {
            const selected = control.rows.findIndex(row => row.kind === "model" && row.instance.instanceId === control.selectedInstanceId && row.model.slug === control.selectedModel);
            control.highlightedIndex = selected >= 0 ? selected : control.firstSelectableRow(0, 1);
            search.forceActiveFocus();
        }

        enter: Transition {
            NumberAnimation {
                property: "opacity"
                from: 0
                to: 1
                duration: 120
                easing.type: Easing.OutCubic
            }
        }

        // Closing is instant: a fade could swallow the next open.
        exit: null

        background: ShellPopoverSurface {}

        contentItem: Item {
            clip: true
            // A Popup is no Item, so its name is on its content.
            Accessible.role: Accessible.Pane
            Accessible.name: qsTr("Models")

            // The provider rail: favourites, then one button per enabled
            // instance. Hidden while searching, since search spans them all.
            Rectangle {
                id: rail

                function buttonFor(id) {
                    for (let index = 0; index < railButtons.children.length; index += 1) {
                        const child = railButtons.children[index];
                        if (child.railId === id && child.available)
                            return child;
                    }
                    return null;
                }

                function firstEnabled() {
                    for (let index = 0; index < railButtons.children.length; index += 1) {
                        const child = railButtons.children[index];
                        if (child.railId !== undefined && child.available)
                            return child;
                    }
                    return null;
                }

                function step(from, direction) {
                    const buttons = [];
                    for (let index = 0; index < railButtons.children.length; index += 1) {
                        const child = railButtons.children[index];
                        if (child.railId !== undefined && child.available)
                            buttons.push(child);
                    }
                    const at = buttons.indexOf(from);
                    const next = buttons[(at + direction + buttons.length) % buttons.length];
                    if (next)
                        next.forceActiveFocus();
                }

                objectName: "modelPickerRail"
                visible: control.showRail
                width: 44
                height: parent.height
                color: control.fade(control.mutedSurface, 0.3)
                radius: Theme.radiusLg

                Flickable {
                    anchors.fill: parent
                    contentHeight: railButtons.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true

                    Column {
                        id: railButtons

                        width: rail.width
                        padding: 4
                        spacing: 4

                        RailButton {
                            visible: control.favorites
                            available: control.favorites
                            railId: Picker.FAVORITES
                            tooltip: qsTr("Favorites")
                            objectName: "modelPickerProvider:favorites"

                            ShellIcon {
                                anchors.centerIn: parent
                                name: "star"
                                filled: true
                                size: 20
                                color: control.foreground
                            }
                        }

                        Rectangle {
                            visible: control.favorites
                            width: parent.width - 8
                            height: 1
                            color: control.divider
                        }

                        Repeater {
                            model: control.instances

                            delegate: RailButton {
                                id: providerButton

                                required property var modelData

                                objectName: "modelPickerProvider:" + modelData.instanceId
                                railId: modelData.instanceId
                                available: modelData.isAvailable
                                canSetUp: modelData.canSetUp === true
                                tooltip: modelData.unavailableReason ?? modelData.displayName

                                ProviderIcon {
                                    anchors.centerIn: parent
                                    size: 20
                                    driverKind: providerButton.modelData.driverKind
                                    initials: providerButton.modelData.initials
                                    accentColor: providerButton.modelData.accentColor
                                    iconUrl: providerButton.modelData.iconUrl
                                    showBadge: providerButton.modelData.showBadge
                                    indicatorBackground: providerButton.selected ? Theme.palette.color("canvas", "#0f0f12") : control.overlay
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                id: main

                anchors.left: rail.visible ? rail.right : parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                color: control.fade(control.mutedSurface, 0.4)
                radius: rail.visible ? 0 : Theme.radiusLg

                Rectangle {
                    visible: rail.visible
                    width: 1
                    height: parent.height
                    color: control.divider
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.leftMargin: rail.visible ? 1 : 0
                    spacing: 0

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 40

                        ShellIcon {
                            x: 12
                            y: 14
                            name: "search"
                            size: 16
                            color: Theme.palette.color("inkTertiary", "#8b919e")
                        }

                        TextField {
                            id: search

                            objectName: "modelPickerSearch"
                            x: 12
                            y: 8
                            width: parent.width - 24
                            height: 26
                            leftPadding: 26
                            rightPadding: 0
                            topPadding: 0
                            bottomPadding: 0
                            placeholderText: qsTr("Search models...")
                            Accessible.name: qsTr("Search models")
                            placeholderTextColor: Theme.palette.color("placeholder", "#71717a")
                            color: control.foreground
                            font.family: control.fontFamily
                            font.pixelSize: Theme.type.body.size
                            selectionColor: Theme.palette.color("accent", "#2563eb")
                            selectedTextColor: Theme.palette.color("accentForeground", "#ffffff")
                            text: control.query
                            background: null
                            onTextEdited: {
                                control.query = text;
                                control.highlightedIndex = control.firstSelectableRow(0, 1);
                            }

                            Keys.onShortcutOverride: event => {
                                event.accepted = control.chordFor(event) !== null;
                            }
                            Keys.onPressed: event => {
                                if (control.handleChord(event)) {
                                    event.accepted = true;
                                    return;
                                }
                                const plain = !(event.modifiers & (Qt.AltModifier | Qt.ControlModifier | Qt.MetaModifier));
                                if (control.showRail && plain && ((event.key === Qt.Key_Left && !(event.modifiers & Qt.ShiftModifier) && text.length === 0) || event.key === Qt.Key_Backtab)) {
                                    event.accepted = control.focusRail();
                                    return;
                                }
                                switch (event.key) {
                                case Qt.Key_Escape:
                                    popup.close();
                                    control.forceActiveFocus();
                                    event.accepted = true;
                                    return;
                                case Qt.Key_Down:
                                    control.moveHighlight(1);
                                    event.accepted = true;
                                    return;
                                case Qt.Key_Up:
                                    control.moveHighlight(-1);
                                    event.accepted = true;
                                    return;
                                case Qt.Key_Return:
                                case Qt.Key_Enter:
                                    control.activate(control.highlightedIndex);
                                    event.accepted = true;
                                    return;
                                }
                            }
                        }

                        Rectangle {
                            x: 12
                            width: parent.width - 24
                            y: parent.height - 1
                            height: 1
                            color: search.activeFocus ? Theme.palette.color("focus", "#3b82f6") : control.divider
                        }
                    }

                    ListView {
                        id: list

                        objectName: "modelPickerList"
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        leftMargin: 8
                        rightMargin: 4
                        // Outside the list, so its edges fall between rows.
                        Layout.topMargin: Theme.space.sm
                        Layout.bottomMargin: Theme.space.sm
                        spacing: 2
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        model: control.rows

                        delegate: RowSlot {
                            width: ListView.view.width - ListView.view.leftMargin - ListView.view.rightMargin
                            sourceComponent: modelData.kind === "legacy" ? legacyRow : modelRow
                        }

                        ShellScrollEdge {
                            target: list
                        }

                        Text {
                            objectName: "modelPickerEmpty"
                            anchors.centerIn: parent
                            visible: list.count === 0 && control.setupInstance === null
                            text: qsTr("No models found")
                            color: control.muted
                            font.family: control.fontFamily
                            font.pixelSize: Theme.type.body.size
                        }

                        Column {
                            anchors.centerIn: parent
                            width: parent.width - Theme.space.lg * 2
                            visible: control.setupInstance !== null
                            spacing: Theme.space.sm

                            Text {
                                objectName: "modelPickerSetupReason"
                                width: parent.width
                                horizontalAlignment: Text.AlignHCenter
                                wrapMode: Text.WordWrap
                                text: control.setupInstance ? (control.setupInstance.unavailableReason ?? "") : ""
                                color: control.muted
                                font.family: control.fontFamily
                                font.pixelSize: Theme.type.body.size
                            }

                            ShellButton {
                                objectName: "modelPickerSetup"
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: qsTr("Open provider setup")
                                Accessible.name: qsTr("Open provider setup")
                                onClicked: {
                                    popup.close();
                                    Shell.dispatch("settings.navigate", {
                                        to: "/settings/providers"
                                    });
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // A row of the list: it loads `modelRow` or `legacyRow`, which read their
    // entry and index from it.
    component RowSlot: Loader {
        required property var modelData
        required property int index
    }

    Component {
        id: modelRow

        Rectangle {
            id: row

            readonly property var entry: (parent as RowSlot)?.modelData ?? null
            readonly property int rowIndex: (parent as RowSlot)?.index ?? -1
            readonly property var model: entry ? entry.model : null
            readonly property var instance: entry ? entry.instance : null
            readonly property string disabledReason: model && model.disabledReason !== null ? model.disabledReason : ""
            readonly property bool isSelected: {
                if (instance === null || model === null)
                    return false;
                if (control.multiple !== null)
                    return control.multiple.some(picked => picked.instanceId === instance.instanceId && picked.model === model.slug);
                return instance.instanceId === control.selectedInstanceId && model.slug === control.selectedModel;
            }
            readonly property bool highlighted: control.highlightedIndex === rowIndex
            readonly property string jumpText: entry ? control.jumpLabel(entry) : ""

            objectName: instance && model ? "modelPickerRow:" + instance.instanceId + ":" + model.slug : ""
            implicitHeight: 46
            radius: Theme.radiusXs
            opacity: disabledReason.length > 0 ? 0.64 : 1
            color: highlighted || (rowHover.hovered && disabledReason.length === 0) ? control.highlight : isSelected ? control.fade(control.foreground, 0.08) : "transparent"
            Accessible.role: Accessible.ListItem
            Accessible.name: model ? Picker.displayName(model, true) : ""
            // The search field's arrows and Enter reach it from the keyboard.
            Accessible.onPressAction: if (row.model)
                control.choose(row.instance.instanceId, row.model.slug)

            HoverHandler {
                id: rowHover
            }

            TapHandler {
                onTapped: {
                    if (row.disabledReason.length > 0 || !row.model)
                        return;
                    // Shift-click is the row's "send to this model too".
                    if ((point.modifiers & Qt.ShiftModifier) && control.catalogue?.supportsMultiple === true) {
                        Shell.dispatch("composer.model.multiple.toggle", {
                            instanceId: row.instance.instanceId,
                            model: row.model.slug
                        });
                        return;
                    }
                    control.choose(row.instance.instanceId, row.model.slug);
                }
            }

            ToolTip.visible: rowHover.hovered && disabledReason.length > 0
            ToolTip.delay: 0
            ToolTip.text: disabledReason

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 4
                spacing: Theme.space.sm

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Text {
                            Layout.fillWidth: implicitWidth > width
                            Layout.maximumWidth: implicitWidth
                            Layout.fillHeight: false
                            text: row.model ? Picker.displayName(row.model, true) : ""
                            color: control.foreground
                            font.family: control.fontFamily
                            font.pixelSize: Theme.type.meta.size
                            font.weight: Font.Medium
                            elide: Text.ElideRight
                        }

                        Rectangle {
                            visible: row.model !== null && row.model.isNew
                            implicitWidth: newText.implicitWidth + 6
                            implicitHeight: newText.implicitHeight + 2
                            radius: Theme.radiusXs
                            color: control.fade(Theme.palette.color("update", "#3b82f6"), 0.15)
                            border.color: control.fade(Theme.palette.color("update", "#3b82f6"), 0.35)

                            Text {
                                id: newText

                                anchors.centerIn: parent
                                text: qsTr("NEW")
                                color: Theme.palette.color("updateForeground", "#60a5fa")
                                font.family: control.fontFamily
                                font.pixelSize: Theme.type.caption.size
                                font.weight: Font.DemiBold
                                font.letterSpacing: 0.4
                            }
                        }

                        Badge {
                            visible: row.model !== null && row.model.isUnavailable
                            text: qsTr("Unavailable")
                        }

                        Item {
                            Layout.fillWidth: true
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Theme.space.sm

                        ProviderIcon {
                            size: 12
                            driverKind: row.instance ? row.instance.driverKind : ""
                            initials: row.instance ? row.instance.initials : ""
                            iconUrl: row.instance ? row.instance.iconUrl : null
                        }

                        Text {
                            Layout.fillWidth: true
                            text: row.model && row.instance ? Picker.providerLabel(row.model, row.instance) : ""
                            color: control.muted
                            font.family: control.fontFamily
                            font.pixelSize: Theme.type.meta.size
                            elide: Text.ElideRight
                        }
                    }
                }

                // The numbered jump for the first nine models.
                Rectangle {
                    visible: row.jumpText.length > 0
                    implicitWidth: Math.max(20, kbdText.implicitWidth + 8)
                    implicitHeight: 20
                    radius: Theme.radiusXs
                    color: control.mutedSurface

                    Text {
                        id: kbdText

                        anchors.centerIn: parent
                        text: row.jumpText
                        color: control.muted
                        font.family: control.fontFamily
                        font.pixelSize: Theme.type.meta.size
                        font.weight: Font.Medium
                    }
                }

                // Also send a new thread's prompt to this model.
                AbstractButton {
                    id: also

                    readonly property bool chosen: row.instance !== null && row.model !== null && control.inMultiple(row.instance.instanceId, row.model.slug)

                    objectName: row.instance && row.model ? "modelPickerMultiple:" + row.instance.instanceId + ":" + row.model.slug : ""
                    visible: control.catalogue?.supportsMultiple === true
                    implicitWidth: 24
                    implicitHeight: 24
                    enabled: row.disabledReason.length === 0
                    hoverEnabled: true
                    focusPolicy: Qt.NoFocus
                    Accessible.name: chosen ? qsTr("Stop sending to this model too") : qsTr("Send to this model too")
                    ToolTip.visible: hovered
                    ToolTip.delay: 0
                    ToolTip.text: chosen ? qsTr("Stop sending to this model too") : qsTr("Send to this model too: one thread per model, each in its own worktree")
                    onClicked: Shell.dispatch("composer.model.multiple.toggle", {
                        instanceId: row.instance.instanceId,
                        model: row.model.slug
                    })

                    background: Rectangle {
                        radius: Theme.radiusXs
                        color: also.hovered ? control.highlight : "transparent"
                    }

                    contentItem: Item {
                        ShellIcon {
                            anchors.centerIn: parent
                            name: also.chosen ? "check" : "plus"
                            size: 12
                            color: also.chosen ? Theme.palette.color("accent", "#2563eb") : also.hovered ? Theme.palette.color("inkSecondary", "#b8bdc7") : Theme.palette.color("inkTertiary", "#8b919e")
                        }
                    }
                }

                AbstractButton {
                    id: star

                    readonly property bool favorite: row.model !== null && row.model.isFavorite

                    objectName: row.instance && row.model ? "modelPickerFavorite:" + row.instance.instanceId + ":" + row.model.slug : ""
                    visible: control.favorites
                    implicitWidth: 24
                    implicitHeight: 24
                    enabled: row.disabledReason.length === 0
                    hoverEnabled: true
                    focusPolicy: Qt.NoFocus
                    Accessible.name: favorite ? qsTr("Remove from favorites") : qsTr("Add to favorites")
                    ToolTip.visible: hovered
                    ToolTip.delay: 0
                    ToolTip.text: favorite ? qsTr("Remove from favorites") : qsTr("Add to favorites")
                    onClicked: control.toggleFavorite(row.instance.instanceId, row.model.slug)

                    background: Rectangle {
                        radius: Theme.radiusXs
                        color: star.hovered ? control.highlight : "transparent"
                    }

                    contentItem: Item {
                        ShellIcon {
                            anchors.centerIn: parent
                            name: "star"
                            filled: star.favorite
                            size: 12
                            color: star.favorite ? "#eab308" : star.hovered ? Theme.palette.color("inkSecondary", "#b8bdc7") : Theme.palette.color("inkTertiary", "#8b919e")
                        }
                    }
                }
            }
        }
    }

    Component {
        id: legacyRow

        Rectangle {
            id: legacy

            readonly property var entry: (parent as RowSlot)?.modelData ?? null
            readonly property int rowIndex: (parent as RowSlot)?.index ?? -1

            objectName: entry ? "modelPickerLegacy:" + entry.instanceId : ""
            implicitHeight: 46
            radius: Theme.radiusXs
            color: control.highlightedIndex === rowIndex || legacyHover.hovered ? control.highlight : "transparent"
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Legacy models")
            Accessible.onPressAction: if (legacy.entry)
                control.toggleLegacy(legacy.entry.instanceId)

            HoverHandler {
                id: legacyHover
            }

            TapHandler {
                onTapped: control.toggleLegacy(legacy.entry.instanceId)
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 8
                anchors.rightMargin: 8
                spacing: Theme.space.sm

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    Text {
                        text: qsTr("Legacy models")
                        color: control.foreground
                        font.family: control.fontFamily
                        font.pixelSize: Theme.type.meta.size
                        font.weight: Font.Medium
                    }

                    Text {
                        text: legacy.entry ? qsTr("%1 models").arg(legacy.entry.count) : ""
                        color: control.muted
                        font.family: control.fontFamily
                        font.pixelSize: Theme.type.meta.size
                    }
                }

                ShellChevron {
                    direction: "right"
                    size: Theme.icon.md
                    color: control.muted
                    rotation: legacy.entry && legacy.entry.expanded ? 90 : 0

                    Behavior on rotation {
                        NumberAnimation {
                            duration: 150
                            easing.type: Easing.OutCubic
                        }
                    }
                }
            }
        }
    }

    // A rail entry: square, greyed and unclickable when the instance cannot
    // be chosen, with a tooltip (why it is unavailable) either way.
    // It stays enabled so the tooltip still shows on hover.
    component RailButton: Item {
        id: railButton

        property string railId: ""
        property string tooltip: ""
        property bool available: true
        // An unavailable provider the MC can set up can still be opened:
        // its panel says why and offers the setup.
        property bool canSetUp: false
        readonly property bool selectable: available || canSetUp
        readonly property bool selected: control.view === railId
        default property alias content: face.data

        width: 36
        height: 36
        // A tab of the rail: reached from the search with Left or Shift+Tab,
        // and moved through with the arrows.
        Accessible.role: Accessible.PageTab
        Accessible.name: tooltip
        Accessible.selected: selected
        activeFocusOnTab: false

        HoverHandler {
            id: railHover
        }

        ToolTip.visible: railHover.hovered || activeFocus
        ToolTip.delay: 0
        ToolTip.text: tooltip

        Rectangle {
            id: face

            anchors.fill: parent
            radius: Theme.radiusSm
            opacity: railButton.available ? 1 : 0.5
            // The chosen provider is filled; hover and focus tint the rest.
            color: railButton.selected ? Theme.palette.color("surfaceRaised", "#1c1f24") : railButton.available && (railHover.hovered || railButton.activeFocus) ? Qt.tint(control.overlay, control.fade(control.foreground, 0.1)) : "transparent"
        }

        TapHandler {
            enabled: railButton.selectable
            onTapped: control.selectView(railButton.railId)
        }

        Keys.onShortcutOverride: event => {
            event.accepted = control.chordFor(event) !== null;
        }
        Keys.onPressed: event => {
            if (control.handleChord(event)) {
                event.accepted = true;
                return;
            }
            if (event.modifiers & (Qt.AltModifier | Qt.ControlModifier | Qt.MetaModifier | Qt.ShiftModifier))
                return;
            switch (event.key) {
            case Qt.Key_Up:
                rail.step(railButton, -1);
                break;
            case Qt.Key_Down:
                rail.step(railButton, 1);
                break;
            case Qt.Key_Right:
                search.forceActiveFocus();
                break;
            case Qt.Key_Return:
            case Qt.Key_Enter:
            case Qt.Key_Space:
                if (railButton.selectable)
                    control.selectView(railButton.railId);
                break;
            case Qt.Key_Escape:
                popup.close();
                control.forceActiveFocus();
                break;
            default:
                return;
            }
            event.accepted = true;
        }
    }

    // The outline "Unavailable" badge.
    component Badge: Rectangle {
        property alias text: badgeLabel.text

        implicitWidth: badgeLabel.implicitWidth + 8
        implicitHeight: badgeLabel.implicitHeight + 2
        radius: Theme.radiusXs
        color: "transparent"
        border.color: Theme.palette.color("border", "#27272a")

        Text {
            id: badgeLabel

            anchors.centerIn: parent
            color: control.muted
            font.family: control.fontFamily
            font.pixelSize: Theme.type.caption.size
            font.weight: Font.Medium
        }
    }
}
