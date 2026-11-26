import QtQuick

// A row list of the Space view (SpaceRows): rows a test appends, found by id.
ListModel {
    function indexOf(id) {
        for (let i = 0; i < count; ++i) {
            if (get(i).id === id)
                return i;
        }
        return -1;
    }
}
