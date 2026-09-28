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
                sections: [{ to: "/settings/general", label: "General" }, { to: "/settings/providers", label: "Providers" }],
                searchResults: [{ to: "/settings/providers", title: "Theme", sectionLabel: "Providers", targetId: "theme" }]
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
            keyClick(Qt.Key_Return);
            compare(Shell.dispatchedActions[0].action, "settings.navigate");
            compare(Shell.dispatchedActions[0].payload.to, "/settings/providers");
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
            tryVerify(() => findChild(nav, "settingsRow2") !== null, 1000, "General, Appearance and Cluster are listed");
            let row = findChild(nav, "settingsRow2");
            compare(row.Accessible.name, "Cluster");
            row.forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(Shell.dispatchedActions[0].action, "cluster.open");
        }
        function test_clusterRowTakesCurrentFromTheRoute() {
            Shell.state = Object.assign({}, Shell.state, { cluster: {}, route: { kind: "settings", section: "/settings/cluster" } });
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            tryVerify(() => findChild(nav, "settingsRow3") !== null, 1000, "Cluster follows the page's sections");
            verify(!findChild(nav, "settingsRow0").current, "the page's section is not current");
            verify(findChild(nav, "settingsRow3").current, "Cluster is current");
        }
        function test_routeSectionIsCurrent() {
            Shell.state = Object.assign({}, Shell.state, { route: { kind: "settings", section: "/settings/providers" } });
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            tryVerify(() => findChild(nav, "settingsRow2") !== null, 1000, "the page's sections are listed");
            verify(!findChild(nav, "settingsRow0").current, "the page's last section is not current");
            verify(findChild(nav, "settingsRow2").current, "the route's section is current");
        }
        function test_searchFindsCluster() {
            Shell.state = { cluster: {} };
            let nav = createTemporaryObject(component, root);
            verify(!!nav, "Component exists");
            let search = findChild(nav, "search");
            search.forceActiveFocus();
            keyClick(Qt.Key_M); keyClick(Qt.Key_A); keyClick(Qt.Key_C);
            tryVerify(() => findChild(nav, "settingsRow0") !== null && findChild(nav, "settingsRow0").Accessible.name === "Cluster", 1000, "mac finds Cluster");
            search.text = "theme";
            tryVerify(() => findChild(nav, "settingsRow0") !== null && findChild(nav, "settingsRow0").Accessible.name === "Appearance", 1000, "Appearance matches, Cluster does not");
            verify(!findChild(nav, "settingsRow1"), "Cluster does not match");
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
            tryVerify(() => findChild(nav, "settingsRow3") !== null, 1000, "Connections is listed");
            verify(!findChild(nav, "settingsRow4"), "the page's own Connections section is not");
            let row = findChild(nav, "settingsRow3");
            compare(row.Accessible.name, "Connections");
            verify(row.current, "Connections is current");
            row.forceActiveFocus();
            keyClick(Qt.Key_Return);
            compare(Shell.dispatchedActions[0].action, "connections.open");
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
    }
}
