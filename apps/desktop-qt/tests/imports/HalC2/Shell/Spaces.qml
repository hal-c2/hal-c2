pragma Singleton
import QtQuick

// The Space view's state (SpaceController), as rows and fields a test sets
// with load(): each list is an array of the rows SpacePages documents.
QtObject {
    property string spaceId: ""
    property string spaceName: ""
    property string pageId: ""
    property var page: ({})
    property string deckId: ""
    property var deck: ({})
    property bool presenting: false
    property var slide: ({})
    property int slideNumber: 0
    property int slideCount: 0
    property string status: "live"
    readonly property SpaceRows spaces: SpaceRows {}
    readonly property SpaceRows pages: SpaceRows {}
    readonly property SpaceRows trash: SpaceRows {}
    readonly property SpaceRows blocks: SpaceRows {}
    readonly property SpaceRows comments: SpaceRows {}
    readonly property SpaceRows decks: SpaceRows {}
    readonly property SpaceRows deckTrash: SpaceRows {}
    readonly property SpaceRows slides: SpaceRows {}
    readonly property SpaceRows images: SpaceRows {}
    readonly property SpaceRows imageTrash: SpaceRows {}
    // As SpaceHistory; load() takes `history` with its fields and rows.
    readonly property QtObject history: QtObject {
        signal changed
        property bool shown: false
        property string pageId: ""
        property bool loading: false
        property bool failed: false
        property bool hasMore: false
        property bool reading: false
        property var version: ({})
        readonly property SpaceRows versions: SpaceRows {}
        readonly property SpaceRows blocks: SpaceRows {}
    }

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
        fill(decks, state.decks);
        fill(deckTrash, state.deckTrash);
        fill(slides, state.slides);
        fill(images, state.images);
        fill(imageTrash, state.imageTrash);
        const history = state.history ?? {};
        fill(this.history.versions, history.versions);
        fill(this.history.blocks, history.blocks);
        this.history.pageId = history.pageId ?? "";
        this.history.loading = history.loading ?? false;
        this.history.failed = history.failed ?? false;
        this.history.hasMore = history.hasMore ?? false;
        this.history.version = history.version ?? {};
        this.history.reading = history.reading ?? false;
        this.history.shown = history.shown ?? false;
        this.history.changed();
        page = state.page ?? {};
        pageId = page.id ?? "";
        deck = state.deck ?? {};
        deckId = deck.id ?? "";
        slide = state.slide ?? {};
        slideNumber = state.slideNumber ?? 0;
        slideCount = state.slideCount ?? 0;
        presenting = state.presenting ?? false;
    }

    function reset() {
        load({});
    }
}
