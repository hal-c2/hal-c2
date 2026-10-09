import QtQuick
import QtTest
import HalC2.Shell
import "../qml/HalC2/Bricks"

Item {
    id: root
    width: 400
    height: 300

    Component {
        id: notificationsComponent
        Notifications {
            width: 340
            height: implicitHeight
        }
    }

    TestCase {
        name: "NotificationsTests"
        when: windowShown

        function cleanup() {
            Shell.reset();
            Theme.colors = {};
            Theme.radius = 8;
        }

        function toast(id, title, actions) {
            return {
                id: id,
                type: "info",
                title: title,
                description: null,
                updateKey: 0,
                actions: actions
            };
        }

        function test_onlyTheShellsToastsShow() {
            Shell.state = {
                toasts: {
                    items: [toast("native:2", "Snoozed until 6 PM", [
                            {
                                id: "primary",
                                label: "Undo",
                                primary: true
                            }
                        ]), toast("native:1", "Pushing", [])],
                    expanded: true
                },
                notifications: {
                    items: [toast("page-1", "The page's", [])]
                }
            };
            const host = createTemporaryObject(notificationsComponent, root);
            compare(host.items.map(item => item.id), ["native:2", "native:1"]);
            compare(findChild(host, "notificationDismiss-page-1"), null);
            // Clicks land once the cards have faded in.
            tryCompare(findChild(host, "notification-native:2"), "opacity", 1);
            tryCompare(findChild(host, "notification-native:1"), "opacity", 1);
            const undo = findChild(host, "notificationAction-native:2-primary");
            verify(undo !== null);
            mouseClick(undo);
            const dismiss = findChild(host, "notificationDismiss-native:1");
            verify(dismiss !== null);
            mouseClick(dismiss);
            compare(Shell.dispatchedActions.map(entry => entry.action + " " + entry.payload.id), ["notification.action native:2", "notification.dismiss native:1"]);
        }

        function stack(count, expanded) {
            const items = [];
            for (let i = count; i >= 1; --i)
                items.push(toast("native:" + i, "Toast " + i, []));
            Shell.state = {
                toasts: {
                    items: items,
                    expanded: expanded
                }
            };
        }

        function card(host, id) {
            return findChild(host, "notification-" + id);
        }

        function expandRequests() {
            return Shell.dispatchedActions.filter(entry => entry.action === "notification.expand").map(entry => entry.payload.expanded);
        }

        function test_aCollapsedStackShowsTheNewestWithTwoBehindIt() {
            stack(5, false);
            const host = createTemporaryObject(notificationsComponent, root);
            tryVerify(() => card(host, "native:5") && card(host, "native:5").visible);
            tryVerify(() => card(host, "native:4").visible && card(host, "native:3").visible);
            tryVerify(() => !card(host, "native:2").visible && !card(host, "native:1").visible);
            verify(card(host, "native:5").enabled);
            verify(!card(host, "native:4").enabled);
            verify(host.height < 2 * card(host, "native:5").height);
        }

        function test_anExpandedStackShowsEveryToast() {
            stack(5, true);
            const host = createTemporaryObject(notificationsComponent, root);
            for (let i = 1; i <= 5; ++i) {
                const id = "native:" + i;
                tryVerify(() => card(host, id) && card(host, id).visible && card(host, id).enabled, 1000, id);
            }
            const dismiss = findChild(host, "notificationDismiss-native:1");
            tryVerify(() => dismiss.visible);
        }

        function test_pointingAtTheStackExpandsIt() {
            stack(3, false);
            const host = createTemporaryObject(notificationsComponent, root);
            tryVerify(() => host.height > 0);
            mouseMove(host, host.width / 2, 10);
            tryCompare(host, "wantsExpanded", true);
            compare(expandRequests(), [true]);
            stack(3, true);
            mouseMove(root, root.width - 2, root.height - 2);
            tryCompare(host, "wantsExpanded", false);
            compare(expandRequests(), [true, false]);
        }

        function test_aTapOpensTheStackAndAnotherClosesIt() {
            stack(3, false);
            const host = createTemporaryObject(notificationsComponent, root);
            tryVerify(() => host.height > 0);
            touchEvent(host).press(0, host, host.width / 3, 10).commit().release(0, host, host.width / 3, 10).commit();
            compare(expandRequests(), [true]);
            stack(3, true);
            touchEvent(host).press(0, host, host.width / 3, 10).commit().release(0, host, host.width / 3, 10).commit();
            compare(expandRequests(), [true, false]);
        }

        function test_aNewToastLeavesTheOthersCardsAlone() {
            stack(2, false);
            const host = createTemporaryObject(notificationsComponent, root);
            tryVerify(() => card(host, "native:1") !== null);
            const older = card(host, "native:1");
            stack(3, false);
            compare(card(host, "native:1"), older);
        }

        function test_accentClearsRoundedCorners_data() {
            return [
                {
                    tag: "square",
                    radius: 0
                },
                {
                    tag: "terminal",
                    radius: 4
                },
                {
                    tag: "glass-minimal",
                    radius: 10
                },
                {
                    tag: "dashboard",
                    radius: 18
                }
            ];
        }

        function isAccent(shot, x, y) {
            return shot.red(x, y) > 200 && shot.green(x, y) < 60 && shot.blue(x, y) < 60;
        }

        function test_accentClearsRoundedCorners(data) {
            Theme.radius = data.radius;
            Theme.colors = {
                warning: "#ff0000",
                surfaceOverlay: "#ffffff",
                border: "#ffffff"
            };
            Shell.state = {
                toasts: {
                    items: [
                        {
                            id: "native:1",
                            type: "warning",
                            title: qsTr("Update available"),
                            description: qsTr("Install the update now or review provider settings."),
                            actions: []
                        }
                    ]
                }
            };
            let toast = createTemporaryObject(notificationsComponent, root);
            verify(!!toast, "Component exists");
            tryVerify(() => {
                const shot = grabImage(toast);
                return isAccent(shot, 2, Math.floor(shot.height / 2));
            });
            const shot = grabImage(toast);
            let top = shot.height;
            let bottom = -1;
            for (let y = 0; y < shot.height; ++y) {
                for (let x = 0; x < 6; ++x) {
                    if (isAccent(shot, x, y)) {
                        top = Math.min(top, y);
                        bottom = Math.max(bottom, y);
                    }
                }
            }
            verify(bottom > top);
            verify(top >= Math.max(1, data.radius));
            verify(bottom < shot.height - Math.max(1, data.radius));
            compare(Math.abs(top - (shot.height - 1 - bottom)) <= 1, true);
        }
    }
}
