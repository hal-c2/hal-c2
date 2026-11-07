// The prompt stash (ComposerController): stashing the route thread's draft,
// bringing it back, deleting it, and the stash's cap, as the composer brick
// dispatches them (features/composer/editors-and-keys.feature).

#include <QDir>
#include <QFile>
#include <QQuickItem>
#include <QVariantMap>

#include "Brick.h"
#include "ComposerBrick.h"
#include "ComposerController.h"
#include "Harness.h"
#include "NavigationController.h"
#include "World.h"

namespace {

// Whether the scenario has touched the stash yet: until then "the draft
// reads" sets the draft up, afterwards it checks it.
struct StashState {
  bool acted = false;
  // The text last stashed.
  QString stashed;
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
  stashState(world).stashed = text;
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
    if (stashState(world).acted || world.checking) {
      expectDraft(world, c[0]);
    } else {
      type(world, c[0]);
      world.sync();
      // An editor on screen shows it before the user goes on.
      if (composerBrickShown(world)) {
        world.waitFor([&] { return composerEditor(world)->property("text") == c[0]; }, QStringLiteral("the editor to show the draft"));
      }
    }
  });
  step(QStringLiteral("the composer is still empty"), [](World& world, const Captures&, const Table&) { expectDraft(world, QString()); });
  step(QStringLiteral("the draft reads %1 and then %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expectDraft(world, c[0] + QStringLiteral("\n\n") + c[1]);
  });
  step(QStringLiteral("the user stashed %1").arg(q), [](World& world, const Captures& c, const Table&) { stashText(world, c[0]); });
  step(QStringLiteral("the user stashes %1").arg(q), [](World& world, const Captures& c, const Table&) { stashText(world, c[0]); });
  step(QStringLiteral("the user stashed %1 and %1").arg(q), [](World& world, const Captures& c, const Table&) {
    stashText(world, c[0]);
    stashText(world, c[1]);
  });
  step(QStringLiteral("the user stashed a prompt of (\\d+) characters"), [](World& world, const Captures& c, const Table&) {
    QString text;
    for (int i = 0; i < c[0].toInt(); ++i) text += QChar(u'a' + i % 26);
    stashText(world, text);
  });
  step(QStringLiteral("the user stashes the prompt and the stash cannot be written"), [](World& world, const Captures&, const Table&) {
    // A folder where the stash's file goes: nothing can be written there.
    const QString path = QDir(world.homeDir()).filePath(QStringLiteral("data/shell-composer.json"));
    const QString aside = path + QStringLiteral(".aside");
    const bool had = QFile::exists(path);
    expect(!had || QFile::rename(path, aside), QStringLiteral("could not move %1 aside").arg(path));
    expect(QDir().mkpath(path), QStringLiteral("could not make %1").arg(path));
    stash(world);
    expect(QDir(path).removeRecursively() && (!had || QFile::rename(aside, path)), QStringLiteral("could not put %1 back").arg(path));
  });
  step(QStringLiteral("the user opens the stash"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.stash.menu"), QVariantMap{{QStringLiteral("open"), true}});
    world.sync();
  });
  step(QStringLiteral("the stash lists %1 and then %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantList list = entries(world);
    const auto snippet = [&](int i) { return list.value(i).toMap().value(QStringLiteral("snippet")).toString(); };
    expect(world.state(QStringLiteral("composerStash")).toMap().value(QStringLiteral("open")).toBool() && list.size() == 2 && snippet(0) == c[0] &&
               snippet(1) == c[1],
           QStringLiteral("the stash is %1").arg(show(world.state(QStringLiteral("composerStash")))));
  });
  // A listed text in quotes may hold quotes of its own.
  step(QStringLiteral("the prompt is listed as \"(.*)\""), [](World& world, const Captures& c, const Table&) {
    const QString expected =
        c[0] == QStringLiteral("its first 90 characters and \"…\"") ? stashState(world).stashed.left(90) + QStringLiteral("…") : c[0];
    const QString listed = entries(world).value(0).toMap().value(QStringLiteral("snippet")).toString();
    expect(listed == expected, QStringLiteral("the stash lists \"%1\"").arg(listed));
  });
  step(QStringLiteral("the prompt says how long ago it was stashed"), [](World& world, const Captures&, const Table&) {
    QQuickItem* age = composerBrick(world).find(QStringLiteral("stashAge-0"));
    expect(age && age->isVisible(), QStringLiteral("the stash shows no age for its prompt"));
    expect(age->property("text") == QLatin1String("just now"), QStringLiteral("the prompt was stashed \"%1\"").arg(age->property("text").toString()));
  });
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
