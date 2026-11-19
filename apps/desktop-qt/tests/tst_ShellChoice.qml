import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

// The options are clicked, so they sit in a shown item: a TestCase is not.
Item {
    id: root
    width: 600
    height: 120

    TestCase {
        id: testCase
        name: "ShellChoiceTests"
        when: windowShown

        Component {
            id: oneComponent
            ShellChoice {
                width: 500
                options: [
                    { value: "github", label: "GitHub" },
                    { value: "gitlab", label: "GitLab (coming later)", disabled: true }
                ]
                value: "github"
                onPicked: picked => value = picked
            }
        }

        Component {
            id: manyComponent
            ShellChoice {
                width: 500
                multiple: true
                optionName: "repository:"
                options: ["acme/api", "acme/web"]
                value: []
                onPicked: picked => value = value.includes(picked) ? value.filter(each => each !== picked) : value.concat([picked])
            }
        }

        // Two choices sharing labels, as a settings page has them.
        Component {
            id: pairComponent
            Column {
                ShellChoice {
                    objectName: "access"
                    width: 500
                    optionName: "access:"
                    options: [{ value: "", label: "Its default" }, "auto"]
                    Accessible.name: "Access"
                }
                ShellChoice {
                    objectName: "effort"
                    width: 500
                    optionName: "effort:"
                    options: [{ value: "", label: "Its default" }, "high"]
                    Accessible.name: "Effort"
                }
            }
        }

        function init() {
            Theme.colors = {
                text: "#111111",
                textMuted: "#777777",
                accentText: "#0055ff"
            };
        }

        function cleanup() {
            Theme.colors = {};
        }

        function test_chosenOptionIsInTheAccentInk() {
            const choice = createTemporaryObject(oneComponent, root);
            const github = findChild(choice, "choice:github");
            verify(github.chosen);
            compare(github.tint, Qt.color("#0055ff"));
        }

        // A disabled option cannot be chosen, and is read in the muted ink, at full opacity.
        function test_disabledOptionIsReadableAndCannotBeChosen() {
            const choice = createTemporaryObject(oneComponent, root);
            const gitlab = findChild(choice, "choice:gitlab");
            verify(!gitlab.enabled);
            compare(gitlab.opacity, 1);
            compare(gitlab.tint, Qt.color("#777777"));
            mouseClick(gitlab);
            compare(choice.value, "github");
            verify(!gitlab.chosen);
        }

        // With `multiple`, each click picks a value in or out, and the keyboard does the same.
        function test_manyPicksEachInAndOut() {
            const choice = createTemporaryObject(manyComponent, root);
            const api = findChild(choice, "repository:acme/api");
            const web = findChild(choice, "repository:acme/web");
            compare(api.text, "acme/api");
            mouseClick(api);
            mouseClick(web);
            compare(choice.value, ["acme/api", "acme/web"]);
            verify(api.chosen && web.chosen);
            api.forceActiveFocus(Qt.TabFocusReason);
            keyClick(Qt.Key_Return);
            compare(choice.value, ["acme/web"]);
            verify(!api.chosen);
        }

        // Sized by its natural width, as in a Flow, its options stay on one line.
        function test_naturalWidthKeepsTheOptionsOnOneLine() {
            const choice = createTemporaryObject(manyComponent, root, { width: 0 });
            choice.width = Qt.binding(() => choice.naturalWidth);
            const api = findChild(choice, "repository:acme/api");
            const web = findChild(choice, "repository:acme/web");
            tryCompare(web, "y", api.y);
            verify(web.x > api.x);
            compare(choice.naturalWidth, api.implicitWidth + web.implicitWidth + choice.spacing);
        }
    
        // Each choice is a named group, and an option says which one it is in,
        // so the same label in two choices is told apart.
        function test_optionsSayWhichChoiceTheyAreIn() {
            const pair = createTemporaryObject(pairComponent, root);
            const access = findChild(pair, "access");
            compare(access.Accessible.role, Accessible.Grouping);
            compare(findChild(pair, "access:").Accessible.description, "Access");
            compare(findChild(pair, "effort:").Accessible.description, "Effort");
            access.Accessible.name = "Runtime access";
            compare(findChild(pair, "access:").Accessible.description, "Runtime access");
        }
    }
}
