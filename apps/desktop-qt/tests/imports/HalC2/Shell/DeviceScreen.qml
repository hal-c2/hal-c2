import QtQuick

// DeviceScreen (src/native/DeviceScreen.h) without a decoder: it never has a picture.
Item {
    property var stream: null
    readonly property bool hasFrame: false
}
