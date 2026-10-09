import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

Item {
    id: root
    width: 400
    height: 600
    Component { id: component; SettingsNav { width: 300; height: 550 } }
    TestCase {
        name: "SettingsNavTests"
        when: windowShown
        function init() { Shell.reset(); Shell.state = { route: { kind: "settings", section: "/settings/general" } }; }
        function cleanup() { Shell.reset(); Keybindings.bindings = []; Settings.clear(); Themes.clear(); }
        function test_keyboardNavigation() {
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            let row = findChild(nav, "settingsRow0");
            verify(!!row, "Object exists");
            row.focus = true;
            row.forceActiveFocus();
            keyClick(Qt.Key_Down);
            keyClick(Qt.Key_Down);
            keyClick(Qt.Key_Down);
            keyClick(Qt.Key_Return);
            compare(Shell.dispatchedActions[0].action, "settings.navigate");
            compare(Shell.dispatchedActions[0].payload.to, "/settings/snap-shot");
            keyClick(Qt.Key_Up);
            keyClick(Qt.Key_Up);
            keyClick(Qt.Key_Up);
            keyClick(Qt.Key_Space);
            compare(Shell.dispatchedActions[1].payload.to, "/settings/general");
        }
        function test_clusterRowOpensCluster() {
            Shell.state = { cluster: {} };
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            tryVerify(() => findChild(nav, "settingsRow4") !== null, 1000, "General, Appearance, Keybindings, SnapShots and Cluster are listed");
            let row = findChild(nav, "settingsRow4");
            compare(row.Accessible.name, "Cluster");
            row.forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(Shell.dispatchedActions[0].action, "cluster.open");
        }
        function test_clusterRowTakesCurrentFromTheRoute() {
            Shell.state = Object.assign({}, Shell.state, { cluster: {}, route: { kind: "settings", section: "/settings/cluster" } });
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            tryVerify(() => findChild(nav, "settingsRow4") !== null, 1000, "Cluster follows the other sections");
            verify(!findChild(nav, "settingsRow0").current, "General is not current");
            verify(findChild(nav, "settingsRow4").current, "Cluster is current");
        }
        function test_routeSectionIsCurrent() {
            Shell.state = Object.assign({}, Shell.state, { route: { kind: "settings", section: "/settings/snap-shot" } });
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            tryVerify(() => findChild(nav, "settingsRow3") !== null, 1000, "the sections are listed");
            verify(!findChild(nav, "settingsRow0").current, "General is not current");
            verify(findChild(nav, "settingsRow3").current, "the route's section is current");
        }
        function test_searchFindsCluster() {
            Shell.state = { cluster: {} };
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            let search = findChild(nav, "search");
            search.forceActiveFocus();
            keyClick(Qt.Key_I); keyClick(Qt.Key_N); keyClick(Qt.Key_V);
            tryVerify(() => findChild(nav, "settingsRow0") !== null && findChild(nav, "settingsRow0").Accessible.name === "Cluster", 1000, "inv finds Cluster");
            search.text = "theme";
            tryVerify(() => findChild(nav, "settingsRow1") !== null && findChild(nav, "settingsRow1").Accessible.name === "Appearance", 1000, "Appearance matches, Cluster does not");
            verify(!findChild(nav, "settingsRow2"), "Cluster does not match");
        }
        function test_nativePagesWithoutThePage() {
            Shell.state = {};
            let nav = createTemporaryObject(component, root);
            tryVerify(() => findChild(nav, "settingsRow1") !== null, 1000, "General and Appearance are listed");
            let row = findChild(nav, "settingsRow1");
            compare(row.Accessible.name, "Appearance");
            row.forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(Shell.dispatchedActions[0].action, "settings.navigate");
            compare(Shell.dispatchedActions[0].payload.to, "/settings/appearance");
            verify(findChild(nav, "settingsRow0").current, "a bare settings route shows General");
        }
        function test_connectionsRowOpensConnections() {
            Shell.state = { connections: {}, route: { kind: "settings", section: "/settings/connections" } };
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            tryVerify(() => findChild(nav, "settingsRow4") !== null, 1000, "Connections is listed");
            verify(!findChild(nav, "settingsRow5"), "Connections is listed once");
            let row = findChild(nav, "settingsRow4");
            compare(row.Accessible.name, "Connections");
            verify(row.current, "Connections is current");
            row.forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(Shell.dispatchedActions[0].action, "connections.open");
        }
        function test_keybindingsRowOpensKeybindings() {
            Shell.state = { route: { kind: "settings", section: "/settings/keybindings" } };
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            tryVerify(() => findChild(nav, "settingsRow3") !== null, 1000, "General, Appearance, Keybindings and SnapShots are listed");
            verify(!findChild(nav, "settingsRow4"), "Keybindings is listed once");
            let row = findChild(nav, "settingsRow2");
            compare(row.Accessible.name, "Keybindings");
            verify(row.current, "Keybindings is current");
            row.forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(Shell.dispatchedActions[0].action, "keybindings.open");
        }
        function test_keyboardSearchResult() {
            let nav = createTemporaryObject(component, root);
            type(nav, "theme");
            tryVerify(() => row(nav, 0) !== null && row(nav, 0).isResult);
            row(nav, 0).forceActiveFocus();
            keyClick(Qt.Key_Space);
            compare(Shell.dispatchedActions[0].action, "settings.openResult");
            compare(Shell.dispatchedActions[0].payload.targetId, "themes");
        }

        // features/settings/search-and-navigation.feature, on the native settings.
        function type(nav, text) {
            const search = findChild(nav, "search");
            search.forceActiveFocus();
            for (const ch of text) keyClick(ch === " " ? Qt.Key_Space : ch.toUpperCase().charCodeAt(0));
            return search;
        }
        function row(nav, index) {
            return findChild(nav, "settingsRow" + index);
        }
        function test_choosingASectionOpensIt() {
            Shell.state = { providerSettings: {}, route: { kind: "settings", section: "/settings/general" } };
            const nav = createTemporaryObject(component, root);
            tryVerify(() => row(nav, 4) !== null && row(nav, 4).Accessible.name === "Providers");
            mouseClick(row(nav, 4));
            compare(Shell.dispatchedActions[0].action, "settings.navigate");
            compare(Shell.dispatchedActions[0].payload.to, "/settings/providers");
            Shell.state = { providerSettings: {}, route: { kind: "settings", section: "/settings/providers" } };
            verify(row(nav, 4).current, "Providers is the current section");
            verify(!row(nav, 0).current);
        }
        function test_theKeyboardMovesThroughSections() {
            Shell.state = {};
            const nav = createTemporaryObject(component, root);
            tryVerify(() => row(nav, 0) !== null);
            row(nav, 0).forceActiveFocus();
            keyClick(Qt.Key_Down);
            keyClick(Qt.Key_Return);
            compare(Shell.dispatchedActions[0].payload.to, "/settings/appearance");
        }
        function test_aSearchResultOpensTheSettingInItsSection() {
            Shell.state = {};
            const nav = createTemporaryObject(component, root);
            type(nav, "theme");
            tryVerify(() => row(nav, 0) !== null && row(nav, 0).Accessible.name === "Theme");
            compare(row(nav, 0).modelData.sectionLabel, "Appearance");
            mouseClick(row(nav, 0));
            const opened = Shell.dispatchedActions.find(action => action.action === "settings.openResult");
            compare(opened.payload.to, "/settings/appearance");
            compare(opened.payload.targetId, "themes");
        }
        function test_everySearchWordMustMatchASetting() {
            Shell.state = {};
            const nav = createTemporaryObject(component, root);
            type(nav, "prompt font");
            tryVerify(() => row(nav, 0) !== null && row(nav, 0).Accessible.name === "Prompt font");
            compare(row(nav, 1).Accessible.name, "Prompt font size");
            verify(!row(nav, 2), "the other fonts do not match");
        }
        // Results are ranked by how well the title matches.
        function test_theBestMatchingTitleComesFirst() {
            Keybindings.bindings = [
                { command: "model.picker", label: "Model picker: Open", key: "mod+shift+m", defaultKey: "mod+shift+m" },
                { command: "sidebar.toggle", label: "Sidebar: Toggle", key: "mod+b", defaultKey: "mod+b" }
            ];
            Shell.state = { projectSettings: {} };
            const nav = createTemporaryObject(component, root);
            const search = type(nav, "model");
            tryVerify(() => row(nav, 0) !== null && row(nav, 0).Accessible.name === "Default model");
            compare(row(nav, 0).modelData.sectionLabel, "Project");
            let last = null;
            for (let index = 0; row(nav, index) !== null; ++index) last = row(nav, index);
            compare(last.Accessible.name, "Model picker: Open", "commands come after every setting");
            search.text = "mod+b";
            tryVerify(() => row(nav, 0) !== null && row(nav, 0).Accessible.name === "Sidebar: Toggle");
            mouseClick(row(nav, 0));
            compare(Shell.dispatchedActions[0].action, "settings.navigate");
            compare(Shell.dispatchedActions[0].payload.to, "/settings/keybindings");
        }
        function test_slashStartsASearch() {
            Shell.state = {};
            const nav = createTemporaryObject(component, root);
            tryVerify(() => row(nav, 0) !== null);
            row(nav, 0).forceActiveFocus();
            keyClick(Qt.Key_Slash);
            verify(findChild(nav, "search").activeFocus, "the search has the keyboard");
            compare(findChild(nav, "search").text, "", "the slash is not typed");
            keyClick(Qt.Key_Slash);
            compare(findChild(nav, "search").text, "/", "in the search a slash is typed");
        }
        function test_nothingMatchesTheSearch() {
            Shell.state = {};
            const nav = createTemporaryObject(component, root);
            type(nav, "zzzz");
            tryVerify(() => findChild(nav, "noMatches").visible);
            verify(!row(nav, 0));
        }
        function test_escapeClearsTheSearch() {
            Shell.state = {};
            const nav = createTemporaryObject(component, root);
            const search = type(nav, "model");
            tryVerify(() => row(nav, 0) !== null && row(nav, 0).isResult);
            keyClick(Qt.Key_Escape);
            compare(search.text, "");
            tryVerify(() => row(nav, 0) !== null && !row(nav, 0).isResult && row(nav, 0).Accessible.name === "General");
        }
    
        // Restoring defaults (the web's useSettingsRestore).
        function changeThemeAndTimeFormat() {
            Settings.defaults = { timestampFormat: "locale" };
            Settings.device = { timestampFormat: "24-hour" };
            Themes.themeId = "grove";
        }
        function askToRestore(nav) {
            const button = findChild(nav, "restoreDefaults");
            verify(button.enabled, "something differs from its default");
            mouseClick(button);
            const dialog = findChild(nav, "restoreDialog");
            tryVerify(() => dialog.opened);
            return dialog;
        }
        function test_restoringDefaultsListsWhatWillChangeAndAsksFirst() {
            changeThemeAndTimeFormat();
            const nav = createTemporaryObject(component, root);
            askToRestore(nav);
            compare(findChild(nav, "restoreList").text, "This will reset: Theme, Time format.");
            compare(Themes.themeId, "grove", "nothing changes before the user confirms");
        }
        function test_confirmingTheRestoreResetsTheListedSettings() {
            changeThemeAndTimeFormat();
            const nav = createTemporaryObject(component, root);
            const dialog = askToRestore(nav);
            mouseClick(findChild(dialog.contentItem, "confirm"));
            compare(Themes.themeId, "");
            compare(Settings.setting("timestampFormat"), "locale");
            verify(!findChild(nav, "restoreDefaults").enabled, "nothing is left to restore");
        }
        function test_cancellingTheRestoreChangesNothing() {
            changeThemeAndTimeFormat();
            const nav = createTemporaryObject(component, root);
            const dialog = askToRestore(nav);
            mouseClick(findChild(dialog.contentItem, "cancel"));
            tryVerify(() => !dialog.visible);
            compare(Themes.themeId, "grove");
            compare(Settings.setting("timestampFormat"), "24-hour");
        }
        function test_aThemeThatCannotBeRestoredKeepsEverything() {
            changeThemeAndTimeFormat();
            Themes.failSaves = true;
            const nav = createTemporaryObject(component, root);
            const dialog = askToRestore(nav);
            mouseClick(findChild(dialog.contentItem, "confirm"));
            compare(Themes.calls.map(call => call.name), ["restoreDefaults"]);
            compare(Themes.themeId, "grove");
            compare(Settings.setting("timestampFormat"), "24-hour", "the other settings wait for the theme");
        }
        function test_tabReachesTheSectionListAtTheCurrentSection() {
            Shell.state = { route: { kind: "settings", section: "/settings/appearance" } };
            const nav = createTemporaryObject(component, root);
            tryVerify(() => row(nav, 1) !== null);
            findChild(nav, "search").forceActiveFocus();
            keyClick(Qt.Key_Tab);
            const list = row(nav, 0).ListView.view;
            verify(list.activeFocus, "the list is a Tab stop after the search field");
            compare(list.currentIndex, 1, "the cursor starts on the section showing");
            keyClick(Qt.Key_Down);
            keyClick(Qt.Key_Return);
            compare(Shell.dispatchedActions[0].action, "keybindings.open");
        }
        function test_downFromTheSearchFieldEntersTheList() {
            Shell.state = {};
            const nav = createTemporaryObject(component, root);
            tryVerify(() => row(nav, 0) !== null);
            findChild(nav, "search").forceActiveFocus();
            keyClick(Qt.Key_Down);
            verify(row(nav, 0).ListView.view.activeFocus);
        }
        function test_escapeLeavesSettingsFromAnyRowAndClearsTheSearchFirst() {
            Shell.state = {};
            const nav = createTemporaryObject(component, root);
            tryVerify(() => row(nav, 0) !== null);
            row(nav, 0).forceActiveFocus();
            keyClick(Qt.Key_Escape);
            compare(Shell.dispatchedActions[0].action, "settings.back");
            const search = type(nav, "theme");
            keyClick(Qt.Key_Escape);
            compare(search.text, "");
            compare(Shell.dispatchedActions.length, 1, "the first Escape only clears the search");
            keyClick(Qt.Key_Escape);
            compare(Shell.dispatchedActions.length, 2);
        }
    }
}
