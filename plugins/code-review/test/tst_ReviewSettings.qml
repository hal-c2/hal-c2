// Run from a hal-c2 checkout, with QT_QPA_PLATFORM=offscreen:
//   qmltestrunner -import apps/desktop-qt/tests/imports -import apps/desktop-qt/qml \
//     -input plugins/code-review/test
import QtQuick
import QtTest

// A TestCase is never visible, so what it types into lives beside it.
Item {
    id: test

    width: 900
    height: 2400

    readonly property var saved: ({
            host: "github",
            repositories: ["acme/api"],
            activation: "selective",
            ignoredAuthors: ["dependabot[bot]"],
            trustedLogins: [],
            reviewsPerAuthorPerDay: 10,
            reviewsPerRepositoryPerDay: 50,
            maxChangedLines: 2000,
            concurrency: 2,
            pollMinutes: 5,
            provider: "codex",
            model: "",
            prompt: "Review {{pr.number}}."
        })

    // The plugin object a settings page gets, with the MC part faked:
    // `settings` answers what is saved, and each save is recorded.
    QtObject {
        id: plugin

        property var environments: ["local"]
        property var saves: []

        function call(method, input, callback, environment) {
            callback({
                settings: test.saved,
                providers: [],
                repositories: []
            }, null);
        }

        function saveSettings(values, callback, environment) {
            saves = saves.concat([values]);
            callback({}, null);
        }
    }

    Loader {
        id: loader

        width: test.width
    }

    TestCase {
        name: "ReviewSettings"
        when: windowShown

        function find(name) {
            return findChild(loader.item, name);
        }

        function init() {
            plugin.saves = [];
            loader.source = "";
            loader.setSource(Qt.resolvedUrl("../ui/ReviewSettings.qml"), {
                plugin: plugin
            });
            tryVerify(() => loader.status === Loader.Ready && loader.item.loaded);
        }

        function type(field, text) {
            field.forceActiveFocus();
            for (const each of text)
                keyClick(each);
        }

        function test_a_second_login_can_be_typed_after_a_comma() {
            const field = find("codeReviewSetting:trustedLogins");
            type(field, "a,");
            compare(field.text, "a,");
            type(field, " b");
            compare(field.text, "a, b");
            compare(loader.item.values.trustedLogins, ["a", "b"]);
            verify(loader.item.dirty);

            // Once editing ends the text is shown as the setting has it.
            type(field, ",");
            field.editingFinished();
            compare(field.text, "a, b");

            mouseClick(find("codeReviewSave"));
            compare(plugin.saves.length, 1);
            compare(plugin.saves[0].trustedLogins, ["a", "b"]);
        }

        function test_ignored_authors_take_a_second_login_too() {
            const field = find("codeReviewSetting:ignoredAuthors");
            field.forceActiveFocus();
            field.cursorPosition = field.text.length;
            type(field, ", renovate[bot]");
            compare(field.text, "dependabot[bot], renovate[bot]");
            compare(loader.item.values.ignoredAuthors, ["dependabot[bot]", "renovate[bot]"]);
        }

        function test_discarding_shows_the_saved_logins_again() {
            const field = find("codeReviewSetting:trustedLogins");
            type(field, "a,");
            verify(loader.item.dirty);
            mouseClick(find("codeReviewDiscard"));
            compare(field.text, "");
            verify(!loader.item.dirty);
        }
    }
}
