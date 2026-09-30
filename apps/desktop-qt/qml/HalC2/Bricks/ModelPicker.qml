import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/modelPicker.js" as Picker

// The composer's model picker, copied from the web's ProviderModelPicker:
// the trigger shows the chosen model with its provider's icon, and the popup
// has the provider rail (ModelPickerSidebar) beside a searchable model list
// (ModelPickerContent, ModelListRow). The catalogue is Shell.state.modelPicker;
// choosing a model or starring it is dispatched to the shell.
AbstractButton {
    id: control

    // The composer's current choice.
    property var selectedInstanceId: null
    property var selectedModel: null

    readonly property var catalogue: Shell.state.modelPicker ?? null
    readonly property var instances: catalogue ? catalogue.instances : []
    readonly property bool locked: catalogue ? catalogue.locked : false
    readonly property var activeInstance: Picker.findInstance(instances, selectedInstanceId)
    readonly property var activeModel: Picker.findModel(activeInstance, selectedModel)
    readonly property string triggerTitle: activeModel ? Picker.displayName(activeModel, true) : (selectedModel ? selectedModel : qsTr("Choose model"))
    readonly property string triggerLabel: activeModel && activeModel.isUnavailable ? triggerTitle + qsTr(" (Unavailable)") : triggerTitle
    readonly property bool mac: Qt.platform.os === "osx" || Qt.platform.os === "macos"
    readonly property alias popup: popup

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
    readonly property string fontFamily: Theme.fontUi.length > 0 ? Theme.fontUi : Qt.application.font.family

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

    // The same guard as the web's handleModelSelect: a model that says why it
    // cannot be used is never sent.
    function choose(instanceId, model) {
        const entry = Picker.findModel(Picker.findInstance(instances, instanceId), model);
        if (!entry || entry.disabledReason !== null)
            return;
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

    implicitHeight: 28
    implicitWidth: leftPadding + contentItem.implicitWidth + rightPadding
    leftPadding: 10
    rightPadding: 10 + 14 + 4
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    opacity: enabled ? 1 : 0.64
    font.family: fontFamily
    font.pixelSize: 14
    font.weight: Font.Medium
    Accessible.role: Accessible.ComboBox
    Accessible.name: triggerLabel

    ToolTip.visible: hovered && !popup.visible
    ToolTip.delay: 500
    ToolTip.text: catalogue && catalogue.shortcut ? triggerLabel + " · " + catalogue.shortcut : triggerLabel

    onClicked: popup.visible ? popup.close() : popup.open()

    background: Rectangle {
        readonly property color labelColor: control.hovered || control.pressed || popup.visible ? control.foreground : Theme.palette.color("secondaryLabel", "#a1a1aa")

        radius: Math.min(Theme.radius, 8)
        color: control.pressed || control.hovered || popup.visible ? control.highlight : Qt.alpha(control.highlight, 0)

        Behavior on color {
            ColorAnimation {
                duration: 120
            }
        }

        ShellIcon {
            x: parent.width - width - 10
            y: (parent.height - height) / 2
            name: "chevron-down"
            size: 14
            strokeWidth: 2.25
            color: Theme.palette.color("iconMuted", "#8b8b93")
        }
    }

    contentItem: RowLayout {
        spacing: 6

        ProviderIcon {
            objectName: "modelPickerIcon"
            visible: control.activeInstance !== null
            size: 16
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
            color: control.background.labelColor
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

        // Above the trigger, as the composer's picker opens on the web, and
        // flipped below it when the window has no room above.
        property bool below: false

        scale: Shell.state.layout?.zoom ?? 1
        transformOrigin: Item.TopLeft
        x: 0
        y: below ? control.height + 4 : -height - 4
        width: 360
        height: 346
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
            control.view = Picker.initialView(control.instances, control.selectedInstanceId, control.locked);
        }
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

        exit: Transition {
            NumberAnimation {
                property: "opacity"
                from: 1
                to: 0
                duration: 90
            }
        }

        background: Rectangle {
            radius: Math.min(Theme.radius, 10)
            color: control.overlay
            border.color: control.fade(control.foreground, 0.1)
            border.width: 1
        }

        contentItem: Item {
            clip: true

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
                radius: Math.min(Theme.radius, 10)

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

                    // The web's selected-provider marker on the rail's edge.
                    Rectangle {
                        readonly property var target: control.showRail ? rail.buttonForAny(control.view) : null

                        visible: target !== null
                        x: railButtons.width - width
                        y: target ? target.y + (target.height - height) / 2 : 0
                        width: 3
                        height: 20
                        radius: 1.5
                        color: Theme.palette.color("accent", "#2563eb")

                        Behavior on y {
                            NumberAnimation {
                                duration: 200
                                easing.type: Easing.OutCubic
                            }
                        }
                    }
                }

                function buttonForAny(id) {
                    for (let index = 0; index < railButtons.children.length; index += 1) {
                        const child = railButtons.children[index];
                        if (child.railId === id)
                            return child;
                    }
                    return null;
                }
            }

            Rectangle {
                id: main

                anchors.left: rail.visible ? rail.right : parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                color: control.fade(control.mutedSurface, 0.4)
                radius: rail.visible ? 0 : Math.min(Theme.radius, 10)

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
                            color: control.fade(control.muted, 0.55)
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
                            placeholderTextColor: Theme.palette.color("placeholder", "#71717a")
                            color: control.foreground
                            font.family: control.fontFamily
                            font.pixelSize: 13
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
                        topMargin: 6
                        bottomMargin: 6
                        spacing: 2
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        model: control.rows

                        delegate: Loader {
                            required property var modelData
                            required property int index

                            width: ListView.view.width - ListView.view.leftMargin - ListView.view.rightMargin
                            sourceComponent: modelData.kind === "legacy" ? legacyRow : modelRow
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: list.count === 0
                            text: qsTr("No models found")
                            color: control.muted
                            font.family: control.fontFamily
                            font.pixelSize: 13
                        }
                    }
                }
            }
        }
    }

    Component {
        id: modelRow

        Rectangle {
            id: row

            readonly property var entry: parent ? parent.modelData : null
            readonly property int rowIndex: parent ? parent.index : -1
            readonly property var model: entry ? entry.model : null
            readonly property var instance: entry ? entry.instance : null
            readonly property string disabledReason: model && model.disabledReason !== null ? model.disabledReason : ""
            readonly property bool isSelected: instance !== null && model !== null && instance.instanceId === control.selectedInstanceId && model.slug === control.selectedModel
            readonly property bool highlighted: control.highlightedIndex === rowIndex
            readonly property string jumpText: entry ? control.jumpLabel(entry) : ""

            objectName: instance && model ? "modelPickerRow:" + instance.instanceId + ":" + model.slug : ""
            implicitHeight: 46
            radius: 4
            opacity: disabledReason.length > 0 ? 0.64 : 1
            color: highlighted || (rowHover.hovered && disabledReason.length === 0) ? control.highlight : isSelected ? control.fade(control.foreground, 0.08) : "transparent"
            Accessible.role: Accessible.ListItem
            Accessible.name: model ? Picker.displayName(model, !control.locked) : ""

            HoverHandler {
                id: rowHover
            }

            TapHandler {
                onTapped: {
                    if (row.disabledReason.length === 0 && row.model)
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
                spacing: 6

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
                            text: row.model ? Picker.displayName(row.model, !control.locked) : ""
                            color: control.foreground
                            font.family: control.fontFamily
                            font.pixelSize: 12
                            font.weight: Font.Medium
                            elide: Text.ElideRight
                        }

                        Rectangle {
                            visible: row.model !== null && row.model.isNew
                            implicitWidth: newText.implicitWidth + 6
                            implicitHeight: newText.implicitHeight + 2
                            radius: 3
                            color: control.fade(Theme.palette.color("update", "#3b82f6"), 0.15)
                            border.color: control.fade(Theme.palette.color("update", "#3b82f6"), 0.35)

                            Text {
                                id: newText

                                anchors.centerIn: parent
                                text: qsTr("NEW")
                                color: Theme.palette.color("updateForeground", "#60a5fa")
                                font.family: control.fontFamily
                                font.pixelSize: 10
                                font.bold: true
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
                        spacing: 6

                        ProviderIcon {
                            size: 12
                            driverKind: row.instance ? row.instance.driverKind : ""
                            initials: row.instance ? row.instance.initials : ""
                            iconUrl: row.instance ? row.instance.iconUrl : null
                        }

                        Text {
                            Layout.fillWidth: true
                            text: row.model && row.instance ? Picker.providerLabel(row.model, row.instance) : ""
                            color: control.fade(control.muted, 0.7)
                            font.family: control.fontFamily
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                    }
                }

                // The web's Kbd: the numbered jump for the first nine models.
                Rectangle {
                    visible: row.jumpText.length > 0
                    implicitWidth: Math.max(20, kbdText.implicitWidth + 8)
                    implicitHeight: 20
                    radius: 4
                    color: control.mutedSurface

                    Text {
                        id: kbdText

                        anchors.centerIn: parent
                        text: row.jumpText
                        color: control.muted
                        font.family: control.fontFamily
                        font.pixelSize: 12
                        font.weight: Font.Medium
                    }
                }

                AbstractButton {
                    id: star

                    readonly property bool favorite: row.model !== null && row.model.isFavorite

                    objectName: row.instance && row.model ? "modelPickerFavorite:" + row.instance.instanceId + ":" + row.model.slug : ""
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
                        radius: 4
                        color: star.hovered ? control.highlight : "transparent"
                    }

                    contentItem: Item {
                        ShellIcon {
                            anchors.centerIn: parent
                            name: "star"
                            filled: star.favorite
                            size: 12
                            color: star.favorite ? "#eab308" : control.fade(control.muted, star.hovered ? 1 : 0.72)
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

            readonly property var entry: parent ? parent.modelData : null
            readonly property int rowIndex: parent ? parent.index : -1

            objectName: entry ? "modelPickerLegacy:" + entry.instanceId : ""
            implicitHeight: 46
            radius: 4
            color: control.highlightedIndex === rowIndex || legacyHover.hovered ? control.highlight : "transparent"
            Accessible.role: Accessible.Button
            Accessible.name: qsTr("Legacy models")

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
                spacing: 6

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    Text {
                        text: qsTr("Legacy models")
                        color: control.foreground
                        font.family: control.fontFamily
                        font.pixelSize: 12
                        font.weight: Font.Medium
                    }

                    Text {
                        text: legacy.entry ? qsTr("%1 models").arg(legacy.entry.count) : ""
                        color: control.fade(control.muted, 0.7)
                        font.family: control.fontFamily
                        font.pixelSize: 12
                    }
                }

                ShellIcon {
                    name: "chevron-right"
                    size: 16
                    color: control.muted
                    rotation: legacy.entry && legacy.entry.expanded ? 90 : 0

                    Behavior on rotation {
                        NumberAnimation {
                            duration: 150
                        }
                    }
                }
            }
        }
    }

    // A rail entry: square, greyed and unclickable when the instance cannot
    // be chosen, with the web's tooltip (why it is unavailable) either way.
    // It stays enabled so the tooltip still shows on hover, as the web's
    // wrapper span does for a disabled button.
    component RailButton: Item {
        id: railButton

        property string railId: ""
        property string tooltip: ""
        property bool available: true
        readonly property bool selected: control.view === railId
        default property alias content: face.data

        width: 36
        height: 36
        Accessible.role: Accessible.Button
        Accessible.name: tooltip
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
            radius: 6
            opacity: railButton.available ? 1 : 0.5
            color: railButton.available && (railHover.hovered || railButton.activeFocus) ? Qt.tint(control.overlay, control.fade(control.foreground, 0.1)) : "transparent"
        }

        TapHandler {
            enabled: railButton.available
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
                if (railButton.available)
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

    // The web's outline "Unavailable" badge.
    component Badge: Rectangle {
        property alias text: badgeLabel.text

        implicitWidth: badgeLabel.implicitWidth + 8
        implicitHeight: badgeLabel.implicitHeight + 2
        radius: 4
        color: "transparent"
        border.color: Theme.palette.color("border", "#27272a")

        Text {
            id: badgeLabel

            anchors.centerIn: parent
            color: control.muted
            font.family: control.fontFamily
            font.pixelSize: 11
            font.weight: Font.Medium
        }
    }
}
