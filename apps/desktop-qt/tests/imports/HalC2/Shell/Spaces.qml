pragma Singleton
import QtQuick

// The Space view's state (SpaceController), as rows and fields a test sets
// with load(): each list is an array of the rows SpacePages documents.
QtObject {
    property string spaceId: ""
    property string spaceName: ""
    property string pageId: ""
    property var page: ({})
    property string status: "live"
    readonly property SpaceRows spaces: SpaceRows {}
    readonly property SpaceRows pages: SpaceRows {}
    readonly property SpaceRows trash: SpaceRows {}
    readonly property SpaceRows blocks: SpaceRows {}
    readonly property SpaceRows comments: SpaceRows {}

    function fill(model, rows) {
        model.clear();
        for (const row of rows ?? [])
            model.append(row);
    }

    function load(state) {
        spaceId = state.spaceId ?? "";
        spaceName = state.spaceName ?? "";
        status = state.status ?? "live";
        fill(spaces, state.spaces);
        fill(pages, state.pages);
        fill(trash, state.trash);
        fill(blocks, state.blocks);
        fill(comments, state.comments);
        page = state.page ?? {};
        pageId = page.id ?? "";
    }

    function reset() {
        load({});
    }
}
