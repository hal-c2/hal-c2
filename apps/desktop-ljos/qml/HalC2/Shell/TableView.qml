import QtQuick

// Stands in for QtQuick.TableView, for what TreeView takes of it.
Item {
    enum EditTriggers {
        NoEditTriggers = 0,
        SingleTapped = 1,
        DoubleTapped = 2,
        SelectedTapped = 4,
        EditKeyPressed = 8,
        AnyKeyPressed = 16
    }
}
