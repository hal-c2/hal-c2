import QtQuick

// One Actor, described inside it, for each entry of `model`: a list of
// objects with an `id` (see `role`), a list of strings, or a number.
// Each gets the `key` and `entry` it was made for.
Item {
    id: crowd

    default property Component delegate
    readonly property var world: {
        let above = parent;
        while (above && above.world === undefined)
            above = above.parent;
        return above?.world ?? null;
    }
    property var model: null
    property string role: "id"
    property var members: ({})
    property int count: 0
    property bool built: false

    function list(entries) {
        return typeof entries === "number" ? Array.from({ length: entries }, (_, i) => i) : entries ?? [];
    }
    function keyOf(entry) {
        return String(typeof entry === "object" ? entry[role] : entry);
    }

    // Lets go of whoever is not in `entries`.
    function keep(entries) {
        const wanted = {};
        for (const entry of list(entries))
            wanted[keyOf(entry)] = true;
        for (const key of Object.keys(members)) {
            if (wanted[key])
                continue;
            const gone = members[key];
            delete members[key];
            count--;
            world?.leave(gone);
            gone.visible = false;
            gone.parent = null;
            gone.destroy();
        }
    }

    // Makes whoever is new in `entries`, and gives the rest their new entry.
    function fill(entries) {
        if (!delegate || !world)
            return;
        for (const entry of list(entries)) {
            const key = keyOf(entry);
            if (members[key]) {
                members[key].entry = entry;
                continue;
            }
            const made = delegate.createObject(crowd.parent, {
                key: key,
                entry: entry,
                world: world,
                crowd: crowd
            });
            if (made) {
                members[key] = made;
                count++;
            }
        }
    }

    function sync(entries) {
        keep(entries);
        fill(entries);
    }

    onModelChanged: if (built) sync(model)
    Component.onCompleted: {
        built = true;
        if (model !== null)
            sync(model);
    }
    Component.onDestruction: if (world?.leave) keep([])
}
