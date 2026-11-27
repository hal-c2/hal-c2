# Office

A machine's threads as people in a pixel-art office. Each thread sits at a desk,
with the workers it delegated to in the same group of desks; about a third of the
workers are cats and dogs. What a person does follows its agent: typing, running
and testing at the computer, planning at a whiteboard, reading at a bookshelf,
and, while it waits, sitting at the desk, with now and then a coffee, a nap on
the couch or a chat in the break room. They walk around the furniture and
through each other. When one agent hands work to another or messages it, the two
walk up to each other and talk; one whose agent asks the user something raises a
question mark. Hover a person for who it is; click it to open its thread. How to
use it is in [docs/user/office.md](../../docs/user/office.md); what it does, scenario by
scenario, is in [features/plugins/office.feature](../../features/plugins/office.feature).

It is an ordinary MC plugin and needs nothing from this repository but the
plugin API: copy the folder into an MC's `plugins` folder to install it.

## The package

- `plugin.json`: the name, description, the permissions it asks for and why,
  its settings and the page it adds.
- `mc/`: the MC part. `office.ex` follows the machine's thread rows and observed
  turns and publishes the `office` topic; `floor.ex` is who is in the office,
  what each does and who talks to whom, as plain functions. Nothing is kept on
  disk: after a restart the office is rebuilt from the threads.
- `ui/OfficePage.qml`: the **Office** page, generated from `src/`. Don't edit it.
  Clients fetch only the files `plugin.json` names, so the page and the engine
  it uses have to be this one file. Every look is drawn from a seed (the
  thread's id), so a person looks the same each time and on every client. The
  floor, each piece of furniture and one sprite sheet per person are painted
  once; the page then only moves them, on one timer that runs while the page is
  shown. A sprite sheet is thousands of Canvas calls, so sheets are painted a few
  a frame, within a budget the page learns from how long one took; until the
  floor and everyone on it are drawn, the page says the office is being set up.
- `src/`: the page as it is written. `OfficePage.qml` says who is in the room
  and what they do, and `OfficeArt.qml` and `Furniture.qml` draw it.
- `ljos-play/`: a submodule pinning the declarative engine that runs it,
  [Ljós Play](https://github.com/hal-c2/ljos-play). Change the engine in its
  own repository and move the submodule here. Only the bundler reads it, so
  clients and tests work without it checked out.
- `bundle.mjs`: writes `ui/OfficePage.qml` from `src/` and the engine.
- `test/tst_OfficePage.qml`: the generated page against a fake MC part.

## Changing the page

Edit `src/`, then write the shipped file and check that it is current:

```bash
node plugins/office/bundle.mjs
node plugins/office/bundle.mjs --check
```

The bundler reads the engine from the commit the submodule is pinned at, not
whatever is checked out there, and checks the submodule out if it is not yet.
To move the engine, check out another ljos-play commit in the submodule, stage
it, then bundle:

```bash
git submodule update --init -- plugins/office/ljos-play
git -C plugins/office/ljos-play fetch origin
git -C plugins/office/ljos-play checkout <commit>
git add plugins/office/ljos-play
node plugins/office/bundle.mjs
git add plugins/office/ui/OfficePage.qml
```

The bundler makes each file in `src/` an inline component, so a file has one
root object, its opening line and closing brace in the first column.

## Running the tests

From the repository root, with both `-import` paths: `apps/mobile-qt/tests/imports`
holds the fake `HalC2.Shell` and `packages/qml` the bricks. Without them
the run fails with "module HalC2.Shell is not installed".

```bash
# Ljós
ljos test --import apps/mobile-qt/tests/imports --import packages/qml \
  plugins/office/test/tst_OfficePage.qml

# Qt 6 (a bare qmltestrunner may be Qt 5's, which prints nothing and exits 1)
QT_QPA_PLATFORM=offscreen "$(qmake6 -query QT_INSTALL_BINS)/qmltestrunner" \
  -import apps/mobile-qt/tests/imports -import packages/qml \
  -input plugins/office/test/tst_OfficePage.qml
```

Add `OfficePage::test_<name>` after `-input <file>` to run single tests with Qt.

## The `office` topic

```json
{
  "people": [
    {
      "id": "…",
      "title": "Fix the parser",
      "projectId": "…",
      "project": "api",
      "parentId": null,
      "provider": "claudeAgent",
      "model": "claude-opus-5-5",
      "state": "working",
      "activity": "testing",
      "question": null,
      "since": "2026-11-18T21:00:00Z"
    }
  ],
  "talks": [
    {
      "id": "…",
      "from": "…",
      "to": "…",
      "kind": "delegate",
      "text": "Write the tests",
      "at": "2026-11-18T21:00:05Z"
    }
  ]
}
```

`state` is `working`, `asking`, `waiting`, `idle` or `failed`; `activity` is
`typing`, `running`, `testing`, `reading`, `browsing`, `planning`, `delegating`,
`thinking` or null. `talks` are the newest 40, oldest first, and each leaves
thirty seconds after it was said, even with fewer than 40: the topic holds what
is being said now, not a history. `kind` is `delegate`, `message` or `result`; a
hand-off is only a talk while its worker is that new. A talk can come before
either of its two is in `people`, a hand-off before its worker's row for one,
and waits on the page for both while it is in the topic. A talk keeps its id as
its text arrives, and the page shows the text it has now. The page plays none
that were there when it first saw the office or came back in sight.
