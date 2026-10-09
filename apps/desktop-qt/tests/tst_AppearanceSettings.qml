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
