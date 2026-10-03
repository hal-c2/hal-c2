import QtQuick
import "js/settingsRows.js" as Rows

// Settings → General, natively: the everyday behaviour of threads, the
// composer, diffs and confirmations (features/settings/general.feature).
SettingsPage {
    objectName: "generalSettings"
    title: qsTr("General")
    rows: Rows.general

    // The auto-settle rules are each environment's own.
    SettingsScopeSentence {}
}
