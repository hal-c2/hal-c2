import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// The usage page (UsageController publishes `usage`): cost or tokens over a
// window, merged across the chosen environments, or how much of each
// provider's limits is left.
Rectangle {
    id: page

    readonly property var model: Shell.state.usage ?? null
    readonly property string metric: model ? model.metric : "limits"
    readonly property bool limitsShown: metric === "limits"
    readonly property var summary: model ? model.summary : null
    readonly property var limits: model && model.limits ? model.limits : ({ pools: [], notices: [] })
    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#a1a1aa")
    readonly property color warning: Theme.palette.color("warning", "#f59e0b")

    function usd(value) {
        return "$" + Number(value).toLocaleString(Qt.locale("en_US"), "f", 2);
    }

    // K, M, B and T with three significant figures, as the web shows tokens.
    function tokens(value) {
        const units = ["", "K", "M", "B", "T"];
        let scaled = Number(value);
        let unit = 0;
        while (Math.abs(scaled) >= 1000 && unit < units.length - 1) {
            scaled /= 1000;
            ++unit;
        }
        return (unit === 0 ? String(Math.round(scaled)) : String(Number(scaled.toPrecision(3)))) + units[unit];
    }

    function amount(row) {
        return page.metric === "tokens" ? page.tokens(row.totalTokens) : page.usd(row.costUsd);
    }

    function sessions(count) {
        return count === 1 ? qsTr("1 session") : qsTr("%1 sessions").arg(Math.round(count));
    }

    // How long until `iso`: `2d 3h`, `3h 20m` or `5m`; "" once it has passed.
    function until(iso) {
        const minutes = Math.max(0, Math.round((Date.parse(iso) - Date.now()) / 60000));
        if (minutes === 0)
            return "";
        const days = Math.floor(minutes / 1440);
        const hours = Math.floor((minutes % 1440) / 60);
        if (days > 0)
            return qsTr("%1d %2h").arg(days).arg(hours);
        if (hours > 0)
            return qsTr("%1h %2m").arg(hours).arg(minutes % 60);
        return qsTr("%1m").arg(minutes);
    }

    function resetsIn(iso) {
        if (!iso)
            return "";
        const left = page.until(iso);
        return left ? qsTr("resets in %1").arg(left) : qsTr("resets now");
    }

    // `2 reset credits banked · next expires in 27d 23h` (resetCreditsSummary).
    function credits(row) {
        if (row.available === 0)
            return qsTr("No reset credits banked");
        const banked = row.available === 1 ? qsTr("1 reset credit banked") : qsTr("%1 reset credits banked").arg(row.available);
        const left = row.nextExpiresAt ? page.until(row.nextExpiresAt) : "";
        return left ? qsTr("%1 · next expires in %2").arg(banked).arg(left) : banked;
    }

    color: Theme.palette.color("canvas", "#0b0b0d")

    component Toggle: ShellButton {
        required property bool selected

        primary: selected
        subtle: !selected
    }

    component Section: Label {
        Layout.topMargin: 12
        color: page.muted
        font.pixelSize: Math.round(12 * Theme.fontScale)
        font.weight: Font.DemiBold
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 8

        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Label {
                text: qsTr("Usage")
                color: page.foreground
                font.pixelSize: Math.round(18 * Theme.fontScale)
                font.weight: Font.DemiBold
            }

            Label {
                objectName: "usageWindowLabel"
                visible: !page.limitsShown
                text: page.model ? page.model.windowLabel : ""
                color: page.muted
                font.pixelSize: Math.round(12 * Theme.fontScale)
            }

            Item {
                Layout.fillWidth: true
            }

            ShellComboBox {
                id: environmentBox

                readonly property var choices: [{ id: "", label: qsTr("All environments") }].concat((page.model ? page.model.environments : []).map(environment => ({
                    id: environment.id,
                    label: page.limitsShown || environment.status === "ready" ? environment.label : environment.status === "scanning" ? qsTr("%1 · Scanning…").arg(environment.label) : environment.status === "outdated" ? qsTr("%1 · Update required").arg(environment.label) : qsTr("%1 · Unavailable").arg(environment.label)
                })))

                objectName: "usageEnvironment"
                visible: page.model !== null && page.model.environments.length > 1
                outline: true
                textRole: "label"
                valueRole: "id"
                model: choices
                currentIndex: Math.max(0, choices.findIndex(choice => choice.id === (page.model ? page.model.environmentId : "")))
                onActivated: index => Shell.dispatch("usage.environment", { id: choices[index].id })
            }

            ShellButton {
                objectName: "usagePrices"
                text: qsTr("Model prices")
                onClicked: Shell.dispatch("usagePrices.open")
            }

            ShellButton {
                objectName: "usageRefresh"
                iconName: "refresh-cw"
                enabled: page.model !== null && !page.model.refreshing
                Accessible.name: page.limitsShown ? qsTr("Refresh limits") : qsTr("Refresh usage")
                onClicked: Shell.dispatch("usage.refresh")
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 4

            Repeater {
                model: [["cost", qsTr("Cost")], ["tokens", qsTr("Tokens")], ["limits", qsTr("Limits")]]

                delegate: Toggle {
                    required property var modelData

                    objectName: "usageMetric_" + modelData[0]
                    text: modelData[1]
                    selected: page.metric === modelData[0]
                    onClicked: Shell.dispatch("usage.metric", { metric: modelData[0] })
                }
            }

            Item {
                Layout.preferredWidth: 12
            }

            Repeater {
                model: [[1, qsTr("Past 24h")], [7, qsTr("7 days")], [30, qsTr("30 days")], [90, qsTr("90 days")]]

                delegate: Toggle {
                    required property var modelData

                    text: modelData[1]
                    enabled: !page.limitsShown
                    selected: page.model !== null && page.model.windowDays === modelData[0]
                    onClicked: Shell.dispatch("usage.window", { days: modelData[0] })
                }
            }
        }

        Repeater {
            model: page.limitsShown ? page.limits.notices : (page.model ? page.model.notices : [])

            delegate: Label {
                required property string modelData

                Layout.fillWidth: true
                text: modelData
                color: page.warning
                font.pixelSize: Math.round(12 * Theme.fontScale)
                wrapMode: Text.Wrap
            }
        }

        Label {
            objectName: "usageMessage"
            Layout.fillWidth: true
            Layout.topMargin: 48
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            color: page.muted
            font.pixelSize: Math.round(13 * Theme.fontScale)
            visible: text.length > 0
            text: page.model ? page.model.message : ""
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: availableWidth
            clip: true

            ColumnLayout {
                width: parent.width
                spacing: 6

                // Limits: one section per provider, one line per window.
                Repeater {
                    model: page.limitsShown ? page.limits.pools : []

                    delegate: ColumnLayout {
                        id: pool

                        required property var modelData

                        Layout.fillWidth: true
                        spacing: 6

                        RowLayout {
                            Layout.topMargin: 8
                            spacing: 6

                            ProviderIcon {
                                driverKind: pool.modelData.driver
                            }

                            Label {
                                text: pool.modelData.label
                                color: page.foreground
                                font.pixelSize: Math.round(14 * Theme.fontScale)
                                font.weight: Font.DemiBold
                            }
                        }

                        Repeater {
                            model: pool.modelData.windows

                            delegate: ShellCard {
                                id: card

                                required property var modelData

                                Layout.fillWidth: true
                                implicitHeight: cardColumn.implicitHeight + 20

                                ColumnLayout {
                                    id: cardColumn

                                    anchors.fill: parent
                                    anchors.margins: 10
                                    spacing: 6

                                    RowLayout {
                                        Layout.fillWidth: true

                                        Label {
                                            Layout.fillWidth: true
                                            text: card.modelData.label
                                            color: page.muted
                                            font.pixelSize: Math.round(12 * Theme.fontScale)
                                        }

                                        Label {
                                            text: page.resetsIn(card.modelData.resetsAt)
                                            color: page.muted
                                            font.pixelSize: Math.round(11 * Theme.fontScale)
                                        }
                                    }

                                    Label {
                                        text: qsTr("%1% left").arg(card.modelData.remainingPercent)
                                        color: page.foreground
                                        font.pixelSize: Math.round(20 * Theme.fontScale)
                                        font.weight: Font.DemiBold
                                    }

                                    // One share per account, the soonest reset first.
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        Repeater {
                                            model: card.modelData.accounts

                                            delegate: ColumnLayout {
                                                required property var modelData

                                                Layout.fillWidth: true
                                                Layout.preferredWidth: 1
                                                spacing: 2

                                                Rectangle {
                                                    Layout.fillWidth: true
                                                    implicitHeight: 6
                                                    radius: 3
                                                    color: Theme.palette.color("accentSurface", "#27272a")

                                                    Rectangle {
                                                        width: parent.width * Math.max(0, 100 - modelData.usedPercent) / 100
                                                        height: parent.height
                                                        radius: 3
                                                        color: Theme.palette.color("accent", "#3b82f6")
                                                    }
                                                }

                                                Label {
                                                    Layout.fillWidth: true
                                                    text: qsTr("%1 · %2%").arg(modelData.name).arg(Math.round(100 - modelData.usedPercent))
                                                    color: page.muted
                                                    font.pixelSize: Math.round(11 * Theme.fontScale)
                                                    elide: Text.ElideRight
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Banked reset credits, spent only once the user confirms.
                        Repeater {
                            model: pool.modelData.credits ?? []

                            delegate: RowLayout {
                                required property var modelData

                                objectName: "usageCredits_" + modelData.key
                                Layout.fillWidth: true
                                spacing: 8

                                Label {
                                    text: pool.modelData.credits.length > 1 ? qsTr("%1: %2").arg(modelData.name).arg(page.credits(modelData)) : page.credits(modelData)
                                    color: page.muted
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
                                }

                                ShellButton {
                                    objectName: "useReset"
                                    visible: modelData.available > 0
                                    enabled: !modelData.busy
                                    subtle: true
                                    text: modelData.busy ? qsTr("Using…") : qsTr("Use reset")
                                    onClicked: {
                                        resetDialog.key = modelData.key;
                                        resetDialog.open();
                                    }
                                }

                                Label {
                                    objectName: "resetStatus"
                                    Layout.fillWidth: true
                                    visible: text.length > 0
                                    text: modelData.status
                                    color: page.foreground
                                    font.pixelSize: Math.round(12 * Theme.fontScale)
                                    wrapMode: Text.Wrap
                                }
                            }
                        }
                    }
                }

                // Usage: the total, each provider's part, then the breakdowns.
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: !page.limitsShown && page.summary !== null
                    spacing: 4

                    Label {
                        objectName: "usageTotal"
                        text: page.summary ? page.amount(page.summary) : ""
                        color: page.foreground
                        font.pixelSize: Math.round(28 * Theme.fontScale)
                        font.weight: Font.DemiBold
                    }

                    Label {
                        text: {
                            if (!page.summary)
                                return "";
                            const count = page.sessions(page.summary.sessions);
                            if (page.metric === "tokens")
                                return count;
                            if (page.summary.unpricedShare > 0)
                                return qsTr("%1 · API estimate excludes %2% unpriced records").arg(count).arg((page.summary.unpricedShare * 100).toFixed(1));
                            return qsTr("%1 · API estimate").arg(count);
                        }
                        color: page.muted
                        font.pixelSize: Math.round(12 * Theme.fontScale)
                    }

                    Repeater {
                        model: page.summary ? page.summary.providers : []

                        delegate: RowLayout {
                            required property var modelData

                            Layout.fillWidth: true
                            spacing: 6

                            ProviderIcon {
                                driverKind: modelData.id === "claude" ? "claudeAgent" : modelData.id
                            }

                            Label {
                                Layout.fillWidth: true
                                text: qsTr("%1  %2").arg(modelData.label).arg(page.sessions(modelData.sessions))
                                color: page.foreground
                                font.pixelSize: Math.round(13 * Theme.fontScale)
                            }

                            Label {
                                text: page.amount(modelData)
                                color: page.foreground
                                font.pixelSize: Math.round(13 * Theme.fontScale)
                            }
                        }
                    }

                    Section {
                        text: qsTr("Totals")
                    }

                    Repeater {
                        model: page.summary ? [[qsTr("Processed tokens"), page.tokens(page.summary.totalTokens)], [qsTr("Cached input"), page.tokens(page.summary.cachedInputTokens)], [qsTr("Uncached input"), page.tokens(page.summary.uncachedInputTokens)], [qsTr("Output"), page.tokens(page.summary.outputTokens)], [qsTr("Cache savings"), page.usd(page.summary.cacheSavingsUsd)]] : []

                        delegate: RowLayout {
                            required property var modelData

                            Layout.fillWidth: true

                            Label {
                                Layout.fillWidth: true
                                text: modelData[0]
                                color: page.muted
                                font.pixelSize: Math.round(12 * Theme.fontScale)
                            }

                            Label {
                                text: modelData[1]
                                color: page.foreground
                                font.pixelSize: Math.round(12 * Theme.fontScale)
                            }
                        }
                    }

                    Section {
                        text: qsTr("Models")
                    }

                    Repeater {
                        model: page.summary ? page.summary.models : []

                        delegate: RowLayout {
                            required property var modelData

                            Layout.fillWidth: true

                            Label {
                                Layout.fillWidth: true
                                text: modelData.model
                                color: page.foreground
                                font.pixelSize: Math.round(12 * Theme.fontScale)
                                elide: Text.ElideRight
                            }

                            Label {
                                text: page.metric === "cost" && modelData.unpriced ? qsTr("Unpriced") : page.amount(modelData)
                                color: page.foreground
                                font.pixelSize: Math.round(12 * Theme.fontScale)
                            }
                        }
                    }

                    Section {
                        text: page.model && page.model.windowDays === 1 ? qsTr("Hourly") : qsTr("Daily")
                    }

                    // Newest first, each a bar against the busiest period.
                    Repeater {
                        id: periods

                        readonly property real peak: {
                            let most = 0;
                            for (const period of (page.summary ? page.summary.periods : []))
                                most = Math.max(most, page.metric === "tokens" ? period.totalTokens : period.costUsd);
                            return most;
                        }

                        model: page.summary ? page.summary.periods : []

                        delegate: RowLayout {
                            required property var modelData

                            Layout.fillWidth: true
                            spacing: 8

                            Label {
                                Layout.preferredWidth: 64
                                text: modelData.label
                                color: page.muted
                                font.pixelSize: Math.round(11 * Theme.fontScale)
                            }

                            Item {
                                Layout.fillWidth: true
                                implicitHeight: 8

                                Rectangle {
                                    height: parent.height
                                    radius: 2
                                    width: periods.peak > 0 ? parent.width * (page.metric === "tokens" ? modelData.totalTokens : modelData.costUsd) / periods.peak : 0
                                    color: Theme.palette.color("accent", "#3b82f6")
                                }
                            }

                            Label {
                                Layout.preferredWidth: 72
                                horizontalAlignment: Text.AlignRight
                                text: page.amount(modelData)
                                color: page.foreground
                                font.pixelSize: Math.round(11 * Theme.fontScale)
                            }
                        }
                    }
                }
            }
        }
    }
    UsageModelPrices {
        anchors.fill: parent
    }

    Dialog {
        id: resetDialog

        property string key

        objectName: "resetDialog"
        parent: Overlay.overlay
        modal: true
        anchors.centerIn: parent
        scale: Shell.state.layout?.zoom ?? 1
        transformOrigin: Item.TopLeft
        width: Math.min(440, (parent?.width ?? 472) / scale - 32)
        padding: 20
        title: qsTr("Use a reset credit?")
        onAccepted: Shell.dispatch("usage.resetCredit", { key: key })

        background: Rectangle {
            color: Theme.palette.color("surfaceOverlay", "#18181b")
            border.color: Theme.palette.color("border", "#27272a")
            radius: Math.min(Theme.radius, 16)
        }
        header: Label {
            text: resetDialog.title
            padding: 20
            bottomPadding: 4
            font.pixelSize: Math.round(17 * Theme.fontScale)
            font.weight: Font.DemiBold
            color: page.foreground
        }
        contentItem: ColumnLayout {
            spacing: 12

            Label {
                Layout.fillWidth: true
                text: qsTr("This redeems one credit on your account and clears the current rate-limit windows. It cannot be undone.")
                color: page.muted
                font.pixelSize: Math.round(13 * Theme.fontScale)
                wrapMode: Text.Wrap
            }

            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Item { Layout.fillWidth: true }

                ShellButton {
                    objectName: "cancel"
                    subtle: true
                    text: qsTr("Cancel")
                    onClicked: resetDialog.reject()
                }

                ShellButton {
                    objectName: "confirm"
                    primary: true
                    text: qsTr("Use credit")
                    onClicked: resetDialog.accept()
                }
            }
        }
    }
}
