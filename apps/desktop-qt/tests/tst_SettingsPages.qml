import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import "../qml/HalC2/Bricks/js/settingsPages.js" as Pages
import "../qml/HalC2/Bricks/js/settingsRows.js" as Rows
import HalC2.Shell

Item {
    id: root
    width: 800
    height: 700

    Component {
        id: hostComponent
        SettingsHost {
            width: 700
            height: 600
        }
    }
    Component {
        id: rowComponent
        SettingsRow {
            width: 600
        }
    }
    Component {
        id: appearanceComponent
        AppearanceSettings {
            width: 700
            height: 600
        }
    }

    TestCase {
        name: "SettingsPagesTests"
        when: windowShown

        function init() {
            Shell.reset();
            Settings.clear();
            Themes.clear();
        }

        function test_sectionsResolveToTheirBrick() {
            compare(Pages.resolve(""), "/settings/general");
            compare(Pages.resolve("/settings"), "/settings/general");
            compare(Pages.brickFor(""), "GeneralSettings");
            compare(Pages.brickFor("/settings/appearance"), "AppearanceSettings");
            compare(Pages.brickFor("/settings/cluster"), "ClusterSettings");
            compare(Pages.brickFor("/settings/connections"), "ConnectionsSettings");
            compare(Pages.brickFor("/settings/keybindings"), "KeybindingsSettings");
            compare(Pages.brickFor("/settings/providers"), "ProvidersSettings");
            compare(Pages.brickFor("/settings/storage"), "", "the page still renders Storage");
            compare(Pages.brickFor("/settings/nowhere"), "");
        }

        function test_navListsNativePagesAlwaysAndThePagesWhileListed() {
            const labels = rows => rows.map(section => section.label);
            compare(labels(Pages.navRows([], {})), ["General", "Appearance", "Keybindings"]);
            compare(labels(Pages.navRows([{ to: "/settings/storage" }], { cluster: {}, providerSettings: {} })), ["General", "Appearance", "Keybindings", "Providers", "Storage", "Cluster"]);
        }

        function test_searchFindsNativeSectionsAndDropsThePagesResultsInThem() {
            compare(Pages.searchRows("theme", {}).map(section => section.label), ["Appearance"]);
            compare(Pages.searchRows("invite", { cluster: {} })[0].label, "Cluster");
            compare(Pages.searchRows("pairing", {}).length, 0, "Connections waits for its state");
            compare(Pages.searchRows("pairing", { connections: {} })[0].label, "Connections");
            compare(Pages.searchRows("sign out", { providerSettings: {} })[0].label, "Providers");
            const kept = Pages.pageResults([{ to: "/settings/appearance" }, { to: "/settings/storage" }, { to: "/settings/providers" }]);
            compare(kept.map(result => result.to), ["/settings/storage"]);
        }

        function test_projectGroupingRestoresTheModeUsedBefore() {
            verify(!Rows.groupingOn("separate"));
            verify(Rows.groupingOn("repository_path"));
            compare(Rows.groupingFromToggle(false, ""), "separate");
            compare(Rows.groupingFromToggle(true, "repository_path"), "repository_path");
            compare(Rows.groupingFromToggle(true, ""), "repository");
        }

        function test_inactiveSettlingStartsFromTheDefault() {
            verify(!Rows.settleOn(null));
            verify(Rows.settleOn(7));
            compare(Rows.settleFromToggle(true, 3), 3);
            compare(Rows.settleFromToggle(false, 3), null);
        }

        function test_numbersStayInRange() {
            const row = { min: 12, max: 20 };
            compare(Rows.clamp(row, "30", 16), 20);
            compare(Rows.clamp(row, "3", 16), 12);
            compare(Rows.clamp(row, "abc", 16), 16);
        }

        function test_hostLoadsTheSectionsBrick() {
            const host = createTemporaryObject(hostComponent, root, { section: "/settings/general" });
            verify(!!host);
            tryCompare(host, "status", Loader.Ready);
            compare(host.item.objectName, "generalSettings");
            host.section = "/settings/storage";
            verify(!host.active, "the page's section loads nothing");
        }

        function test_aChangedRowOffersAReset() {
            Settings.defaults = { confirmThreadDelete: true };
            const spec = Rows.general.find(row => row.key === "confirmThreadDelete");
            const row = createTemporaryObject(rowComponent, root, { spec: spec });
            verify(!!row);
            const reset = findChild(row, "reset");
            verify(!reset.visible, "a row at its default offers no reset");
            Settings.set("confirmThreadDelete", false);
            verify(reset.visible);
            mouseClick(reset);
            compare(Settings.setting("confirmThreadDelete"), true);
            verify(!reset.visible);
        }

        function test_turningInactiveSettlingOnShowsTheDefaultDays() {
            Settings.defaults = { sidebarAutoSettleAfterDays: 3 };
            Settings.nodeKeys = ["sidebarAutoSettleAfterDays"];
            Settings.set("sidebarAutoSettleAfterDays", null);
            const spec = Rows.general.find(row => row.key === "sidebarAutoSettleAfterDays");
            const row = createTemporaryObject(rowComponent, root, { spec: spec });
            const days = findChild(row, "days");
            verify(!days.visible);
            const toggle = findChild(row, "control");
            mouseClick(toggle);
            compare(Settings.setting("sidebarAutoSettleAfterDays"), 3);
            tryVerify(() => days.visible);
            compare(days.value, 3);
        }

        function test_appearanceModesAndThemes() {
            Themes.available = [{ id: "grove", label: "Grove", appearance: "light", appearances: ["light", "dark"], source: "builtIn" }];
            const page = createTemporaryObject(appearanceComponent, root);
            verify(!!page);
            mouseClick(findChild(page, "mode:dark"));
            compare(Themes.mode, "dark");
            const grove = findChild(page, "theme:grove");
            verify(!!grove);
            mouseClick(grove.children[0]);
            compare(Themes.themeId, "grove");
        }

        function test_aNewThemeStartsFromTheActiveOneAndSavesItsEdits() {
            const page = createTemporaryObject(appearanceComponent, root);
            verify(!!page);
            mouseClick(findChild(page, "newTheme"));
            const editor = page.editor;
            tryVerify(() => editor.opened);
            compare(findChild(editor.contentItem, "name").text, "HAL-C2 copy");
            let accent = null;
            tryVerify(() => (accent = findChild(editor.contentItem, "color:accent")) !== null);
            accent.text = "#ff0000";
            accent.editingFinished();
            mouseClick(findChild(editor.contentItem, "save"));
            const saved = Themes.calls.filter(call => call.name === "saveCustom");
            compare(saved.length, 1);
            compare(saved[0].args[0].label, "HAL-C2 copy");
            compare(saved[0].args[0].id, "");
            compare(saved[0].args[0].appearance, "dark");
            compare(saved[0].args[0].colors.accent, "#ff0000");
            compare(saved[0].args[0].colors.canvas, "#000000");
            tryVerify(() => !editor.visible);
        }
    }
}
