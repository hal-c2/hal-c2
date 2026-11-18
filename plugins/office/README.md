# Office

A machine's threads as people in a pixel-art office. Each thread sits at a desk,
with the workers it delegated to in the same group of desks; about a third of the
workers are cats and dogs. What a person does follows its agent: typing, running
and testing at the computer, planning at a whiteboard, reading at a bookshelf,
and drinking coffee, napping on the couch or chatting in the break room while it
waits. They walk around the furniture and each other. When one agent hands work
to another or messages it, the two walk up to each other and talk; one whose
agent asks the user something raises a question mark. Hover a person for who it
is; click it to open its thread. How to use it is in
[docs/user/office.md](../../docs/user/office.md); what it does, scenario by
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
- `ui/OfficePage.qml`: the **Office** page. Every look is drawn from a seed (the
  thread's id), so a person looks the same each time and on every client. The
  floor, each piece of furniture and one sprite sheet per person are painted
  once; the page then only moves them, on one timer that runs while the page is
  shown.
- `test/tst_OfficePage.qml`: the page against a fake MC part; its header has the
  command that runs it.

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
`thinking` or null. `talks` are the newest 40, oldest first; `kind` is
`delegate`, `message` or `result`.
