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

        // features/navigation/appearance.feature: each theme shows its colors.
        function test_eachThemeShowsItsColorsBesideItsName() {
            const page = createTemporaryObject(pageComponent, root);
            const standard = findChild(page, "theme:hal-c2");
            const grove = findChild(page, "use:grove");
            compare(swatches(standard), ["#ffffff", "#2563eb", "#18181b"]);
            compare(swatches(grove), ["#f1f5ee", "#3f7d4e", "#1c2a1f"]);
            // The name starts at the left, after the swatches, not in the middle of the row.
            let name = null;
            const walk = item => {
                if (item.text === "Grove" && item.elide !== undefined && item !== grove) name = item;
                for (const child of item.children) walk(child);
            };
            walk(grove.contentItem);
            verify(name !== null);
            verify(name.mapToItem(grove, 0, 0).x < 80, "the name starts at " + name.mapToItem(grove, 0, 0).x);
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
    }
}
