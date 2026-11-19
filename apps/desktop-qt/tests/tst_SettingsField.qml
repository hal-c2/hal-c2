import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

TestCase {
    id: testCase
    name: "SettingsFieldTests"
    width: 500
    height: 200
    when: windowShown

    Component {
        id: besideComponent
        SettingsField {
            width: 400
            title: "Skip draft pull requests"
            description: "Drafts wait until they are ready."
            control: ShellSwitch {
                objectName: "switch"
            }
        }
    }

    Component {
        id: belowComponent
        SettingsField {
            width: 400
            title: "Prompt"
            ShellTextArea {
                objectName: "area"
                Layout.fillWidth: true
            }
        }
    }

    // Each kind of control a field holds, beside or below, as the plugins' pages have them.
    Component {
        id: namingComponent
        SettingsField {
            width: 400
            title: "Only issues labelled"
            description: "Empty to follow every open issue."
            control: ShellSwitch {
                objectName: "switch"
            }
            ShellTextField {
                objectName: "field"
            }
            ShellSpinBox {
                objectName: "spin"
            }
            ShellTextArea {
                objectName: "area"
            }
            ShellChoice {
                objectName: "choice"
                options: ["a", "b"]
            }
            ShellSpinBox {
                objectName: "named"
                Accessible.name: "Its own name"
            }
            ShellCheckBox {
                objectName: "check"
                text: "Also drafts"
            }
            Repeater {
                model: 1
                ShellTextField {
                    objectName: "repeated"
                }
            }
        }
    }

    // A screen reader hears the field's title as the name of what it holds and
    // its description as their description, and they follow the title.
    function test_titleNamesTheControls() {
        const field = createTemporaryObject(namingComponent, testCase);
        for (const name of ["switch", "field", "spin", "area", "choice"]) {
            const control = findChild(field, name);
            compare(control.Accessible.name, "Only issues labelled", name);
            compare(control.Accessible.description, "Empty to follow every open issue.", name);
        }
        tryCompare(findChild(field, "repeated").Accessible, "name", "Only issues labelled");
        field.title = "Labels";
        compare(findChild(field, "field").Accessible.name, "Labels");
    }

    // A control that names itself, or says what it is, keeps its own name.
    function test_controlKeepsItsOwnName() {
        const field = createTemporaryObject(namingComponent, testCase);
        compare(findChild(field, "named").Accessible.name, "Its own name");
        verify(findChild(field, "check").Accessible.name !== field.title);
    }

    // A small control sits to the right of the title, on its line.
    function test_controlSitsBesideTheTitle() {
        const field = createTemporaryObject(besideComponent, testCase);
        const control = findChild(field, "switch");
        waitForRendering(field);
        const at = control.mapToItem(field, 0, 0);
        verify(at.x > field.width / 2);
        verify(at.y < field.height / 2 + control.height);
    }

    // A wide control goes below the title and description, as wide as the field.
    function test_contentGoesBelow() {
        const field = createTemporaryObject(belowComponent, testCase);
        const area = findChild(field, "area");
        waitForRendering(field);
        const at = area.mapToItem(field, 0, 0);
        compare(at.x, 0);
        verify(at.y > 0);
        compare(area.width, field.width);
    }
}
