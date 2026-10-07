# Code Review

An agent of your choice reviews pull requests on the repositories you pick, and
you decide what of it reaches the pull request. How to use it is in
[docs/user/code-review.md](../../docs/user/code-review.md); what it does, scenario
by scenario, is in
[features/source-control/agent-code-review.feature](../../features/source-control/agent-code-review.feature).

It is an ordinary MC plugin and needs nothing from this repository but the plugin
API: copy the folder into an MC's `plugins` folder to install it.

## The package

- `plugin.json`: the name, description, screenshots, the permissions it asks
  for and why, its settings and what it adds to the clients.
- `mc/`: the MC part. `code_review.ex` watches the repositories, runs each review
  in a thread of its own and publishes; `checkout.ex` makes the checkout of a pull
  request's head the agent works in.
- `ui/`: one QML file per part, each self-contained. `ReviewsPage.qml` is the
  **Reviews** tab, `ReviewHeader.qml` and `ReviewRowMark.qml` are how a review
  thread looks, and `ReviewSettings.qml` replaces the generated settings page.
- `assets/`: the icon and the screenshots `plugin.json` names.

## Between the parts

The UI parts follow two topics of the MC part: `reviews`, every review with what
is watched, for the page; and `threads`, each review thread's pull request, state
and verdict, for the header and row mark, sent only when one of those changes.
They act through calls: `settings` (with the MC's agents and the repositories of
its projects), `start`, `retry`, `refresh`, `dismiss`, `publish` and `discard`.

The agent reports through the `code_review_report` tool the plugin gives its
threads.

## Tests

The MC scenarios run with `mise exec -- mix features source-control/agent-code-review.feature`
in `apps/server-ex`. The desktop draws these QML files against a fake of the MC
part: `HAL_C2_FEATURES="source-control/agent-code-review.feature"` with the
desktop's `tst_Features`.
