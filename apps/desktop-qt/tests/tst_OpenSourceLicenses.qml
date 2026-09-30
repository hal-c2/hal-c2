import QtQuick
import QtTest
import "../qml/HalC2/Bricks"
import HalC2.Shell

// features/settings/licenses.feature: the licenses page draws what
// LicensesController publishes and hands searches, entries and retries back.
Item {
    id: root
    width: 800
    height: 700

    Component {
        id: pageComponent
        OpenSourceLicenses {
            width: 780
            height: 680
        }
    }

    function entry(name, overrides) {
        return Object.assign({ key: "package:" + name + "@1.0.0", name: name, version: "1.0.0", license: "MIT",
                               where: "Web", sourceUrl: null }, overrides);
    }

    TestCase {
        name: "OpenSourceLicensesTests"
        when: windowShown

        function init() {
            Shell.reset();
        }

        function test_a_search_counts_what_matches_and_opens_an_entry() {
            Shell.state = { licenses: { status: "ready", message: null, query: "re", total: 3,
                                        entries: [root.entry("react", {}), root.entry("MesloLGS NF", { version: null, where: "Android, Mobile" })],
                                        openKey: "package:react@1.0.0", noticeText: "MIT License" } };
            const page = createTemporaryObject(pageComponent, root);
            waitForRendering(page);
            compare(findChild(page, "licenseCount").text, "2 of 3");
            const react = findChild(page, "license:react");
            compare(findChild(react, "summary").text, "MIT · Web");
            const notice = findChild(react, "noticeText");
            verify(notice.visible);
            compare(notice.text, "MIT License");
            verify(!findChild(findChild(page, "license:MesloLGS NF"), "noticeText").visible);
            compare(findChild(findChild(page, "license:MesloLGS NF"), "toggle").text, "MesloLGS NF");

            mouseClick(findChild(react, "toggle"));
            compare(Shell.dispatchedActions[0].action, "licenses.open");
            compare(Shell.dispatchedActions[0].payload.key, "package:react@1.0.0");
        }

        function test_no_match_says_so() {
            Shell.state = { licenses: { status: "ready", message: null, query: "zzzz", total: 3, entries: [], openKey: null, noticeText: null } };
            const page = createTemporaryObject(pageComponent, root);
            verify(findChild(page, "noLicenseMatch").visible);
        }

        function test_a_failed_load_can_be_retried() {
            Shell.state = { licenses: { status: "error", message: "The license manifest could not load.", query: "", total: 0,
                                        entries: [], openKey: null, noticeText: null } };
            const page = createTemporaryObject(pageComponent, root);
            verify(findChild(page, "licensesError").visible);
            verify(!findChild(page, "licenseSearch").visible);
            mouseClick(findChild(page, "licensesRetry"));
            compare(Shell.dispatchedActions[0].action, "licenses.retry");
        }
    }
}
