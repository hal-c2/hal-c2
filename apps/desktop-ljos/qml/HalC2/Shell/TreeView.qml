import QtQuick

// Stands in for QtQuick.TreeView over LocalFolderModel. Ljós has no tree
// views or tree models (TODO(ljos#27)), so the model is the tree's visible
// rows (depth, expanded and hasChildren are roles; toggleExpanded(row) opens
// and closes a folder) and the view is a ListView over them.
//
// `model:` has to be given once the model's object is complete, as
// FolderExplorer does by binding it to `enabled`/`rootPath`: an object that
// becomes a model only at its own completion is one row to a view resolving
// it earlier (TODO(ljos#37)).
ListView {
    id: tree

    // QModelIndex of the root in Qt; the rows here start at the root.
    property int rootIndex: -1
    property var columnWidthProvider: null
    property ItemSelectionModel selectionModel: null
    property int editTriggers: TableView.NoEditTriggers
    // Rows are cheap and a recycled one keeps its old roles.
    reuseItems: false
}
