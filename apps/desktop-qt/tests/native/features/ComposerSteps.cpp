// The composer's turn RPCs: what the page's composer shows, what the user
// sends, and the text the page is asked to restore
// (features/desktop/native-composer.feature).

#include <QVariantMap>

#include "Harness.h"
#include "World.h"

namespace {

void composerOn(World& world, const QString& target, const QString& routeKind, const QString& prompt,
                const QVariant& nativeSend) {
  world.composer = {
      {QStringLiteral("target"), target},
      {QStringLiteral("routeKind"), routeKind},
      {QStringLiteral("text"), prompt},
      {QStringLiteral("cursor"), prompt.size()},
      {QStringLiteral("nativeSend"), nativeSend},
  };
  world.publishComposer();
  // The page's composer is the one for the route it shows.
  if (routeKind == QLatin1String("draft")) {
    world.pageOpens({{QStringLiteral("kind"), QStringLiteral("draft")}, {QStringLiteral("draftId"), target}});
  } else {
    world.pageOpens({{QStringLiteral("kind"), QStringLiteral("thread")}, {QStringLiteral("threadKey"), target}});
  }
}

QVariantMap plainSend(const QString& prompt, const QString& runtimeMode, const QString& interactionMode) {
  const QString text = prompt.trimmed();
  return {
      {QStringLiteral("prompt"), prompt},
      {QStringLiteral("text"), text},
      {QStringLiteral("titleSeed"), text},
      {QStringLiteral("modelSelection"),
       QVariantMap{{QStringLiteral("instanceId"), QStringLiteral("codex")}, {QStringLiteral("model"), QStringLiteral("gpt-5")}}},
      {QStringLiteral("runtimeMode"), runtimeMode},
      {QStringLiteral("interactionMode"), interactionMode},
  };
}

const Steps steps([] {
  const QString q = kQuoted;

  // The composer.
  step(QStringLiteral("the composer shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    composerOn(world, c[0], QStringLiteral("server"), QString(), QVariant::fromValue(nullptr));
  });
  step(QStringLiteral("the composer shows %1 with the plain prompt %1").arg(q), [](World& world, const Captures& c, const Table&) {
    composerOn(world, c[0], QStringLiteral("server"), c[1], plainSend(c[1], QStringLiteral("full-access"), QStringLiteral("default")));
  });
  step(QStringLiteral("the composer shows %1 with the plain prompt %1 in %1 and %1 modes").arg(q),
       [](World& world, const Captures& c, const Table&) {
         composerOn(world, c[0], QStringLiteral("server"), c[1], plainSend(c[1], c[2], c[3]));
       });
  step(QStringLiteral("the composer shows the draft %1 with the plain prompt %1").arg(q), [](World& world, const Captures& c, const Table&) {
    composerOn(world, c[0], QStringLiteral("draft"), c[1], plainSend(c[1], QStringLiteral("full-access"), QStringLiteral("default")));
  });
  step(QStringLiteral("the user stops the turn"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.interrupt"));
  });
  step(QStringLiteral("the user sends %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.submit"),
                            QVariantMap{
                                {QStringLiteral("edit"), QVariantMap{{QStringLiteral("clientId"), QStringLiteral("qml")},
                                                                     {QStringLiteral("revision"), world.nextEdit++}}},
                                {QStringLiteral("text"), c[0]},
                                {QStringLiteral("intent"), QStringLiteral("foreground")},
                            });
  });
  step(QStringLiteral("the user types %1 into the composer").arg(q), [](World& world, const Captures& c, const Table&) {
    world.composer.insert(QStringLiteral("text"), c[0]);
    world.publishComposer();
  });

  const auto textSet = [](World& world, const QString& target, const QString& text) {
    for (const PageAction& action : world.actionsOf(QStringLiteral("composer.text.set"))) {
      if (action.payload.value(QStringLiteral("target")) == target && action.payload.value(QStringLiteral("text")) == text) {
        return true;
      }
    }
    return false;
  };
  step(QStringLiteral("the page is asked to set the composer text for %1 to %1").arg(q), [textSet](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return textSet(world, c[0], c[1]); },
                  [&] { return QStringLiteral("the composer text; the page got %1").arg(world.describePage()); });
  });
  step(QStringLiteral("the page is asked to set the composer text for %1 to the prompts:").arg(q),
       [textSet](World& world, const Captures& c, const Table& table) {
         QStringList prompts;
         for (qsizetype row = 1; row < table.size(); ++row) prompts.append(table.at(row).value(0));
         const QString text = prompts.join(QStringLiteral("\n\n"));
         world.waitFor([&] { return textSet(world, c[0], text); },
                       [&] { return QStringLiteral("the composer text; the page got %1").arg(world.describePage()); });
       });
  step(QStringLiteral("the page is not asked to set the composer text for %1 to %1").arg(q),
       [textSet](World& world, const Captures& c, const Table&) {
         world.sync();
         expect(!textSet(world, c[0], c[1]), QStringLiteral("the page got %1").arg(world.describePage()));
       });
});

}  // namespace
