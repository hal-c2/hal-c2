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
