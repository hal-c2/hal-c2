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
//
// Docked (upstream's ComposerModelEffort), it is the composer's one model
// control: the chosen model's efforts and other options sit in a column
// beside the list, its speed beside the permissions below, and the trigger
// names the effort, fast mode and context window after the model. A pick
// leaves it open until Escape or a click outside.
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
    // What stands where the model would be when no provider can run a turn
    // (catalogue.noProvider, keyed in C++): it wins over the model name,
    // which a keep-unlisted provider can still resolve while unready.
    readonly property string noProviderText: catalogue?.noProvider === "open-provider-settings" ? qsTr("Open provider settings") : catalogue?.noProvider === "no-provider-available" ? qsTr("No provider available") : ""
    // Short names are for chat models; where favorites is off (a Space's
    // image models) the trigger keeps the model's own name.
    readonly property string triggerTitle: multiple !== null ? qsTr("%1 models").arg(multiple.length) : noProviderText.length > 0 ? noProviderText : activeModel ? Picker.displayName(activeModel, favorites, activeInstance) : (selectedModel ? selectedModel : qsTr("Choose model"))
    // The full name, for the tooltip the short title stands in for. Where
    // the button shows a stand-in instead (no provider, or several models),
    // the tooltip follows the button.
    readonly property string triggerFullTitle: multiple === null && noProviderText.length === 0 && activeModel ? Picker.displayName(activeModel, false, activeInstance) + (activeModel.isUnavailable ? qsTr(" (Unavailable)") : "") : triggerTitle

    function inMultiple(instanceId, model) {
        return multiple !== null && multiple.some(entry => entry.instanceId === instanceId && entry.model === model);
    }
    readonly property string triggerLabel: activeModel && activeModel.isUnavailable ? triggerTitle + qsTr(" (Unavailable)") : triggerTitle
    readonly property bool mac: Qt.platform.os === "osx" || Qt.platform.os === "macos"
    readonly property alias popup: popup

    // The permissions the popup's footer offers ({value, label, icon}) and
    // the thread's; with none the popup has no footer.
    property var runtimeModes: []
    property string runtimeMode: ""
    // Docked, the footer stays for the speed so the popup keeps one height.
    readonly property bool showFooter: onlyInstances === null && (runtimeModes.length > 0 || controlDocked)
    // The part the popup opens on: "models" (the search), "effort" or
    // "permissions".
    property string openOn: "models"

    // The model control: the composer's options for the chosen model
    // (model.options, the effort marked `effort`) and Appearance's effort
    // display ("label" or "bars").
    property bool docked: false
    property var options: []
    property string effortDisplay: "label"
    readonly property bool controlDocked: docked && onlyInstances === null
    readonly property var effortOption: controlDocked ? (options.find(option => option.effort === true) ?? null) : null
    readonly property bool effortLocked: (effortOption?.lockedReason ?? "").length > 0
    // Fast mode, and Codex's service tier in its place, are the footer's speed.
    readonly property var fastOption: controlDocked ? (options.find(option => option.id === "fastMode" && option.type === "boolean") ?? null) : null
    readonly property var tierOption: controlDocked && activeInstance?.driverKind === "codex" ? (options.find(option => option.id === "serviceTier" && option.type === "select") ?? null) : null
    // The column's other options, one row each below the efforts.
    readonly property var columnOptions: controlDocked ? options.filter(option => !option.effort && option.id !== fastOption?.id && option.id !== tierOption?.id) : []
    readonly property var speedChoices: tierOption ? tierOption.choices.map(choice => ({
                value: choice.id,
                label: choice.label,
                fast: /fast/i.test(choice.label),
                checked: choice.id === tierOption.value
            })) : fastOption ? [false, true].map(value => ({
                value: value,
                label: value ? qsTr("Fast") : qsTr("Standard"),
                fast: value,
                checked: (fastOption.value === true) === value
            })) : []
    // What the trigger adds after the model: the effort as a word or as bars
    // (Max and Ultrathink keep their names), a bolt for fast and the context
    // window.
    readonly property var triggerBars: effortDisplay === "bars" && effortOption?.bars && !effortOption.bars.special ? effortOption.bars : null
    readonly property string triggerEffort: effortOption === null || triggerBars !== null ? "" : optionValueLabel(effortOption)
    readonly property bool triggerFast: speedChoices.some(choice => choice.checked && choice.fast)
    readonly property var contextWindowOption: controlDocked ? (options.find(option => option.id === "contextWindow" && option.type === "select" && !option.effort) ?? null) : null
    readonly property string triggerContextWindow: contextWindowOption ? optionValueLabel(contextWindowOption) : ""
    // A model chosen with an effort to pick, until its options arrive.
    property string pendingEffortFor: ""
    // The row a pick came from: the options it changes rebuild the rows, and
    // the keyboard stays on the one picked.
    property string refocusName: ""

    // A select's chosen value by its label, else the option's own.
    function optionValueLabel(option) {
        const chosen = (option?.choices ?? []).find(choice => choice.id === option.value);
        return chosen ? chosen.label : (option?.label ?? "");
    }

    function setOption(id, value) {
        const focused = control.Window.activeFocusItem;
        refocusName = popup.opened && focused ? focused.objectName : "";
        Shell.dispatch("composer.option.set", {
            id: id,
            value: value
        });
    }

    // The column's rows the keyboard moves through, top to bottom.
    function columnRows() {
        return columnBody.children.filter(child => child.inColumn === true && child.visible && child.enabled);
    }

    // Focuses the chosen effort, else the first effort; with `any` falls
    // back to the column's first option. False when nothing took focus.
    function focusEffort(any) {
        const rows = columnRows();
        const levels = rows.filter(row => row.effortLevel === true);
        const row = levels.find(level => level.checked) ?? levels[0] ?? (any ? rows[0] : undefined);
        if (!row)
            return false;
        row.forceActiveFocus(Qt.TabFocusReason);
        return true;
    }

    function stepColumn(from, step) {
        const rows = columnRows();
        const next = rows[Math.max(0, Math.min(rows.length - 1, rows.indexOf(from) + step))];
        if (next)
            next.forceActiveFocus(Qt.TabFocusReason);
    }

    // Opens the popup on the current effort, or moves there.
    function openEffort() {
        if (!enabled || !controlDocked)
            return;
        if (popup.opened) {
            focusEffort(true);
            return;
        }
        openOn = "effort";
        popup.open();
    }

    onOptionsChanged: {
        if (pendingEffortFor.length > 0)
            Qt.callLater(focusPendingEffort);
        if (refocusName.length > 0)
            Qt.callLater(restoreFocus);
    }

    function restoreFocus() {
        const name = refocusName;
        refocusName = "";
        // Only when the rebuild dropped the keyboard to the popup itself: a
        // user who moved on to another part keeps it there.
        const focused = control.Window.activeFocusItem;
        if (!popup.opened || (focused && popup.contentItem !== focused && isAncestor(popup.contentItem, focused)))
            return;
        const row = named(popup.contentItem, name);
        if (row)
            row.forceActiveFocus(Qt.TabFocusReason);
    }

    function isAncestor(ancestor, item) {
        for (let at = item.parent; at; at = at.parent) {
            if (at === ancestor)
                return true;
        }
        return false;
    }

    function named(item, name) {
        if (item.objectName === name)
            return item;
        for (const child of item.children) {
            const found = named(child, name);
            if (found)
                return found;
        }
        return null;
    }

    function focusPendingEffort() {
        if (pendingEffortFor !== selectedInstanceId + "\n" + selectedModel || !popup.opened)
            return;
        if (focusEffort(false))
            pendingEffortFor = "";
    }

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

    // Opens the popup with its permissions menu open, or moves there.
    function openPermissions() {
        if (!enabled || !showFooter)
            return;
        if (popup.opened) {
            permissionsPicker.forceActiveFocus();
            permissionsPicker.popup.open();
            return;
        }
        openOn = "permissions";
        popup.open();
    }

    function close() {
        popup.close();
    }

    // Out of the popup with the keyboard back on the trigger.
    function leave() {
        popup.close();
        control.forceActiveFocus();
    }

    // One step back (the phone's system back): out of the permissions menu
    // when it is open, else out of the popup.
    function stepBack() {
        if (permissionsPicker.popup.visible)
            permissionsPicker.popup.close();
        else
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
        // In the model control, a model with an effort stays open on it.
        if (controlDocked && entry.hasEffort === true) {
            pendingEffortFor = instanceId + "\n" + model;
            Qt.callLater(focusPendingEffort);
            return;
        }
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
    ToolTip.text: catalogue && catalogue.shortcut ? triggerFullTitle + " · " + catalogue.shortcut : triggerFullTitle

    onClicked: {
        // The stand-in that names provider settings goes there, as it says.
        if (catalogue?.noProvider === "open-provider-settings") {
            Shell.dispatch("settings.navigate", {
                to: "/settings/providers"
            });
        } else if (popup.visible) {
            popup.close();
        } else {
            popup.open();
        }
    }

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

        Text {
            objectName: "modelPickerEffort"
            visible: text.length > 0
            Layout.maximumWidth: Theme.control.md * 3
            text: control.triggerEffort
            font: control.font
            color: control.muted
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
        }

        EffortBars {
            objectName: "modelPickerEffortBars"
            visible: control.triggerBars !== null
            count: control.triggerBars?.count ?? 0
            filled: control.triggerBars?.filled ?? 0
            color: control.muted
        }

        ShellIcon {
            objectName: "modelPickerFast"
            visible: control.triggerFast
            name: "zap"
            filled: true
            size: Theme.icon.sm
            color: control.muted
        }

        Text {
            objectName: "modelPickerContextWindow"
            visible: text.length > 0
            Layout.maximumWidth: Theme.control.md * 3
            text: control.triggerContextWindow
            font.family: control.fontFamily
            font.pixelSize: Theme.type.meta.size
            color: control.muted
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
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
        width: 360 + (control.controlDocked ? column.width : 0)
        // The search row, then six whole rows (46 tall, 2 apart) between the
        // list's margins: the list never stops on a sliced row.
        height: 40 + 2 * Theme.space.sm + 6 * 46 + 5 * 2 + (control.showFooter ? footer.height : 0)
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
            control.pendingEffortFor = "";
            control.refocusName = "";
        }
        // The keymap's modelPickerOpen.
        onVisibleChanged: Keybindings.modelPickerOpen = visible
        onOpened: {
            const selected = control.rows.findIndex(row => row.kind === "model" && row.instance.instanceId === control.selectedInstanceId && row.model.slug === control.selectedModel);
            control.highlightedIndex = selected >= 0 ? selected : control.firstSelectableRow(0, 1);
            if (control.openOn === "permissions" && control.showFooter) {
                permissionsPicker.forceActiveFocus();
                permissionsPicker.popup.open();
            } else if (control.openOn !== "effort" || !control.focusEffort(true)) {
                search.forceActiveFocus();
            }
            control.openOn = "models";
        }
        onClosed: permissionsPicker.popup.close()

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
            // Escape from any part the search and rail do not handle: the
            // column, the speed and the permissions while their menu is shut.
            Keys.onEscapePressed: control.leave()

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
                height: parent.height - (control.showFooter ? footer.height : 0)
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
                anchors.right: column.visible ? column.left : parent.right
                anchors.top: parent.top
                anchors.bottom: control.showFooter ? footer.top : parent.bottom
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
                                // Enter and Escape mid-composition are the input method's:
                                // they confirm or cancel the text, and leave the picker be.
                                // Taken here, so the popup's own Escape never sees them.
                                if (inputMethodComposing && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Escape)) {
                                    event.accepted = true;
                                    return;
                                }
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

            // Beside the models in the model control: the chosen model's
            // efforts, then its other options one row each.
            Rectangle {
                id: column

                objectName: "modelControlColumn"
                visible: control.controlDocked
                // ljos-allow(layout-fixed-size): one width for every provider, so the popup does not move as the user goes between them
                width: 200
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: control.showFooter ? footer.top : parent.bottom
                color: control.fade(control.mutedSurface, 0.4)
                radius: Theme.radiusLg

                Rectangle {
                    width: 1
                    height: parent.height
                    color: control.divider
                }

                RowLayout {
                    id: columnHeader

                    x: Theme.space.sm + 1
                    width: parent.width - 2 * Theme.space.sm - 1
                    height: 40
                    spacing: Theme.space.sm

                    Text {
                        objectName: "modelControlHeader"
                        text: control.effortOption?.label ?? (control.columnOptions.length > 0 ? qsTr("Options") : qsTr("Effort"))
                        color: control.muted
                        font.family: control.fontFamily
                        font.pixelSize: Theme.type.meta.size
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }

                    Text {
                        objectName: "modelControlModel"
                        text: control.triggerTitle
                        color: control.muted
                        font.family: control.fontFamily
                        font.pixelSize: Theme.type.meta.size
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignRight
                        Layout.maximumWidth: parent.width / 2
                    }
                }

                Flickable {
                    id: columnScroll

                    anchors.top: columnHeader.bottom
                    anchors.left: parent.left
                    anchors.leftMargin: 1
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    contentHeight: columnBody.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    clip: true

                    Column {
                        id: columnBody

                        width: columnScroll.width
                        padding: 4
                        spacing: 2

                        Text {
                            objectName: "modelControlEffortNote"
                            visible: control.effortLocked
                            width: parent.width - 8
                            leftPadding: 4
                            text: control.effortOption?.lockedReason ?? ""
                            color: control.muted
                            font.family: control.fontFamily
                            font.pixelSize: Theme.type.meta.size
                            wrapMode: Text.WordWrap
                        }

                        Repeater {
                            model: control.effortOption?.choices ?? []

                            delegate: ColumnRow {
                                required property var modelData

                                objectName: "modelControlEffort:" + modelData.id
                                effortLevel: true
                                text: modelData.label
                                isDefault: modelData.isDefault === true
                                description: modelData.description ?? ""
                                checked: modelData.id === control.effortOption?.value
                                enabled: !control.effortLocked
                                onClicked: control.setOption(control.effortOption.id, modelData.id)
                            }
                        }

                        Text {
                            objectName: "modelControlNoEffort"
                            visible: control.effortOption === null && control.columnOptions.length === 0
                            width: parent.width - 8
                            leftPadding: 4
                            text: qsTr("No effort levels")
                            color: control.muted
                            font.family: control.fontFamily
                            font.pixelSize: Theme.type.body.size
                        }

                        Rectangle {
                            visible: control.effortOption !== null && control.columnOptions.length > 0
                            x: 4
                            width: parent.width - 8
                            height: 1
                            color: control.divider
                        }

                        Repeater {
                            model: control.columnOptions

                            delegate: ColumnRow {
                                id: optionRow

                                required property var modelData
                                readonly property bool isSwitch: modelData.type === "boolean"

                                objectName: (isSwitch ? "modelControlSwitch:" : "modelControlOption:") + modelData.id
                                text: modelData.label
                                detail: isSwitch ? (modelData.value === true ? qsTr("On") : qsTr("Off")) : control.optionValueLabel(modelData)
                                chevron: !isSwitch
                                switchRow: isSwitch
                                switchOn: isSwitch && modelData.value === true
                                description: modelData.description ?? ""
                                Accessible.role: isSwitch ? Accessible.CheckBox : Accessible.ButtonMenu
                                onClicked: {
                                    if (isSwitch)
                                        control.setOption(modelData.id, modelData.value !== true);
                                    else
                                        choicesMenu.open();
                                }
                                Keys.onRightPressed: event => {
                                    event.accepted = !isSwitch;
                                    if (!isSwitch)
                                        choicesMenu.open();
                                }

                                // The option's choices, beside its row.
                                ShellMenu {
                                    id: choicesMenu

                                    objectName: "modelControlChoices:" + optionRow.modelData.id
                                    x: optionRow.width
                                    y: 0
                                    // On the chosen value, so the arrows start from it.
                                    onOpened: currentIndex = (optionRow.modelData.choices ?? []).findIndex(choice => choice.id === optionRow.modelData.value)
                                    onClosed: if (popup.opened)
                                        optionRow.forceActiveFocus()

                                    Instantiator {
                                        model: optionRow.isSwitch ? [] : optionRow.modelData.choices

                                        delegate: ShellMenuItem {
                                            required property var modelData

                                            objectName: "modelControlChoice:" + optionRow.modelData.id + ":" + modelData.id
                                            text: modelData.label
                                            detail: modelData.isDefault === true ? qsTr("Default") : ""
                                            current: modelData.id === optionRow.modelData.value
                                            onTriggered: control.setOption(optionRow.modelData.id, modelData.id)
                                            // Left closes the choices, back on their row.
                                            Keys.onLeftPressed: choicesMenu.close()
                                        }
                                        onObjectAdded: (index, object) => choicesMenu.insertItem(index, object)
                                        onObjectRemoved: (index, object) => choicesMenu.removeItem(object)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // Below the models: the speed and the thread's permissions, which
            // open their own menu.
            Rectangle {
                id: footer

                objectName: "modelPickerFooter"
                visible: control.showFooter
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Theme.control.md + 2 * Theme.space.xs + 1
                color: control.fade(control.mutedSurface, 0.4)
                radius: Theme.radiusLg

                Rectangle {
                    width: parent.width
                    height: 1
                    color: control.divider
                }

                // The speed, as segments at the footer's start.
                Row {
                    objectName: "modelControlSpeed"
                    visible: control.speedChoices.length > 0
                    x: Theme.space.xs
                    y: 1 + Theme.space.xs
                    spacing: 2

                    Repeater {
                        model: control.speedChoices

                        delegate: ShellButton {
                            required property var modelData

                            objectName: "modelControlSpeed:" + modelData.value
                            subtle: !modelData.checked
                            checked: modelData.checked
                            text: modelData.label
                            iconName: modelData.fast ? "zap" : ""
                            Accessible.name: qsTr("Speed: %1").arg(modelData.label)
                            onClicked: control.setOption(control.tierOption?.id ?? control.fastOption.id, modelData.value)
                        }
                    }
                }

                ShellComboBox {
                    id: permissionsPicker

                    readonly property int current: control.runtimeModes.findIndex(mode => mode.value === control.runtimeMode)

                    objectName: "modelPickerPermissions"
                    visible: control.runtimeModes.length > 0
                    // At the footer's end, where the speed controls do not reach.
                    width: Math.min(implicitWidth, parent.width - 2 * Theme.space.xs)
                    x: parent.width - width - Theme.space.xs
                    y: 1 + Theme.space.xs
                    iconName: current >= 0 ? (control.runtimeModes[current].icon ?? "") : ""
                    model: control.runtimeModes.map(mode => mode.label)
                    currentIndex: current
                    Accessible.name: qsTr("Permissions")
                    ToolTip.visible: hovered && !popup.visible && current >= 0
                    ToolTip.delay: 500
                    ToolTip.text: current >= 0 ? (control.runtimeModes[current].description ?? "") : ""
                    onActivated: index => Shell.dispatch("composer.runtimeMode.set", {
                            mode: control.runtimeModes[index].value
                        })
                }
            }
        }
    }

    // A row of the model control's column: an effort level (a check when
    // chosen, "Default" on the provider's own), or another option naming its
    // value with a chevron to its choices or a switch.
    component ColumnRow: AbstractButton {
        id: columnRow

        readonly property bool inColumn: true
        property bool effortLevel: false
        property bool isDefault: false
        property string description: ""
        property string detail: ""
        property bool chevron: false
        property bool switchOn: false
        property bool switchRow: false

        width: parent ? parent.width - 8 : 0
        x: 4
        implicitHeight: detail.length > 0 ? 40 : 30
        focusPolicy: Qt.StrongFocus
        hoverEnabled: true
        opacity: enabled ? 1 : 0.64
        Accessible.role: effortLevel ? Accessible.RadioButton : Accessible.Button
        Accessible.name: detail.length > 0 ? text + ", " + detail : text
        Accessible.checked: checked || switchOn
        ToolTip.visible: hovered && description.length > 0
        ToolTip.delay: 500
        ToolTip.text: description
        Keys.onUpPressed: control.stepColumn(columnRow, -1)
        Keys.onDownPressed: control.stepColumn(columnRow, 1)
        Keys.onLeftPressed: search.forceActiveFocus()
        Keys.onReturnPressed: clicked()
        Keys.onEnterPressed: clicked()
        Keys.onSpacePressed: clicked()

        background: Rectangle {
            radius: Theme.radiusXs
            color: columnRow.hovered || columnRow.activeFocus ? control.highlight : columnRow.checked ? control.fade(control.foreground, 0.08) : "transparent"
            border.color: Theme.palette.color("focus", "#3b82f6")
            border.width: columnRow.visualFocus ? 1 : 0
        }

        contentItem: RowLayout {
            spacing: Theme.space.sm

            ColumnLayout {
                Layout.fillWidth: true
                Layout.leftMargin: 6
                spacing: 0

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.space.xs

                    Text {
                        text: columnRow.text
                        color: control.foreground
                        font.family: control.fontFamily
                        font.pixelSize: Theme.type.body.size
                        elide: Text.ElideRight
                        Layout.fillWidth: !columnRow.isDefault
                    }

                    Text {
                        visible: columnRow.isDefault
                        text: qsTr("Default")
                        color: control.muted
                        font.family: control.fontFamily
                        font.pixelSize: Theme.type.meta.size
                        Layout.fillWidth: true
                    }
                }

                Text {
                    visible: columnRow.detail.length > 0
                    text: columnRow.detail
                    color: control.muted
                    font.family: control.fontFamily
                    font.pixelSize: Theme.type.meta.size
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }

            ShellIcon {
                visible: columnRow.effortLevel && columnRow.checked
                name: "check"
                size: Theme.icon.sm
                color: control.foreground
                Layout.rightMargin: 4
            }

            ShellIcon {
                visible: columnRow.chevron
                name: "chevron-right"
                size: Theme.icon.sm
                color: control.muted
                Layout.rightMargin: 4
            }

            ShellSwitch {
                visible: columnRow.switchRow
                checked: columnRow.switchOn
                // The row's value, not its own: a click asks the row.
                checkable: false
                focusPolicy: Qt.NoFocus
                onClicked: columnRow.clicked()
                Layout.rightMargin: 2
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
            Accessible.name: model ? Picker.displayName(model, false, instance) : ""
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
                            text: row.model ? Picker.displayName(row.model, false, row.instance) : ""
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

        // The end of a provider's list when it has older models: "Show more"
        // lists them above it, "Show less" folds them away again.
        Rectangle {
            id: legacy

            readonly property var entry: (parent as RowSlot)?.modelData ?? null
            readonly property int rowIndex: (parent as RowSlot)?.index ?? -1
            readonly property bool active: control.highlightedIndex === rowIndex || legacyHover.hovered
            readonly property string text: legacy.entry && legacy.entry.expanded ? qsTr("Show less") : qsTr("Show more")

            objectName: entry ? "modelPickerLegacy:" + entry.instanceId : ""
            implicitHeight: 46
            radius: Theme.radiusXs
            color: active ? control.highlight : "transparent"
            Accessible.role: Accessible.Button
            Accessible.name: legacy.text
            Accessible.onPressAction: if (legacy.entry)
                control.toggleLegacy(legacy.entry.instanceId)

            HoverHandler {
                id: legacyHover
            }

            TapHandler {
                onTapped: control.toggleLegacy(legacy.entry.instanceId)
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: legacy.text
                color: legacy.active ? control.foreground : control.muted
                font.family: control.fontFamily
                font.pixelSize: Theme.type.body.size
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
