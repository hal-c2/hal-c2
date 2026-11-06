pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell
import "js/settingsRows.js" as Rows
import "js/settingsPages.js" as Pages

// A native settings page: its title, anything the page puts first (its
// children), then `rows` (js/settingsRows.js) under their section headings,
// each row on a hairline, in one centred column (columnX in js/settingsPages.js).
// A settings search result it holds (route.target, an objectName on the page)
// is scrolled into view when opened, or, when the selected scope cannot show
// it, a notice in place of the page says which scope can.
Rectangle {
    id: page

    property string title: ""
    property var rows: []
    default property alias content: lead.data
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color line: Theme.palette.color("border", "#27272a")
    // How wide the page lays its content out, whatever that content asks for.
    readonly property real contentWidth: column.width

    readonly property var route: Shell.state.route ?? null
    readonly property int targetSeq: route !== null && route.targetSeq !== undefined ? route.targetSeq : 0

    // The search result opened here, while it is one the page holds (Pages.targetOf).
    readonly property var scope: Shell.state.settingsScope ?? null
    readonly property var target: route !== null && route.kind === "settings" && route.target ? Pages.targetOf(route.section, route.target, Qt.platform.os) : null

    // What stands between the user and the opened setting, shown in place of
    // the page: {text, choices: [{label, action, payload}]}, or null. A setting
    // some selected environment cannot have offers the environments that can;
    // one set per environment offers every project.
    readonly property var notice: {
        if (target === null || scope === null) return null;
        if (target.capability) {
            const targets = scope.targets ?? [];
            const environments = scope.environments ?? [];
            const supports = environment => environment.capabilities?.[target.capability] === true;
            // The rule Settings.supports() shows the row by: every target's
            // settings are read and it has the capability. A target still
            // loading is waited for; one offline cannot show the setting.
            const states = targets.map(id => environments.find(candidate => candidate.id === id));
            if (states.some(environment => environment !== undefined && environment.online && !environment.readable)) return null;
            const lacking = states.length === 0 || states.some(environment => environment === undefined || !environment.readable || !supports(environment));
            if (!lacking) return null;
            const choices = environments.filter(environment => environment.online && supports(environment)).map(environment => ({
                label: environment.label, action: "settingsScope.environment", payload: { id: environment.id }
            }));
            return {
                text: choices.length > 0
                    ? qsTr("%1 requires a supporting environment. Choose one to continue.").arg(target.title)
                    : qsTr("%1 requires a supporting environment. Connect or update an environment to continue.").arg(target.title),
                choices: choices
            };
        }
        if (target.scope === "environment" && scope.kind === "project") {
            return {
                text: qsTr("%1 is not available for the selected target. Choose its owning scope to continue.").arg(target.title),
                choices: [{ label: qsTr("All projects"), action: "settingsScope.project", payload: { key: "" } }]
            };
        }
        return null;
    }

    // Moves to the scope a notice offers, then on to the setting.
    function choose(choice) {
        const section = route.section;
        const targetId = route.target;
        Shell.dispatch(choice.action, choice.payload);
        Shell.dispatch("settings.openResult", { to: section, targetId: targetId });
    }

    function descendant(item, name) {
        for (let i = 0; i < item.children.length; ++i) {
            const child = item.children[i];
            if (child.objectName === name) return child;
            const found = descendant(child, name);
            if (found !== null) return found;
        }
        return null;
    }

    // An opened result is kept in view while the page still lays out (rows
    // that arrive with its state), until the user scrolls.
    property bool following: false

    // The folded sections the user, or a search result inside one, opened.
    property var openFolds: ({})

    function setFold(section, open) {
        if ((openFolds[section] === true) === open) return;
        const next = Object.assign({}, openFolds);
        next[section] = open;
        openFolds = next;
    }

    // Scrolls the route's target to the top of the page, when it is here.
    function reveal() {
        if (route === null || !route.target) return;
        const fold = Rows.foldOf(rows, route.target);
        if (fold.length > 0 && !openFolds[fold]) {
            // Its rows are made once the fold is open.
            setFold(fold, true);
            Qt.callLater(reveal);
            return;
        }
        if (notice !== null) return;
        // A setting hidden until another is on opens at that one.
        let target = descendant(column, route.target);
        if ((target === null || !target.visible) && page.target?.within)
            target = descendant(column, page.target.within);
        if (target === null) return;
        following = true;
        const y = target.mapToItem(column, 0, 0).y + column.y - Theme.space.md;
        flick.contentY = Math.max(0, Math.min(y, flick.contentHeight - flick.height));
    }

    // Tab can focus a control below the fold; it is scrolled into view so
    // it is never used unseen.
    readonly property Item focusedItem: Window.activeFocusItem

    function revealFocus(item) {
        let inside = item;
        while (inside !== null && inside !== column)
            inside = inside.parent;
        if (inside === null) return;
        const top = item.mapToItem(flick.contentItem, 0, 0).y;
        const bottom = top + item.height;
        let y = flick.contentY;
        const edge = Theme.space.md;
        if (top < y + edge || bottom - top > flick.height - 2 * edge)
            y = top - edge;
        else if (bottom > y + flick.height - edge)
            y = bottom - flick.height + edge;
        else
            return;
        following = false;
        flick.contentY = Math.max(0, Math.min(y, flick.contentHeight - flick.height));
    }

    onFocusedItemChanged: if (focusedItem !== null) revealFocus(focusedItem)
    onTargetSeqChanged: Qt.callLater(reveal)
    // The setting a notice stood in for is shown once the notice goes.
    onNoticeChanged: if (notice === null) Qt.callLater(reveal)
    Component.onCompleted: Qt.callLater(reveal)
    color: Theme.palette.color("canvas", "#0b0b0d")

    Flickable {
        id: flick
        objectName: "scroll"

        anchors.fill: parent
        contentHeight: column.implicitHeight + 2 * Theme.space.xl
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar {
            objectName: "scrollBar"
            Accessible.name: qsTr("Scroll settings")
        }
        onMovementStarted: page.following = false

        ColumnLayout {
            id: column

            onImplicitHeightChanged: if (page.following) Qt.callLater(page.reveal)

            x: Pages.columnX(flick.width, Theme.space.xl)
            y: Theme.space.xl
            width: Pages.columnWidth(flick.width, Theme.space.xl)
            spacing: Theme.space.md

            SettingsBreadcrumb {
                Layout.fillWidth: true
                section: page.title
            }

            ColumnLayout {
                objectName: "settingsNotice"

                visible: page.notice !== null
                Layout.fillWidth: true
                spacing: Theme.space.md

                Label {
                    Layout.fillWidth: true
                    text: page.notice?.text ?? ""
                    color: page.foreground
                    font.pixelSize: Theme.type.body.size
                    wrapMode: Text.Wrap
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: Theme.space.sm

                    Repeater {
                        model: page.notice?.choices ?? []

                        delegate: ShellButton {
                            required property var modelData

                            objectName: "choose:" + (modelData.payload.id ?? "allProjects")
                            text: modelData.label
                            onClicked: page.choose(modelData)
                        }
                    }
                }
            }

            ColumnLayout {
                id: lead

                visible: page.notice === null
                Layout.fillWidth: true
                spacing: Theme.space.md
            }

            Repeater {
                model: Rows.listed(page.rows, Qt.platform.os, page.openFolds)

                // A row sits on a hairline, centred in the gap above it; a
                // heading opens its section without one.
                delegate: Loader {
                    id: entry

                    required property var modelData
                    readonly property bool onHairline: modelData.section === undefined

                    Layout.fillWidth: true
                    Layout.topMargin: onHairline ? Theme.space.md : 0
                    // A row every selected environment must support is listed once they do.
                    visible: {
                        Settings.document;
                        if (page.notice !== null) return false;
                        return !modelData.requires || Settings.supports(modelData.requires);
                    }
                    sourceComponent: modelData.section !== undefined ? heading : modelData.link !== undefined ? linkRow : modelData.component === "textGeneration" ? textGenerationRow : modelData.component === "backgroundActivity" ? backgroundActivityRow : settingRow

                    Rectangle {
                        visible: entry.onHairline
                        y: -Math.round((Theme.space.md + column.spacing) / 2)
                        width: entry.width
                        height: 1
                        color: page.line
                    }

                    Component {
                        id: heading

                        ColumnLayout {
                            id: sectionHeading

                            readonly property bool folded: entry.modelData.folded === true
                            readonly property bool open: page.openFolds[entry.modelData.section] === true

                            objectName: "settingsSection:" + entry.modelData.section
                            spacing: Theme.space.sm

                            RowLayout {
                                Layout.topMargin: Theme.space.lg
                                spacing: Theme.space.sm

                                Label {
                                    text: entry.modelData.section
                                    color: page.foreground
                                    font.pixelSize: Theme.type.title.size
                                    font.weight: Font.DemiBold
                                }

                                ShellButton {
                                    objectName: "fold"
                                    visible: sectionHeading.folded
                                    subtle: true
                                    text: sectionHeading.open ? qsTr("Hide") : qsTr("Show")
                                    Accessible.name: sectionHeading.open ? qsTr("Hide %1").arg(entry.modelData.section) : qsTr("Show %1").arg(entry.modelData.section)
                                    onClicked: page.setFold(entry.modelData.section, !sectionHeading.open)
                                }
                            }
                        }
                    }

                    // A row that opens another section (settings.navigate).
                    Component {
                        id: linkRow

                        RowLayout {
                            objectName: "settingsRow:" + entry.modelData.id
                            spacing: Theme.space.md

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: Theme.space.xxs

                                Label {
                                    text: entry.modelData.title
                                    color: page.foreground
                                    font.pixelSize: Theme.type.body.size
                                    font.weight: Font.Medium
                                }

                                Label {
                                    Layout.fillWidth: true
                                    text: entry.modelData.description ?? ""
                                    color: Theme.palette.color("inkTertiary", "#a1a1aa")
                                    font.pixelSize: Theme.type.meta.size
                                    wrapMode: Text.Wrap
                                }
                            }

                            ShellButton {
                                objectName: "open"
                                text: entry.modelData.button
                                onClicked: Shell.dispatch("settings.navigate", { to: entry.modelData.link })
                            }
                        }
                    }

                    Component {
                        id: textGenerationRow

                        TextGenerationRow {
                            spec: entry.modelData
                        }
                    }

                    Component {
                        id: backgroundActivityRow

                        BackgroundActivityRow {
                            spec: entry.modelData
                        }
                    }

                    Component {
                        id: settingRow

                        SettingsRow {
                            spec: entry.modelData
                        }
                    }
                }
            }
        }
    }
}
