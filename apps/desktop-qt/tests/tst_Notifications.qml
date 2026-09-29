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
                        ]), toast("native:1", "Pushing", [])]
                },
                notifications: {
                    items: [toast("page-1", "The page's", [])]
                }
            };
            const host = createTemporaryObject(notificationsComponent, root);
            compare(host.items.map(item => item.id), ["native:2", "native:1"]);
            compare(findChild(host, "notificationDismiss-page-1"), null);

            const undo = findChild(host, "notificationAction-native:2-primary");
            verify(undo !== null);
            mouseClick(undo);
            const dismiss = findChild(host, "notificationDismiss-native:1");
            verify(dismiss !== null);
            mouseClick(dismiss);
            compare(Shell.dispatchedActions.map(entry => entry.action + " " + entry.payload.id), ["notification.action native:2", "notification.dismiss native:1"]);
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
