import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// Settings → Appearance: what the page says about the theme in use.
Item {
    id: root
    width: 700
    height: 800

    Component {
        id: pageComponent
        AppearanceSettings {
            width: 700
            height: 800
        }
    }

    TestCase {
        name: "AppearanceSettingsTests"
        when: windowShown

        function init() {
            Shell.reset();
            Themes.clear();
            Themes.standardSwatch = ["#ffffff", "#2563eb", "#18181b"];
            Themes.available = [
                { id: "grove", label: "Grove", appearance: "light", appearances: ["light", "dark"], source: "builtIn", collection: "", swatch: ["#f1f5ee", "#3f7d4e", "#1c2a1f"] },
                { id: "mine", label: "Mine", appearance: "dark", appearances: ["dark"], source: "custom", collection: "", swatch: ["#101010", "#ff8800", "#fafafa"] }
            ];
        }

        function cleanup() {
            Theme.loaded = false;
            Theme.name = "";
            Theme.followsSystemAppearance = false;
            Theme.lastError = "";
            Theme.appearance = "dark";
            Theme.colors = {};
        }

        function swatches(choice) {
            const found = [];
            const walk = item => {
                if (item.objectName === "swatch") found.push(item.color.toString());
                for (const child of item.children) walk(child);
            };
            walk(choice.contentItem);
            return found;
        }

        // features/navigation/appearance.feature: Settings → Appearance marks
        // the theme in use, the standard theme included.
        function test_theThemeInUseIsMarkedAndTheStandardThemeIsTheWayBack() {
            const page = createTemporaryObject(pageComponent, root);
            const standard = findChild(page, "theme:hal-c2");
            const grove = findChild(page, "use:grove");
            const mine = findChild(page, "use:mine");
            const marked = () => [standard, grove, mine].filter(choice => choice.checked);
            compare(marked().length, 1);
            verify(standard.checked);
            // The standard look is listed first.
            verify(standard.mapToItem(page, 0, 0).y < grove.mapToItem(page, 0, 0).y);

            mouseClick(grove);
            compare(Themes.themeId, "grove");
            compare(marked().length, 1);
            verify(grove.checked);

            mouseClick(standard);
            compare(Themes.themeId, "");
            compare(Themes.resolvedId, "hal-c2");
            compare(marked().length, 1);
            verify(standard.checked);
        }

        // features/navigation/theme-editor.feature: the standard theme can be
        // duplicated like the others.
        function test_theStandardThemeCanBeDuplicated() {
            const page = createTemporaryObject(pageComponent, root);
            mouseClick(findChild(page, "duplicate:hal-c2"));
            compare(Themes.calls.filter(call => call.name === "duplicateStandard").length, 1);
            compare(Themes.calls.filter(call => call.name === "duplicate").length, 0, "a saved theme is not what it copies");
        }

        // features/navigation/appearance.feature: each theme shows its colors.
        function test_eachThemeShowsItsColorsBesideItsName() {
            const page = createTemporaryObject(pageComponent, root);
            const standard = findChild(page, "theme:hal-c2");
            const grove = findChild(page, "use:grove");
            compare(swatches(standard), ["#ffffff", "#2563eb", "#18181b"]);
            compare(swatches(grove), ["#f1f5ee", "#3f7d4e", "#1c2a1f"]);
            // The name starts at the left, after the check's room and the swatches,
            // not in the middle of the row.
            let name = null;
            const walk = item => {
                if (item.text === "Grove" && item.elide !== undefined && item !== grove) name = item;
                for (const child of item.children) walk(child);
            };
            walk(grove.contentItem);
            verify(name !== null);
            verify(name.mapToItem(grove, 0, 0).x < 100, "the name starts at " + name.mapToItem(grove, 0, 0).x);
            compare(name.horizontalAlignment, Text.AlignLeft);
        }

        // features/navigation/environment-themes.feature: Appearance says
        // when a shell theme file is in charge.
        function test_aShellThemeFileIsNamedWithWhatItOverrides() {
            const page = createTemporaryObject(pageComponent, root);
            const notice = findChild(page, "shellTheme");
            const effect = findChild(page, "shellThemeEffect");
            verify(!notice.visible);

            Theme.colors = { surfaceRaised: "#eff6ff", text: "#18181b" };
            Theme.name = "Tokyo Night";
            Theme.loaded = true;
            tryVerify(() => notice.visible && notice.height > 40);
            verify(findChild(page, "shellThemeTitle").text.includes("Tokyo Night"));
            compare(findChild(page, "shellThemePath").text, "/config/theme.json");
            verify(effect.text.includes("keeps the app dark"), effect.text);
            // Above the choices it explains, and readable on its surface.
            verify(notice.mapToItem(page, 0, 0).y < findChild(page, "mode:light").mapToItem(page, 0, 0).y);
            verify(Qt.colorEqual(notice.color, "#eff6ff") && Qt.colorEqual(effect.color, "#18181b"));
            // The choices still work: they are saved under the file.
            mouseClick(findChild(page, "mode:light"));
            compare(Themes.mode, "light");

            Theme.followsSystemAppearance = true;
            verify(effect.text.includes("follows the color scheme"), effect.text);

            Theme.loaded = false;
            tryVerify(() => !notice.visible);
            // A file that cannot be read says why.
            Theme.lastError = "theme.json: unterminated object";
            tryVerify(() => notice.visible);
            compare(findChild(page, "shellThemeError").text, "theme.json: unterminated object");
            verify(!findChild(page, "shellThemeTitle").visible);
        }

        // New theme and Import theme sit together on the Themes heading, and
        // a row's actions are all icon buttons of one size.
        function test_theThemeActionsSitTogether() {
            const page = createTemporaryObject(pageComponent, root);
            const heading = findChild(page, "themes");
            const create = findChild(page, "newTheme");
            const add = findChild(page, "importTheme");
            const standard = findChild(page, "theme:hal-c2");
            tryVerify(() => create.width > 0 && standard.mapToItem(page, 0, 0).y > 0);
            compare(create.mapToItem(page, 0, 0).y, add.mapToItem(page, 0, 0).y);
            verify(create.mapToItem(page, 0, 0).y < standard.mapToItem(page, 0, 0).y);
            verify(create.mapToItem(heading, 0, 0).y >= 0 && create.mapToItem(heading, 0, 0).y < heading.height);
            const exporter = findChild(page, "export:grove");
            compare(exporter.text, "");
            compare(exporter.iconName, "download");
            compare(exporter.width, exporter.height);
            compare(exporter.Accessible.name, "Export Grove");
        }

        // System, Light and Dark are one width, whatever their labels' lengths.
        function test_theColorSchemeSegmentsAreEqual() {
            const page = createTemporaryObject(pageComponent, root);
            const segments = ["system", "light", "dark"].map(mode => findChild(page, "mode:" + mode));
            tryVerify(() => segments[0].width > 0);
            compare(segments[1].width, segments[0].width);
            compare(segments[2].width, segments[0].width);
        }

        // Every row's Duplicate is in one column, the standard theme's and a
        // built-in's included, while a theme of one's own has Edit and Remove.
        function test_theDuplicateButtonsShareAColumn() {
            const page = createTemporaryObject(pageComponent, root);
            const copies = ["hal-c2", "grove", "mine"].map(id => findChild(page, "duplicate:" + id));
            tryVerify(() => copies[0].width > 0 && copies[2].width > 0);
            const x = copies.map(copy => copy.mapToItem(page, 0, 0).x);
            compare(x[1], x[0]);
            compare(x[2], x[0]);
            verify(findChild(page, "export:grove").mapToItem(page, 0, 0).x
                   === findChild(page, "export:mine").mapToItem(page, 0, 0).x,
                   "the Export buttons share a column too");
        }

        // Without a theme of one's own, no row keeps room for Edit and Remove.
        function test_withoutACustomThemeTheRowsCloseUp() {
            Themes.available = [Themes.available[0]];
            const page = createTemporaryObject(pageComponent, root);
            const standard = findChild(page, "duplicate:hal-c2");
            const grove = findChild(page, "duplicate:grove");
            tryVerify(() => standard.width > 0);
            compare(grove.mapToItem(page, 0, 0).x, standard.mapToItem(page, 0, 0).x);
            const row = findChild(page, "theme:grove");
            const exporter = findChild(page, "export:grove");
            verify(row.mapToItem(page, row.width, 0).x - exporter.mapToItem(page, exporter.width, 0).x
                   < standard.width, "Export is the row's last button");
        }
    }
}
