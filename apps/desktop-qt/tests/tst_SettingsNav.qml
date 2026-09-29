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
        function publish(query) {
            Shell.state = { settings: {
                active: true, activeSection: "/settings/general", searchQuery: query,
                sections: [{ to: "/settings/general", label: "General" }, { to: "/settings/source-control", label: "Source Control" }],
                searchResults: [{ to: "/settings/source-control", title: "Theme", sectionLabel: "Source Control", targetId: "theme" }]
            } };
        }
        function init() { Shell.reset(); publish(""); }
        function cleanup() { Shell.reset(); }
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
            compare(Shell.dispatchedActions[0].payload.to, "/settings/source-control");
            keyClick(Qt.Key_Up);
            keyClick(Qt.Key_Up);
            keyClick(Qt.Key_Up);
            keyClick(Qt.Key_Space);
            compare(Shell.dispatchedActions[1].payload.to, "/settings/general");
        }
        function test_escapeKeepsExternalSearchBinding() {
            publish("theme");
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            let search = findChild(nav, "search");
            verify(!!search, "Object exists");
            search.focus = true;
            search.forceActiveFocus();
            keyClick(Qt.Key_Escape);
            compare(Shell.dispatchedActions[0].payload.query, "");
            publish("");
            compare(search.text, "");
            publish("model 123 & provider");
            compare(search.text, "model 123 & provider");
        }
        function test_clusterRowWithoutThePage() {
            Shell.state = { cluster: {} };
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            tryVerify(() => findChild(nav, "settingsRow3") !== null, 1000, "General, Appearance, Keybindings and Cluster are listed");
            let row = findChild(nav, "settingsRow3");
            compare(row.Accessible.name, "Cluster");
            row.forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(Shell.dispatchedActions[0].action, "cluster.open");
        }
        function test_clusterRowTakesCurrentFromTheRoute() {
            Shell.state = Object.assign({}, Shell.state, { cluster: {}, route: { kind: "settings", section: "/settings/cluster" } });
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            tryVerify(() => findChild(nav, "settingsRow4") !== null, 1000, "Cluster follows the page's sections");
            verify(!findChild(nav, "settingsRow0").current, "the page's section is not current");
            verify(findChild(nav, "settingsRow4").current, "Cluster is current");
        }
        function test_routeSectionIsCurrent() {
            Shell.state = Object.assign({}, Shell.state, { route: { kind: "settings", section: "/settings/source-control" } });
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            tryVerify(() => findChild(nav, "settingsRow3") !== null, 1000, "the page's sections are listed");
            verify(!findChild(nav, "settingsRow0").current, "the page's last section is not current");
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
        function test_connectionsRowTakesThePageSectionsPlace() {
            let settings = Shell.state.settings;
            settings.sections = settings.sections.concat([{ to: "/settings/connections", label: "Connections" }]);
            Shell.state = { settings: settings, connections: {}, route: { kind: "settings", section: "/settings/connections" } };
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            tryVerify(() => findChild(nav, "settingsRow4") !== null, 1000, "Connections is listed");
            verify(!findChild(nav, "settingsRow5"), "the page's own Connections section is not");
            let row = findChild(nav, "settingsRow4");
            compare(row.Accessible.name, "Connections");
            verify(row.current, "Connections is current");
            row.forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(Shell.dispatchedActions[0].action, "connections.open");
        }
        function test_keybindingsRowTakesThePageSectionsPlace() {
            let settings = Shell.state.settings;
            settings.sections = settings.sections.concat([{ to: "/settings/keybindings", label: "Keybindings" }]);
            Shell.state = { settings: settings, route: { kind: "settings", section: "/settings/keybindings" } };
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            tryVerify(() => findChild(nav, "settingsRow3") !== null, 1000, "General, Appearance, Keybindings and Source Control are listed");
            verify(!findChild(nav, "settingsRow4"), "the page's own Keybindings section is not");
            let row = findChild(nav, "settingsRow2");
            compare(row.Accessible.name, "Keybindings");
            verify(row.current, "Keybindings is current");
            row.forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(Shell.dispatchedActions[0].action, "keybindings.open");
        }
        function test_keyboardSearchResult() {
            publish("theme");
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            let row = findChild(nav, "settingsRow0");
            verify(!!row, "Object exists");
            row.focus = true;
            row.forceActiveFocus();
            keyClick(Qt.Key_Space);
            compare(Shell.dispatchedActions[0].action, "settings.openResult");
            compare(Shell.dispatchedActions[0].payload.targetId, "theme");
        }

        // features/settings/search-and-navigation.feature, without the page.
        function type(nav, text) {
            const search = findChild(nav, "search");
            search.forceActiveFocus();
            for (const char of text) keyClick(char === " " ? Qt.Key_Space : char.toUpperCase().charCodeAt(0));
            return search;
        }
        function row(nav, index) {
            return findChild(nav, "settingsRow" + index);
        }
        function test_choosingASectionOpensIt() {
            Shell.state = { providerSettings: {}, route: { kind: "settings", section: "/settings/general" } };
            const nav = createTemporaryObject(component, root);
            tryVerify(() => row(nav, 3) !== null && row(nav, 3).Accessible.name === "Providers");
            mouseClick(row(nav, 3));
            compare(Shell.dispatchedActions[0].action, "settings.navigate");
            compare(Shell.dispatchedActions[0].payload.to, "/settings/providers");
            Shell.state = { providerSettings: {}, route: { kind: "settings", section: "/settings/providers" } };
            verify(row(nav, 3).current, "Providers is the current section");
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
            tryVerify(() => row(nav, 0) !== null && row(nav, 0).Accessible.name === "Prompt font size");
            compare(row(nav, 1).Accessible.name, "Prompt font");
            verify(!row(nav, 2), "the other fonts do not match");
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
    }
}
