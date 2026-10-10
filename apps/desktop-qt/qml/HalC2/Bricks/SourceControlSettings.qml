pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// Settings → Source Control, natively (SourceControlSettingsController's
// `sourceControlSettings`): the repository defaults, the version control and
// hosting tools the environment has, Git's background fetch interval, and how
// source control text is written. Rows follow the settings scope; a value
// that differs between the selected environments shows as mixed.
SettingsPage {
    id: page

    readonly property var settings: Shell.state.sourceControlSettings ?? null
    readonly property var discovery: settings?.discovery ?? null
    readonly property bool editable: Shell.state.settingsScope?.editable ?? false
    readonly property bool projectScope: settings?.projectScope ?? false
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color warning: Theme.palette.color("warning", "#fbbf24")
    readonly property var mergeMethods: ["last", "merge", "squash", "rebase"]
    readonly property var writingModes: ["repo_conventions", "conventional_commits", "custom"]
    property bool writingForAll: false

    function send(name, payload) {
        Shell.dispatch("sourceControlSettings." + name, payload ?? {});
    }

    objectName: "sourceControlSettings"
    title: qsTr("Source Control")

    // Inline components cannot see `page`; the ones that need it are handed it.
    component Heading: Label {
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: Math.round(12 * Theme.fontScale)
        font.weight: Font.DemiBold
    }

    component Caption: Label {
        Layout.fillWidth: true
        color: Theme.palette.color("textMuted", "#a1a1aa")
        font.pixelSize: Math.round(12 * Theme.fontScale)
        wrapMode: Text.Wrap
    }

    // A settings row: its title, what it does, whether it is mixed or the
    // project's own, and its control on the right.
    component ScopedRow: RowLayout {
        id: row

        required property SourceControlSettings sourceControl
        property string title
        property string description
        property bool mixed: false
        property bool overridden: false
        property string resetKey: ""
        property bool resettable: false
        default property alias control: controls.data

        Layout.fillWidth: true
        spacing: 12

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2

            RowLayout {
                spacing: 6

                Label {
                    text: row.title
                    color: row.sourceControl.foreground
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                    font.weight: Font.Medium
                }

                ShellButton {
                    objectName: "reset"
                    visible: row.resetKey.length > 0 && (row.sourceControl.projectScope ? row.overridden : row.resettable) && row.sourceControl.editable
                    subtle: true
                    text: row.sourceControl.projectScope ? qsTr("Inherit") : qsTr("Reset")
                    onClicked: row.sourceControl.send("reset", { key: row.resetKey })
                }
            }

            Label {
                objectName: "mixed"
                visible: row.mixed
                text: qsTr("Mixed across selected machines")
                color: row.sourceControl.warning
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            Caption {
                text: row.description
            }
        }

        RowLayout {
            id: controls
            spacing: 8
        }
    }

    component Tool: ColumnLayout {
        id: tool

        required property SourceControlSettings sourceControl
        required property var modelData
        objectName: "sourceControlTool:" + modelData.kind
        Layout.fillWidth: true
        spacing: 6

        // Git's fetch interval is behind a details toggle, opened by a search that targets it.
        property bool detailsOpen: false
        readonly property bool detailsShown: detailsOpen || tool.sourceControl.route?.target === "fetchInterval"

        // The name and summary share a left column; the switch centres on both lines.
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Rectangle {
                        implicitWidth: 8
                        implicitHeight: 8
                        radius: 4
                        color: tool.modelData.comingSoon ? tool.sourceControl.muted
                             : tool.modelData.enabled ? Theme.palette.color("success", "#22c55e") : tool.sourceControl.warning
                    }

                    Label {
                        text: tool.modelData.label
                        color: tool.sourceControl.foreground
                        font.pixelSize: Math.round(13 * Theme.fontScale)
                        font.weight: Font.Medium
                    }

                    Label {
                        objectName: "version"
                        visible: text.length > 0
                        text: tool.modelData.version
                        color: tool.sourceControl.muted
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                        font.family: "monospace"
                    }

                    Label {
                        objectName: "badge"
                        visible: tool.modelData.comingSoon || tool.modelData.authWarning
                        text: tool.modelData.comingSoon ? qsTr("Coming Soon") : tool.modelData.authLabel
                        color: tool.sourceControl.warning
                        font.pixelSize: Math.round(11 * Theme.fontScale)
                        font.weight: Font.DemiBold
                    }

                    Item { Layout.fillWidth: true }
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 4

                    // Alone it takes the row and wraps; with an account it is one
                    // word ("Authenticated") and the account sits beside it.
                    Caption {
                        objectName: "summary"
                        Layout.fillWidth: !tool.modelData.hasAccount
                        text: tool.modelData.summary
                    }

                    Caption {
                        visible: tool.modelData.hasAccount
                        Layout.fillWidth: false
                        text: qsTr("as")
                    }

                    ShellButton {
                        objectName: "account"
                        visible: tool.modelData.hasAccount
                        subtle: true
                        text: tool.modelData.revealed ? tool.modelData.account : "••••••"
                        Accessible.name: qsTr("Toggle source control account visibility")
                        ToolTip.visible: hovered
                        ToolTip.text: tool.modelData.revealed ? qsTr("Click to hide account") : qsTr("Click to reveal account")
                        onClicked: tool.sourceControl.send("reveal", { kind: tool.modelData.kind, revealed: !tool.modelData.revealed })
                    }

                    Item {
                        visible: tool.modelData.hasAccount
                        Layout.fillWidth: true
                    }
                }
            }

            ShellButton {
                objectName: "details"
                Layout.alignment: Qt.AlignVCenter
                visible: tool.modelData.git
                subtle: true
                iconName: tool.detailsShown ? "chevron-up" : "chevron-down"
                Accessible.name: qsTr("Toggle Git details")
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Toggle Git details")
                onClicked: tool.detailsOpen = !tool.detailsShown
            }

            ShellSwitch {
                objectName: "availability"
                Layout.alignment: Qt.AlignVCenter
                visible: !tool.modelData.comingSoon
                enabled: false
                checked: tool.modelData.enabled
                Accessible.name: qsTr("%1 availability").arg(tool.modelData.label)
            }
        }

        // Git's background fetch, an environment-wide timer.
        ScopedRow {
            sourceControl: tool.sourceControl
            objectName: "fetchInterval"
            visible: tool.modelData.git && tool.detailsShown
            title: qsTr("Automatic Git fetch interval")
            description: tool.sourceControl.projectScope
                ? qsTr("Applies to the whole environment. Choose all projects to change it.")
                : qsTr("Refresh remote branches in the background. Set to 0 to avoid automatic Git prompts.")
            mixed: tool.sourceControl.settings?.fetchInterval?.mixed ?? false

            ShellButton {
                objectName: "resetFetch"
                visible: (tool.sourceControl.settings?.fetchInterval?.custom ?? false) && !tool.sourceControl.projectScope && tool.sourceControl.editable
                subtle: true
                text: qsTr("Reset")
                onClicked: tool.sourceControl.send("resetFetchInterval")
            }

            ShellSpinBox {
                objectName: "seconds"
                enabled: tool.sourceControl.editable && !tool.sourceControl.projectScope
                from: 0
                to: 86400
                stepSize: 5
                editable: true
                value: tool.sourceControl.settings?.fetchInterval?.seconds ?? 30
                textFromValue: (number, locale) => number === 0 ? qsTr("Off") : qsTr("%1 s").arg(number)
                valueFromText: (text, locale) => parseInt(text) || 0
                Accessible.name: qsTr("Automatic Git fetch interval in seconds")
                onValueModified: tool.sourceControl.send("fetchInterval", { seconds: value })
            }
        }
    }

    SettingsScopeSentence {}

    Heading { text: qsTr("Repositories") }

    ScopedRow {
        sourceControl: page
        objectName: "autoPull"
        title: qsTr("Automatically pull")
        description: page.projectScope
            ? qsTr("Keeps this project's default branch current when the checkout has no local changes or commits.")
            : qsTr("Keeps the default branch current when the checkout has no local changes or commits. Projects can override it.")
        mixed: page.settings?.autoPull?.mixed ?? false
        overridden: page.settings?.autoPull?.overridden ?? false
        resetKey: "defaultAutoPull"
        resettable: page.settings?.autoPull?.value === true

        ShellSwitch {
            objectName: "control"
            enabled: page.editable
            checked: !(page.settings?.autoPull?.mixed ?? false) && page.settings?.autoPull?.value === true
            Accessible.name: qsTr("Default automatic pull")
            onToggled: page.send("autoPull", { enabled: checked })
        }
    }

    ScopedRow {
        sourceControl: page
        objectName: "mergeMethod"
        title: qsTr("Pull request merge method")
        description: page.projectScope
            ? qsTr("Pull requests in this project start with this method.")
            : qsTr("Pull requests start with this method. Last selected reuses whatever you chose most recently on this device.")
        mixed: page.settings?.mergeMethod?.mixed ?? false
        overridden: page.settings?.mergeMethod?.overridden ?? false
        resetKey: "pullRequestMergeMethod"
        resettable: (page.settings?.mergeMethod?.value ?? "last") !== "last"

        ShellComboBox {
            objectName: "control"
            enabled: page.editable
            outline: true
            implicitWidth: 180
            model: [qsTr("Last selected"), qsTr("Merge"), qsTr("Squash and merge"), qsTr("Rebase and merge")]
            currentIndex: page.settings?.mergeMethod?.mixed ? -1 : page.mergeMethods.indexOf(page.settings?.mergeMethod?.value ?? "last")
            displayText: page.settings?.mergeMethod?.mixed ? qsTr("Mixed") : currentText
            Accessible.name: qsTr("Default pull request merge method")
            onActivated: index => page.send("mergeMethod", { method: page.mergeMethods[index] })
        }
    }

    // What the environment has: its version control tools and hosts.
    ColumnLayout {
        objectName: "sourceControlDiscovery"
        Layout.fillWidth: true
        spacing: 12

        RowLayout {
            Layout.fillWidth: true

            Heading {
                Layout.fillWidth: true
                text: {
                    const status = page.discovery?.status;
                    const found = (page.discovery?.versionControl ?? []).length + (page.discovery?.providers ?? []).length;
                    if (status !== "ready" || found === 0) return qsTr("Server environment");
                    return ((page.discovery.versionControl ?? []).length > 0 ? qsTr("Version Control") : qsTr("Source Control Providers"))
                           + (page.discovery.suffix ?? "");
                }
            }

            ShellButton {
                objectName: "scan"
                visible: (page.discovery?.status ?? "none") !== "none"
                subtle: true
                enabled: !(page.discovery?.scanning ?? false)
                iconName: "refresh-cw"
                Accessible.name: page.discovery?.scanning ? qsTr("Scanning server environment") : qsTr("Rescan server environment")
                ToolTip.visible: hovered
                ToolTip.text: page.discovery?.scanning ? qsTr("Scanning…") : qsTr("Rescan Git and hosting integrations")
                onClicked: page.send("scan")
            }
        }

        ColumnLayout {
            objectName: "discoveryNotice"
            Layout.fillWidth: true
            spacing: 2
            visible: (page.discovery?.title ?? "").length > 0

            Label {
                objectName: "noticeTitle"
                Layout.fillWidth: true
                text: page.discovery?.title ?? ""
                color: page.foreground
                font.pixelSize: Math.round(13 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            Caption {
                objectName: "noticeDetail"
                visible: text.length > 0
                text: page.discovery?.detail ?? ""
            }
        }

        Repeater {
            model: page.discovery?.status === "ready" ? page.discovery.versionControl : []
            delegate: Tool {
                sourceControl: page
            }
        }

        Heading {
            visible: page.discovery?.status === "ready" && page.discovery.versionControl.length > 0 && page.discovery.providers.length > 0
            text: qsTr("Source Control Providers")
        }

        Repeater {
            model: page.discovery?.status === "ready" ? page.discovery.providers : []
            delegate: Tool {
                sourceControl: page
            }
        }
    }

    Heading { text: qsTr("Text generation") }

    ScopedRow {
        sourceControl: page
        objectName: "writingStyle"
        title: qsTr("Writing style")
        description: page.settings?.writingStyle?.description ?? ""
        mixed: page.settings?.writingStyle?.mixed ?? false
        overridden: page.settings?.writingStyle?.overridden ?? false
        resetKey: "sourceControlWritingStyle"
        resettable: page.settings?.writingStyle?.dirty ?? false

        ShellComboBox {
            objectName: "control"
            enabled: page.editable
            outline: true
            implicitWidth: 220
            model: [qsTr("Repository conventions"), qsTr("Conventional Commits"), qsTr("Custom instructions")]
            currentIndex: page.writingModes.indexOf(page.settings?.writingStyle?.mode ?? "")
            displayText: currentIndex < 0 ? qsTr("Mixed") : currentText
            Accessible.name: qsTr("Source control writing style")
            onActivated: index => page.send("writingMode", { mode: page.writingModes[index] })
        }
    }

    ShellButton {
        objectName: "writeForAll"
        visible: (page.settings?.writingStyle?.mixed ?? false) && !page.writingForAll
        enabled: page.editable
        text: qsTr("Write custom instructions for all")
        onClicked: page.writingForAll = true
    }

    TextArea {
        id: instructions

        objectName: "instructions"
        Layout.fillWidth: true
        Layout.preferredHeight: 96
        readonly property bool forAll: page.settings?.writingStyle?.mixed ?? false
        visible: forAll ? page.writingForAll : page.settings?.writingStyle?.mode === "custom"
        enabled: page.editable
        text: forAll ? "" : (page.settings?.writingStyle?.instructions ?? "")
        wrapMode: TextEdit.Wrap
        color: page.foreground
        font.pixelSize: Math.round(13 * Theme.fontScale)
        placeholderText: forAll ? qsTr("Write the instructions each selected environment should use.")
                                : qsTr("Keep titles concise. Use short bullet points in descriptions.")
        placeholderTextColor: Theme.palette.color("placeholder", "#71717a")
        Accessible.name: qsTr("Custom source control writing instructions")
        background: Rectangle {
            radius: Math.min(Theme.radius, 8)
            color: Theme.palette.color("input", "#18181b")
            border.color: Theme.palette.color("border", "#27272a")
        }
        // Instructions save when the field is left.
        onActiveFocusChanged: {
            if (activeFocus || forAll) return;
            if (text.trim() !== (page.settings?.writingStyle?.instructions ?? "")) page.send("instructions", { text: text });
        }
    }

    ShellButton {
        objectName: "applyForAll"
        visible: instructions.forAll && page.writingForAll
        enabled: page.editable
        text: qsTr("Apply instructions to all")
        onClicked: {
            page.send("instructions", { text: instructions.text });
            page.writingForAll = false;
        }
    }

    ScopedRow {
        sourceControl: page
        objectName: "templates"
        title: qsTr("Follow change request templates")
        description: qsTr("Use the repository's template for change request descriptions when available.")
        mixed: page.settings?.templates?.mixed ?? false
        overridden: page.settings?.templates?.overridden ?? false
        resetKey: "followChangeRequestTemplates"
        resettable: (page.settings?.templates?.mixed ?? false) || page.settings?.templates?.value === false

        ShellSwitch {
            objectName: "control"
            enabled: page.editable
            checked: !(page.settings?.templates?.mixed ?? false) && (page.settings?.templates?.value ?? true)
            Accessible.name: qsTr("Follow change request templates")
            onToggled: page.send("templates", { enabled: checked })
        }
    }

    ScopedRow {
        id: writer

        sourceControl: page

        readonly property var model: page.settings?.writerModel ?? null

        objectName: "writerModel"
        title: qsTr("Source control writer model")
        description: writer.model?.available ?? false
            ? qsTr("Model for source control text and branch or bookmark names. Off uses the environment's text generation model.")
            : qsTr("Connect an environment to choose its source control writer model.")
        mixed: writer.model?.mixed ?? false
        overridden: writer.model?.overridden ?? false
        resetKey: page.projectScope ? "sourceControlWriterModelSelection" : ""

        Label {
            visible: (writer.model?.on ?? false) && !(writer.model?.canEnable ?? false)
            text: qsTr("No text generation providers available.")
            color: page.muted
            font.pixelSize: Math.round(12 * Theme.fontScale)
        }

        ShellComboBox {
            id: picker

            objectName: "picker"
            visible: (writer.model?.on ?? false) && (writer.model?.canEnable ?? false)
            enabled: page.editable
            outline: true
            implicitWidth: 240
            model: (writer.model?.models ?? []).map(entry => entry.reason ? qsTr("%1 — %2").arg(entry.label, entry.reason) : entry.label)
            currentIndex: (writer.model?.models ?? []).findIndex(entry => entry.key === writer.model.key)
            displayText: writer.model?.mixed ? qsTr("Mixed")
                       : currentIndex >= 0 ? writer.model.models[currentIndex].label : ""
            Accessible.name: qsTr("Source control writer model")
            // A model that cannot be used is shown with why; picking it says so.
            onActivated: index => page.send("pickWriterModel", { key: writer.model.models[index].key })
        }

        ShellSwitch {
            objectName: "control"
            visible: writer.model?.available ?? false
            enabled: page.editable && ((writer.model?.on ?? false) || (writer.model?.canEnable ?? false))
            checked: writer.model?.on ?? false
            Accessible.name: qsTr("Use a separate source control writer model")
            onToggled: page.send("writerModel", { enabled: checked })
        }
    }
}
