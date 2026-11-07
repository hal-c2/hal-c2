import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Layouts
import HalC2.Shell

// A settings section's title: title size, set apart from what is above it.
// The settings pages' own sections and SettingsPage's headings share it.
Label {
    Layout.fillWidth: true
    Layout.topMargin: Theme.space.lg
    color: Theme.palette.color("ink", "#e4e4e7")
    font.pixelSize: Theme.type.title.size
    font.weight: Font.DemiBold
    wrapMode: Text.Wrap
}
