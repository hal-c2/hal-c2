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
        id: editorComponent
        ThemeEditor {}
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
            compare(Pages.brickFor("/settings/source-control"), "SourceControlSettings");
            compare(Pages.brickFor("/settings/integrations"), "IntegrationsSettings");
            compare(Pages.brickFor("/settings/snap-shot"), "SnapShotSettings");
            compare(Pages.brickFor("/settings/nowhere"), "");
        }

        function test_navListsSectionsOnceTheirStateIsThere() {
            const labels = rows => rows.map(section => section.label);
            compare(labels(Pages.navRows({})), ["General", "Appearance", "Keybindings", "SnapShots"]);
            compare(labels(Pages.navRows({ cluster: {}, providerSettings: {} })), ["General", "Appearance", "Keybindings", "SnapShots", "Providers", "Cluster"]);
        }

        function test_pagesUnderGeneralKeepItMarked() {
            compare(Pages.brickFor("/settings/diagnostics"), "DiagnosticsSettings");
            compare(Pages.brickFor("/settings/open-source-licenses"), "OpenSourceLicenses");
            verify(!Pages.navRows({}).some(section => section.to === "/settings/open-source-licenses"));
            compare(Pages.current("/settings/open-source-licenses"), "/settings/general");
            compare(Pages.current("/settings/diagnostics"), "/settings/general");
            compare(Pages.current("/settings/appearance"), "/settings/appearance");
            verify(Pages.searchRows("licenses", {}).some(result => result.targetId === "settingsRow:open-source-licenses"));
        }

        function test_searchFindsSectionsAndTheirSettings() {
            compare(Pages.searchRows("theme", {}).map(section => section.label), ["Theme", "Appearance"]);
            compare(Pages.searchRows("theme", {})[0].targetId, "themes");
            compare(Pages.searchRows("delete confirmation", {})[0].targetId, "settingsRow:confirmThreadDelete");
            compare(Pages.searchRows("smoothing", {}).some(result => result.targetId === "settingsRow:fontSmoothing"), Qt.platform.os === "osx", "a macOS row is found only there");
            compare(Pages.searchRows("invite", { cluster: {} })[0].label, "Cluster");
            compare(Pages.searchRows("pairing", {}).length, 0, "Connections waits for its state");
            compare(Pages.searchRows("pairing", { connections: {} })[0].label, "Connections");
            compare(Pages.searchRows("sign out", { providerSettings: {} })[0].label, "Providers");
        }

        function test_projectGroupingRestoresTheModeUsedBefore() {
            verify(!Rows.groupingOn("separate"));
            verify(Rows.groupingOn("repository_path"));
            compare(Rows.groupingFromToggle(false, ""), "separate");
            compare(Rows.groupingFromToggle(true, "repository_path"), "repository_path");
            compare(Rows.groupingFromToggle(true, ""), "repository");
        }

        // The scroll bar is named for the page, not for the row text next to it.
        function test_the_settings_scroll_bar_has_its_own_name() {
            const page = createTemporaryObject(appearanceComponent, root, { height: 300 });
            compare(findChild(page, "scrollBar").Accessible.name, "Scroll settings");
        }

        // The text generation combo sits in the same control column as the other combos on General.
        function test_the_text_generation_combo_is_as_wide_as_the_other_combos() {
            const host = createTemporaryObject(hostComponent, root, { section: "/settings/general" });
            tryCompare(host, "status", Loader.Ready);
            const page = host.item;
            const generation = findChild(findChild(page, "settingsRow:text-generation-model"), "control");
            const timestamp = findChild(findChild(page, "settingsRow:timestampFormat"), "control");
            compare(generation.width, timestamp.width);
        }

        // The desktop has no browser, so the time format copy must name the system clock.
        function test_timeFormatDescribesTheSystemClockNotABrowser() {
            const spec = Rows.general.find(row => row.key === "timestampFormat");
            verify(!spec.description.includes("browser"), spec.description);
            verify(spec.description.includes("system"), spec.description);
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

        // features/settings/search-and-navigation.feature: opening a search
        // result brings the setting into view.
        function test_theOpenedSearchResultIsScrolledIntoView() {
            Themes.available = [{ id: "grove", label: "Grove", appearance: "light", appearances: ["light", "dark"], source: "builtIn" }];
            Shell.state = { route: { kind: "settings", section: "/settings/appearance", target: "", targetSeq: 0 } };
            const page = createTemporaryObject(appearanceComponent, root, { height: 300 });
            const target = findChild(page, "settingsRow:panelAnimationDurationMs");
            const inView = () => {
                const y = target.mapToItem(page, 0, 0).y;
                return y >= 0 && y + target.height <= page.height;
            };
            verify(!inView(), "the last row starts out of view");
            Shell.state = { route: { kind: "settings", section: "/settings/appearance", target: "settingsRow:panelAnimationDurationMs", targetSeq: 1 } };
            tryVerify(inView);
        }

        function test_openingTheSameResultAgainScrollsBackToIt() {
            Shell.state = { route: { kind: "settings", section: "/settings/appearance", target: "settingsRow:panelAnimationDurationMs", targetSeq: 1 } };
            const page = createTemporaryObject(appearanceComponent, root, { height: 300 });
            const target = findChild(page, "settingsRow:panelAnimationDurationMs");
            const inView = () => target.mapToItem(page, 0, 0).y >= 0 && target.mapToItem(page, 0, 0).y + target.height <= page.height;
            tryVerify(inView);
            findChild(page, "scroll").contentY = 0;
            verify(!inView(), "the user scrolled away");
            Shell.state = { route: { kind: "settings", section: "/settings/appearance", target: "settingsRow:panelAnimationDurationMs", targetSeq: 2 } };
            tryVerify(inView);
        }

        // A result in another section opens its page at the setting.
        function test_aPageOpenedForASearchResultStartsAtIt() {
            Shell.state = { route: { kind: "settings", section: "/settings/appearance", target: "settingsRow:panelAnimationDurationMs", targetSeq: 1 } };
            const page = createTemporaryObject(appearanceComponent, root, { height: 300 });
            const target = findChild(page, "settingsRow:panelAnimationDurationMs");
            tryVerify(() => target.mapToItem(page, 0, 0).y >= 0 && target.mapToItem(page, 0, 0).y + target.height <= page.height);
        }

        function test_choosingProvidersLoadsItsBrick() {
            Shell.state = { providerSettings: { open: true, environmentId: "", environments: [], status: "loading", title: "Loading provider settings",
                                                description: "", refreshing: false, providers: [] } };
            const host = createTemporaryObject(hostComponent, root, { section: "/settings/providers" });
            tryCompare(host, "status", Loader.Ready);
            compare(host.item.objectName, "providersSettings");
        }

        function test_hostLoadsTheSectionsBrick() {
            const host = createTemporaryObject(hostComponent, root, { section: "/settings/general" });
            verify(!!host);
            tryCompare(host, "status", Loader.Ready);
            compare(host.item.objectName, "generalSettings");
            host.section = "/settings/nowhere";
            verify(!host.active, "an unknown section loads nothing");
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
            Settings.mcKeys = ["sidebarAutoSettleAfterDays"];
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
            // The page hands the draft to the window's editor (ShellWindow's ThemeEditor).
            compare(Themes.calls.filter(call => call.name === "edit").length, 1);
            const editor = createTemporaryObject(editorComponent, root);
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
            compare(Themes.editorOpen, false);
        }
    }
}
