import QtQuick

// Stands in for QtQml.Models.ItemSelectionModel over a list of rows: the
// current index is a row number, -1 for none.
QtObject {
    id: selection

    property var model: null
    property int currentIndex: -1
    property bool hasSelection: currentIndex >= 0

    signal currentChanged(int current, int previous)

    function setCurrentIndex(index, command) {
        if (index === currentIndex)
            return
        const previous = currentIndex
        currentIndex = index
        currentChanged(index, previous)
    }
    function clearCurrentIndex() {
        setCurrentIndex(-1, 0)
    }
    function clear() {
        clearCurrentIndex()
    }
}
