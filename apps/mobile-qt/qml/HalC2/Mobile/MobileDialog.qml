import QtQuick
import QtQuick.Controls.Material
import HalC2.Shell

// A question or a small form over the screen: its title, then its content,
// which brings its own buttons. Centred in its parent, so it stays clear of
// the keyboard when the parent does.
Dialog {
    id: dialog

    modal: true
    anchors.centerIn: parent
    width: Math.min(parent.width - 32, 420)
    padding: 20

    background: MobileSurface {}
    Overlay.modal: MobileScrim {}

    header: Label {
        text: dialog.title
        visible: text.length > 0
        padding: 20
        bottomPadding: 0
        wrapMode: Text.Wrap
        font.pixelSize: Math.round(18 * Theme.fontScale)
        font.weight: Font.DemiBold
    }
}
