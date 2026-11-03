pragma Singleton
import QtQuick

// The agents' browser host (src/native/PreviewAutomationController.h): no agent acts in tests.
QtObject {
    readonly property var activity: ({})
    readonly property bool reduceMotion: true
}
