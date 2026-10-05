# Plugins

A plugin adds something small of your own to the desktop app: a clock in the
status bar, a quota meter under the thread list, a button beside the composer.
Each plugin is one QML file.

## Add a plugin

Open **Settings → Plugins**. Put a plugin file in the folder named at the top
of that page, or paste the address of one into **Load from URL**. HAL-C2 asks
before it downloads anything: a plugin from a URL is not signed, and a plugin
can do whatever the app can.

A plugin shows up as soon as its file is in the folder. Saving the file again
replaces the plugin while the app runs. If the new version has a mistake, the
version that was already running stays and the page says what went wrong.

## Turn a plugin off or remove it

**Disable** keeps the file and hides what the plugin added; **Enable** brings
it back. A disabled plugin stays disabled when you restart. The trash button
deletes the file.

## Write a plugin

A plugin names the places it adds to:

| Place              | Where it shows                  |
| ------------------ | ------------------------------- |
| `sidebar.footer`   | Under the thread list           |
| `composer.actions` | With the composer's own actions |
| `statusbar`        | Along the bottom of the window  |

```qml
import OpenTUI

Plugin {
    pluginId: "clock"

    property string now: new Date().toLocaleTimeString()

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: now = new Date().toLocaleTimeString()
    }

    Contribution {
        slot: "statusbar"
        Text { text: now }
    }
}
```

The same file works in the terminal client. Keep to `Text`, `Row`, `Column`,
`Rectangle` and `Timer` if you want it on both. A plugin that names a place the
app does not have is listed as loaded and shows nothing.
