// The prompt stash (ComposerController): stashing the route thread's draft,
// bringing it back, deleting it, and the stash's cap, as the composer brick
// dispatches them (features/composer/editors-and-keys.feature).

#include <QVariantMap>

#include "ComposerController.h"
#include "Harness.h"
#include "NavigationController.h"
#include "World.h"

namespace {

// Whether the scenario has touched the stash yet: until then "the draft
// reads" sets the draft up, afterwards it checks it.
struct StashState {
  bool acted = false;
};

StashState& stashState(World& world) {
  return world.mc.part<StashState>();
}

QString target(World& world) {
  return world.native().controller<NavigationController>()->threadKey();
}

QString draft(World& world) {
  return world.native().controller<ComposerController>()->draft(target(world));
}

void type(World& world, const QString& text) {
  world.bridge().dispatch(QStringLiteral("composer.text.set"), QVariantMap{{QStringLiteral("target"), target(world)},
                                                                           {QStringLiteral("text"), text},
                                                                           {QStringLiteral("cursor"), text.size()}});
}

QVariantList entries(World& world) {
  return world.state(QStringLiteral("composerStash")).toMap().value(QStringLiteral("entries")).toList();
}

void stash(World& world) {
  stashState(world).acted = true;
  world.bridge().dispatch(QStringLiteral("composer.stash"));
  world.sync();
}

void stashText(World& world, const QString& text) {
  type(world, text);
  stash(world);
}

QString newest(World& world) {
  const QVariantList list = entries(world);
  if (list.isEmpty()) fail(QStringLiteral("nothing is stashed"));
  return list.constFirst().toMap().value(QStringLiteral("id")).toString();
}

void expectDraft(World& world, const QString& expected) {
  world.waitFor([&] { return draft(world) == expected; }, [&] { return QStringLiteral("the draft reads \"%1\"").arg(draft(world)); });
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the draft reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (stashState(world).acted) {
      expectDraft(world, c[0]);
    } else {
      type(world, c[0]);
      world.sync();
    }
  });
  step(QStringLiteral("the draft reads %1 and then %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectDraft(world, c[0] + QStringLiteral("\n\n") + c[1]);
  });
  step(QStringLiteral("the user stashed %1").arg(q), [](World& world, const Captures& c, const Table&) { stashText(world, c[0]); });
  step(QStringLiteral("the user stashes %1").arg(q), [](World& world, const Captures& c, const Table&) { stashText(world, c[0]); });
  step(QStringLiteral("the user stashed (\\d+) prompts"), [](World& world, const Captures& c, const Table&) {
    for (int n = 1; n <= c[0].toInt(); ++n) stashText(world, QStringLiteral("prompt %1").arg(n));
  });
  step(QStringLiteral("the user stashes the prompt(?: again)?"), [](World& world, const Captures&, const Table&) { stash(world); });
  step(QStringLiteral("the user restores the stashed prompt"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.stash.restore"), QVariantMap{{QStringLiteral("id"), newest(world)}});
    world.sync();
  });
  step(QStringLiteral("the user deletes the stashed prompt"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.stash.delete"), QVariantMap{{QStringLiteral("id"), newest(world)}});
    world.sync();
  });
  step(QStringLiteral("nothing is stashed"), [](World& world, const Captures&, const Table&) {
    expect(entries(world).isEmpty(), QStringLiteral("the stash holds %1").arg(show(entries(world))));
  });
  step(QStringLiteral("(\\d+) prompts are stashed, %1 first").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantList list = entries(world);
    expect(list.size() == c[0].toInt() && list.constFirst().toMap().value(QStringLiteral("snippet")) == c[1],
           QStringLiteral("the stash holds %1").arg(show(list)));
  });
});

}  // namespace
