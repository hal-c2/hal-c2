pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtWebEngine
import HalC2.Shell
import "js/browser.js" as BrowserJs

// One browser tab of the right panel (`browser:<tab>`): the MC's tab of a
// thread's previews (Panel.previews), drawn by QtWebEngine. A BrowserPage follows the
// MC's tab and tells it what the page does; the view loads what the MC asks
// for (an agent's navigate) and what the user types.
//
// The page is drawn at the screen's own pixels: the app's zoom is undone
// around it (`stage`), so only the tab's zoom zooms the page. At a device
// size the page renders at that size, centred and scaled down to fit.
//
//   BrowserPanel { anchors.fill: parent; source: Panel.previews; tabId: "browser:tab-1" }
Rectangle {
    id: root

    property var source: null
    property string tabId: ""

    readonly property color foreground: Theme.palette.color("text", "#e4e4e7")
    readonly property color muted: Theme.palette.color("textMuted", "#8b8b93")
    readonly property color errorColor: Theme.palette.color("error", "#ef4444")
    readonly property color edge: Theme.palette.color("border", "#27272a")
    // The window's zoom, undone around the page.
    readonly property real appZoom: Shell.state.layout ? (Shell.state.layout.zoom ?? 1) : 1
    readonly property var viewport: page.viewport
    readonly property bool framed: viewport._tag === "preset" || viewport._tag === "freeform"
    readonly property var device: viewport._tag === "preset" ? BrowserJs.preset(viewport.presetId) : null
    // Where the page is, as the view has it; empty for the start page. A
    // page's source (view-source:) shows here only: the MC's tab stays on the page.
    readonly property string address: /^(view-source:)?https?:/.test(webView.url.toString()) ? webView.url.toString() : ""
    // The page itself, with or without its source showing.
    readonly property string webAddress: address.replace(/^view-source:/, "")
    // Why the last load failed ({name, message}), until the next one starts.
    property var failure: null
    property url failedUrl
    // The address field's complaint about what was typed.
    property string addressProblem: ""

    objectName: "browserPanel"
    color: Theme.palette.color("surface", "#0f0f11")

    BrowserPage {
        id: page

        previews: root.source
        tabId: root.tabId.slice(root.tabId.indexOf(":") + 1)
        view: webView

        onLoadRequested: url => root.go(url, false)
        // Given its tab after it was made (PanelBodies): the view starts where the tab is.
        onTabIdChanged: if (url.length > 0 && webView.url.toString() !== url)
            webView.url = url
        onEvaluateRequested: (request, script, world) => webView.runJavaScript(script, world, result => page.evaluated(request, result))
        onGrabRequested: request => {
            const grabbed = webView.grabToImage(result => page.grabbed(request, result.image));
            if (!grabbed)
                page.grabbed(request, undefined);
        }
        onCommandRequested: command => {
            switch (command) {
            case "preview.refresh":
                root.reload();
                break;
            case "preview.focusUrl":
                addressField.forceActiveFocus();
                addressField.selectAll();
                break;
            case "preview.zoomIn":
                page.zoom = BrowserJs.stepZoom(page.zoom, 1);
                break;
            case "preview.zoomOut":
                page.zoom = BrowserJs.stepZoom(page.zoom, -1);
                break;
            case "preview.resetZoom":
                page.zoom = 1;
                break;
            }
        }
    }

    // Opens `url` (already a web address); `tell` says the MC has not heard.
    function go(url, tell) {
        if (tell)
            page.navigate(url);
        webView.url = url;
    }

    function openTyped(text) {
        const source = /^\s*view-source:/i.test(text);
        const normalized = BrowserJs.normalizeAddress(source ? text.trim().slice(12) : text);
        if (normalized.error) {
            addressProblem = normalized.error;
            return;
        }
        addressProblem = "";
        if (source)
            go("view-source:" + normalized.url, false);
        else
            go(normalized.url, true);
        webView.forceActiveFocus();
    }

    function reload() {
        if (root.failure !== null && root.failedUrl.toString().length > 0)
            webView.url = root.failedUrl;
        else
            webView.reload();
    }

    // The load of `url` failed with Chromium's net error `code` (-102 for
    // ERR_CONNECTION_REFUSED): said in place, and to the MC.
    function failed(code, description, url) {
        root.failure = BrowserJs.describeError(code, description);
        root.failedUrl = url;
        report("failed", code, description);
    }

    function report(phase, code, description) {
        page.report(phase, webView.url.toString(), webView.title, code, description, webView.canGoBack, webView.canGoForward);
    }

    function applyAppearance() {
        webView.userScripts.clear();
        if (page.appearance !== "system") {
            const script = WebEngine.script();
            script.name = "hal-c2-appearance";
            script.sourceCode = BrowserJs.appearanceScript(page.appearance);
            script.injectionPoint = WebEngineScript.DocumentCreation;
            script.worldId = WebEngineScript.MainWorld;
            script.runsOnSubFrames = true;
            webView.userScripts.insert(script);
        }
    }

    Connections {
        target: page
        // Not a binding: the view's zoom is set again on each load.
        function onZoomChanged() {
            webView.zoomFactor = page.zoom;
        }
        function onAppearanceChanged() {
            root.applyAppearance();
            if (root.address.length > 0)
                webView.reload();
        }
    }

    // --- The chrome ----------------------------------------------------------------

    Item {
        id: chrome

        width: parent.width
        height: 40

        Row {
            id: navigation

            anchors.left: parent.left
            anchors.leftMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            ShellButton {
                objectName: "browserBack"
                subtle: true
                iconName: "arrow-left"
                // Chromium shows a page's source in place of the page, so
                // back from it is the page again.
                enabled: webView.canGoBack || root.address !== root.webAddress
                Accessible.name: qsTr("Back")
                onClicked: root.address !== root.webAddress ? root.go(root.webAddress, false) : webView.goBack()
            }

            ShellButton {
                objectName: "browserForward"
                subtle: true
                iconName: "arrow-right"
                enabled: webView.canGoForward
                Accessible.name: qsTr("Forward")
                onClicked: webView.goForward()
            }

            ShellButton {
                objectName: "browserReload"
                subtle: true
                iconName: webView.loading ? "x" : "rotate-cw"
                enabled: root.address.length > 0 || root.failure !== null
                Accessible.name: webView.loading ? qsTr("Stop") : qsTr("Reload")
                onClicked: webView.loading ? webView.stop() : root.reload()
            }
        }

        ShellTextField {
            id: addressField

            objectName: "browserAddress"
            anchors.left: navigation.right
            anchors.leftMargin: 6
            anchors.right: tools.left
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            implicitHeight: 28
            leftPadding: 30
            placeholderText: qsTr("Search or enter an address")
            Accessible.name: qsTr("Address")
            selectByMouse: true
            // Whether the field holds what the user is typing, not the page's address.
            property bool typing: false
            onTextEdited: {
                typing = true;
                root.addressProblem = "";
            }
            onActiveFocusChanged: {
                if (activeFocus)
                    Qt.callLater(selectAll);
                else
                    typing = false;
            }
            onAccepted: {
                // Read before the page's address comes back in.
                const typed = text;
                typing = false;
                root.openTyped(typed);
            }
            Keys.onEscapePressed: {
                typing = false;
                text = root.address;
                root.addressProblem = "";
                webView.forceActiveFocus();
            }
            ToolTip.visible: root.addressProblem.length > 0 && activeFocus
            ToolTip.text: root.addressProblem

            Binding on text {
                when: !addressField.typing
                value: root.address
                restoreMode: Binding.RestoreNone
            }

            ShellIcon {
                x: 10
                anchors.verticalCenter: parent.verticalCenter
                size: 13
                name: root.address.startsWith("https://") ? "lock" : "globe"
                color: root.muted
            }
        }

        Row {
            id: tools

            anchors.right: parent.right
            anchors.rightMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            // The page plays sound, or would: a click mutes or unmutes it.
            ShellButton {
                objectName: "browserMute"
                visible: page.muted || webView.recentlyAudible
                subtle: true
                iconName: page.muted ? "volume-x" : "volume-2"
                Accessible.name: page.muted ? qsTr("Unmute tab") : qsTr("Mute tab")
                onClicked: page.muted = !page.muted
            }

            ShellButton {
                objectName: "browserZoomReset"
                visible: Math.abs(page.zoom - 1) > 0.001
                subtle: true
                text: BrowserJs.zoomLabel(page.zoom)
                toolTip: qsTr("Reset zoom")
                onClicked: page.zoom = 1
            }

            ShellButton {
                id: deviceButton

                objectName: "browserDevice"
                subtle: true
                checked: root.framed
                iconName: root.device?.kind === "tablet" ? "tablet" : root.framed ? "smartphone" : "monitor-smartphone"
                Accessible.name: qsTr("Device size")
                onClicked: deviceMenu.popup(deviceButton, 0, deviceButton.height)
            }

            ShellButton {
                id: devicesButton

                objectName: "browserDevices"
                subtle: true
                checked: Browser.devicesView
                iconName: "layout-grid"
                Accessible.name: Browser.devicesView ? qsTr("Close Devices view") : qsTr("Devices view")
                onClicked: Browser.devicesView = !Browser.devicesView
            }

            ShellButton {
                id: devicesPickButton

                objectName: "browserDevicesPick"
                visible: Browser.devicesView
                subtle: true
                iconName: "sliders-horizontal"
                Accessible.name: qsTr("Choose devices")
                onClicked: devicesPicker.visible ? devicesPicker.close() : devicesPicker.open()

                DevicesPicker {
                    id: devicesPicker

                    objectName: "browserDevicesPicker"
                    x: devicesPickButton.width - width
                    y: devicesPickButton.height + 4
                }
            }

            ShellButton {
                objectName: "browserDevTools"
                subtle: true
                checked: page.devTools
                iconName: "code-xml"
                enabled: root.address.length > 0
                Accessible.name: page.devTools ? qsTr("Close DevTools") : qsTr("Open DevTools")
                onClicked: page.devTools = !page.devTools
            }

            ShellButton {
                id: moreButton

                objectName: "browserMore"
                subtle: true
                iconName: "ellipsis"
                Accessible.name: qsTr("More")
                onClicked: moreMenu.popup(moreButton, 0, moreButton.height)
            }
        }

        // How far the load is; nothing draws while the page is still.
        Rectangle {
            objectName: "browserProgress"
            anchors.bottom: parent.bottom
            height: 2
            width: parent.width * webView.loadProgress / 100
            visible: webView.loading
            color: Theme.palette.color("accent", "#2563eb")
        }

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 1
            visible: !webView.loading
            color: root.edge
        }
    }

    ShellMenu {
        id: deviceMenu

        ShellMenuItem {
            text: qsTr("Fill the panel")
            iconName: "monitor"
            current: !root.framed
            onTriggered: page.setViewport(BrowserJs.viewportOf("fill"))
        }

        ShellMenuSeparator {}

        Repeater {
            model: BrowserJs.presets

            delegate: ShellMenuItem {
                required property var modelData

                objectName: "browserPreset-" + modelData.id
                text: modelData.label
                detail: modelData.width + " × " + modelData.height
                iconName: modelData.kind === "tablet" ? "tablet" : "smartphone"
                current: root.viewport.presetId === modelData.id
                onTriggered: page.setViewport(BrowserJs.viewportOf(modelData.id))
            }
        }

        ShellMenuSeparator {}

        ShellMenuItem {
            text: BrowserJs.desktop.label
            detail: BrowserJs.desktop.width + " × " + BrowserJs.desktop.height
            iconName: "monitor"
            current: root.viewport._tag === "freeform" && root.viewport.width === BrowserJs.desktop.width && root.viewport.height === BrowserJs.desktop.height
            onTriggered: page.setViewport(BrowserJs.viewportOf("desktop"))
        }
    }

    ShellMenu {
        id: moreMenu

        ShellMenuItem {
            text: qsTr("Zoom in")
            iconName: "zoom-in"
            detail: BrowserJs.zoomLabel(page.zoom)
            enabled: page.zoom < BrowserJs.zoomSteps[BrowserJs.zoomSteps.length - 1]
            onTriggered: page.zoom = BrowserJs.stepZoom(page.zoom, 1)
        }

        ShellMenuItem {
            text: qsTr("Zoom out")
            iconName: "zoom-out"
            enabled: page.zoom > BrowserJs.zoomSteps[0]
            onTriggered: page.zoom = BrowserJs.stepZoom(page.zoom, -1)
        }

        ShellMenuItem {
            text: qsTr("Actual size")
            enabled: Math.abs(page.zoom - 1) > 0.001
            onTriggered: page.zoom = 1
        }

        ShellMenuSeparator {}

        ShellMenuItem {
            text: qsTr("Match the system's appearance")
            iconName: "sun-moon"
            current: page.appearance === "system"
            onTriggered: page.appearance = "system"
        }

        ShellMenuItem {
            text: qsTr("Light appearance")
            iconName: "sun"
            current: page.appearance === "light"
            onTriggered: page.appearance = "light"
        }

        ShellMenuItem {
            text: qsTr("Dark appearance")
            iconName: "moon"
            current: page.appearance === "dark"
            onTriggered: page.appearance = "dark"
        }

        ShellMenuSeparator {}

        ShellMenuItem {
            objectName: "browserMuteItem"
            text: page.muted ? qsTr("Unmute tab") : qsTr("Mute tab")
            iconName: page.muted ? "volume-2" : "volume-x"
            onTriggered: page.muted = !page.muted
        }

        ShellMenuItem {
            objectName: "browserDevToolsDock"
            text: Browser.devToolsDock === "right" ? qsTr("Dock DevTools at the bottom") : qsTr("Dock DevTools to the right")
            iconName: Browser.devToolsDock === "right" ? "panel-bottom" : "panel-right"
            onTriggered: {
                Browser.devToolsDock = Browser.devToolsDock === "right" ? "bottom" : "right";
                page.devTools = true;
            }
        }

        ShellMenuItem {
            objectName: "browserOpenExternal"
            text: qsTr("Open in system browser")
            iconName: "external-link"
            enabled: root.address.length > 0
            onTriggered: Shell.openExternal(root.webAddress)
        }
    }

    // --- The page ------------------------------------------------------------------

    Item {
        id: area

        anchors.top: chrome.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        // Hidden, not torn down, while the Devices view shows: the page
        // underneath keeps following the MC's tab and reporting to it.
        visible: !Browser.devicesView
        clip: true

        // The page's own pixels: the app's zoom undone.
        Item {
            id: stage

            objectName: "browserPage"
            width: area.width * root.appZoom
            height: area.height * root.appZoom
            scale: 1 / root.appZoom
            transformOrigin: Item.TopLeft

            readonly property bool docked: page.devTools && devTools.item !== null
            readonly property bool dockRight: Browser.devToolsDock === "right"
            // The share DevTools take while the divider is dragged, else the kept one.
            property real share: -1
            readonly property real devToolsShare: share >= 0 ? share : Browser.devToolsShare

            Item {
                id: pageArea

                width: stage.docked && stage.dockRight ? stage.width * (1 - stage.devToolsShare) : stage.width
                height: stage.docked && !stage.dockRight ? stage.height * (1 - stage.devToolsShare) : stage.height

                readonly property var shown: root.framed ? BrowserJs.fit(root.viewport.width, root.viewport.height, width, height - (root.framed ? 24 : 0), 16) : null

                // What a device size sits on.
                Rectangle {
                    anchors.fill: parent
                    visible: root.framed
                    color: Theme.palette.color("canvas", "#09090b")
                }

                // The device's edge, under the page.
                Rectangle {
                    visible: root.framed
                    x: webView.x - 1
                    y: webView.y - 1
                    width: webView.width * webView.scale + 2
                    height: webView.height * webView.scale + 2
                    color: "transparent"
                    border.color: root.edge
                    radius: 2
                }

                WebEngineView {
                    id: webView

                    objectName: "browserView"
                    x: root.framed ? pageArea.shown?.x ?? 0 : 0
                    y: root.framed ? pageArea.shown?.y ?? 0 : 0
                    width: root.framed ? root.viewport.width : pageArea.width
                    height: root.framed ? root.viewport.height : pageArea.height
                    scale: root.framed ? pageArea.shown?.scale ?? 1 : 1
                    transformOrigin: Item.TopLeft
                    profile: Browser.profile ? Browser.profile : WebEngine.defaultProfile
                    audioMuted: page.muted
                    settings.errorPageEnabled: false
                    settings.focusOnNavigationEnabled: false

                    onLoadingChanged: info => {
                        switch (info.status) {
                        case WebEngineView.LoadStartedStatus:
                            root.failure = null;
                            root.report("loading", 0, "");
                            break;
                        case WebEngineView.LoadSucceededStatus:
                            // A page on another site starts at the default zoom.
                            webView.zoomFactor = page.zoom;
                            root.report("loaded", 0, "");
                            break;
                        case WebEngineView.LoadFailedStatus:
                            // ERR_ABORTED: the page started another load itself.
                            if (info.errorCode === -3)
                                break;
                            root.failed(info.errorCode, info.errorString, info.url);
                            break;
                        }
                    }
                    // A page moving itself (history.pushState) or naming itself.
                    onUrlChanged: if (!loading)
                        root.report("loaded", 0, "")
                    onTitleChanged: if (!loading)
                        root.report("loaded", 0, "")
                    onJavaScriptConsoleMessage: (level, message, lineNumber, sourceID) => page.consoleMessage(level, message, lineNumber, sourceID)
                    onNewWindowRequested: request => {
                        // A sign-in popup is a real window, so it can answer
                        // the page; a link to a new window stays in the tab.
                        const requested = request.requestedUrl.toString();
                        if (requested.startsWith("view-source:")) {
                            // The page's source: in this view, and the MC's tab stays on the page.
                            root.go(requested, false);
                        } else if (request.destination === WebEngineNewWindowRequest.InNewDialog) {
                            const popup = popupWindow.createObject(root, {
                                width: Math.max(320, request.requestedGeometry.width || 500),
                                height: Math.max(240, request.requestedGeometry.height || 600)
                            });
                            request.openIn(popup.view);
                            popup.show();
                        } else {
                            root.go(requested, true);
                        }
                    }
                    Component.onCompleted: {
                        webView.zoomFactor = page.zoom;
                        root.applyAppearance();
                        if (page.url.length > 0)
                            webView.url = page.url;
                    }
                }

                // What an agent does in the page (PreviewAutomation's activity).
                AgentCue {
                    x: webView.x
                    y: webView.y
                    width: webView.width * webView.scale
                    height: webView.height * webView.scale
                    entry: PreviewAutomation.activity[root.tabId] ?? null
                    pageScale: page.zoom * webView.scale
                    reduceMotion: PreviewAutomation.reduceMotion
                }

                Text {
                    objectName: "browserDeviceLabel"
                    visible: root.framed
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: webView.y + webView.height * webView.scale + 6
                    text: (root.device ? root.device.label : qsTr("Custom")) + " · " + root.viewport.width + " × " + root.viewport.height + (webView.scale < 0.995 ? " · " + Math.round(webView.scale * 100) + "%" : "")
                    color: root.muted
                    font.pixelSize: Math.round(11 * Theme.fontScale * root.appZoom)
                }
            }

            // Drags to share the page with DevTools.
            Rectangle {
                id: divider

                visible: stage.docked
                x: stage.dockRight ? pageArea.width : 0
                y: stage.dockRight ? 0 : pageArea.height
                width: stage.dockRight ? 1 : stage.width
                height: stage.dockRight ? stage.height : 1
                color: root.edge

                MouseArea {
                    anchors.centerIn: parent
                    width: stage.dockRight ? 8 : parent.width
                    height: stage.dockRight ? parent.height : 8
                    cursorShape: stage.dockRight ? Qt.SplitHCursor : Qt.SplitVCursor
                    onPositionChanged: mouse => {
                        const at = mapToItem(stage, mouse.x, mouse.y);
                        const share = stage.dockRight ? 1 - at.x / stage.width : 1 - at.y / stage.height;
                        stage.share = Math.max(0.2, Math.min(0.8, share));
                    }
                    onReleased: {
                        Browser.devToolsShare = stage.share;
                        stage.share = -1;
                    }
                }
            }

            // DevTools, made while open: a second page inspecting this one.
            Loader {
                id: devTools

                active: page.devTools
                x: stage.dockRight ? pageArea.width + 1 : 0
                y: stage.dockRight ? 0 : pageArea.height + 1
                width: stage.dockRight ? stage.width - pageArea.width - 1 : stage.width
                height: stage.dockRight ? stage.height : stage.height - pageArea.height - 1
                sourceComponent: WebEngineView {
                    objectName: "browserDevToolsView"
                    profile: webView.profile
                    backgroundColor: root.color
                }
                onItemChanged: webView.devToolsView = item
            }
        }

        // The start page: where the empty tab can go.
        Rectangle {
            objectName: "browserStart"
            anchors.fill: parent
            visible: root.address.length === 0 && root.failure === null && !webView.loading
            color: root.color

            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.min(parent.height * 0.18, 96)
                width: Math.min(parent.width - 48, 420)
                spacing: 6

                Text {
                    text: qsTr("Open a page")
                    color: root.foreground
                    font.pixelSize: Math.round(15 * Theme.fontScale)
                    font.weight: Font.DemiBold
                }

                Text {
                    width: parent.width
                    text: qsTr("Type an address above, or pick a server running on this machine.")
                    wrapMode: Text.Wrap
                    color: root.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                    bottomPadding: 8
                }

                Repeater {
                    model: root.source !== null && root.address.length === 0 ? root.source.suggestions : []

                    delegate: AbstractButton {
                        id: suggestion

                        required property var modelData
                        required property int index

                        objectName: "browserSuggestion-" + index
                        width: parent.width
                        implicitHeight: 32
                        leftPadding: 8
                        rightPadding: 8
                        hoverEnabled: true
                        text: modelData.url
                        Accessible.name: modelData.url

                        background: Rectangle {
                            radius: Math.min(Theme.radius, 8)
                            color: suggestion.hovered || suggestion.visualFocus ? Theme.palette.color("accentSurface", "#27272a") : "transparent"
                        }

                        contentItem: RowLayout {
                            spacing: 8

                            ShellIcon {
                                name: suggestion.modelData.kind === "server" ? "server" : suggestion.modelData.kind === "recent" ? "clock" : "globe"
                                size: 14
                                color: root.muted
                            }

                            Text {
                                Layout.fillWidth: true
                                text: suggestion.modelData.url
                                elide: Text.ElideMiddle
                                color: root.foreground
                                font.pixelSize: Math.round(13 * Theme.fontScale)
                            }

                            Text {
                                visible: text.length > 0
                                text: suggestion.modelData.label || ""
                                color: root.muted
                                font.pixelSize: Math.round(12 * Theme.fontScale)
                            }
                        }

                        onClicked: root.go(modelData.url, true)
                    }
                }

                Text {
                    visible: root.source === null || root.source.suggestions.length === 0
                    text: qsTr("No servers are running on this machine yet.")
                    color: root.muted
                    font.pixelSize: Math.round(12 * Theme.fontScale)
                }
            }
        }

        // Why the page could not load.
        Rectangle {
            objectName: "browserFailure"
            anchors.fill: parent
            visible: root.failure !== null
            color: root.color

            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                y: Math.min(parent.height * 0.18, 96)
                width: Math.min(parent.width - 48, 420)
                spacing: 8

                ShellIcon {
                    size: 28
                    name: "triangle-alert"
                    color: root.muted
                }

                Text {
                    text: qsTr("This site can't be reached")
                    color: root.foreground
                    font.pixelSize: Math.round(16 * Theme.fontScale)
                    font.weight: Font.DemiBold
                }

                Text {
                    objectName: "browserFailureMessage"
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: root.failure ? root.failure.message : ""
                    color: root.muted
                    font.pixelSize: Math.round(13 * Theme.fontScale)
                }

                Text {
                    width: parent.width
                    elide: Text.ElideMiddle
                    text: BrowserJs.hostOf(root.failedUrl.toString()) + (root.failure ? "  ·  " + root.failure.name : "")
                    color: root.muted
                    font.family: "monospace"
                    font.pixelSize: Math.round(11 * Theme.fontScale)
                    bottomPadding: 6
                }

                ShellButton {
                    objectName: "browserFailureReload"
                    primary: true
                    text: qsTr("Reload")
                    onClicked: root.reload()
                }
            }
        }
    }

    // The Devices view: made only while shown, so its frames exist only then.
    Loader {
        id: devicesViewLoader

        anchors.top: chrome.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        active: Browser.devicesView
        visible: Browser.devicesView
        sourceComponent: BrowserDevicesView {
            pageUrl: root.webAddress
            profile: webView.profile
            appearance: page.appearance
            presetIds: Browser.devicesPresetIds
            show3d: Browser.devices3d
        }
    }

    // A sign-in popup: its own window, which may not open another.
    Component {
        id: popupWindow

        Window {
            id: popup

            readonly property alias view: popupView

            title: popupView.title
            color: root.color

            WebEngineView {
                id: popupView

                objectName: "popupView"
                anchors.fill: parent
                profile: webView.profile
                // Left unopened, the request is refused.
                onNewWindowRequested: request => {}
                onWindowCloseRequested: popup.close()
            }

            onClosing: popup.destroy()
        }
    }
}
