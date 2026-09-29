// The composer's turn against the node: the route the composer shows, what the
// user types, picks, attaches and sends (as the brick dispatches it), the
// images the node stores, and the text the page is asked to restore
// (features/desktop/native-composer.feature).

#include <QJsonArray>
#include <QVariantMap>

#include "ComposerController.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "World.h"

namespace {

// The chat images the node stored (`assets.persistChatAttachments`); refused
// like a command, by `the node refuses "assets.persistChatAttachments" ...`.
struct FakeUploads {
  QList<QJsonObject> stored;
};

const FakeNode::Extension uploads([](FakeNode& node) {
  node.onRpc(QStringLiteral("assets.persistChatAttachments"), [&node](const FakeNode::Rpc& rpc) {
    const QString method = QStringLiteral("assets.persistChatAttachments");
    if (node.refusals.contains(method)) {
      node.refuse(rpc, node.refusals.value(method));
      return;
    }
    QJsonArray stored;
    for (const QJsonValue& value : rpc.payload.value(QLatin1String("attachments")).toArray()) {
      QJsonObject image = value.toObject();
      node.part<FakeUploads>().stored.append(image);
      image.remove(QStringLiteral("dataUrl"));
      image.insert(QStringLiteral("id"), QStringLiteral("image-%1").arg(node.part<FakeUploads>().stored.size()));
      stored.append(image);
    }
    node.reply(rpc, QJsonObject{{QStringLiteral("attachments"), stored}});
  });
});

void composerOn(World& world, const QString& target, const QString& routeKind) {
  world.composer = {
      {QStringLiteral("target"), target},
      {QStringLiteral("routeKind"), routeKind},
      {QStringLiteral("text"), QString()},
      {QStringLiteral("cursor"), 0},
  };
  world.publishComposer();
  // The page's composer is the one for the route it shows.
  if (routeKind == QLatin1String("draft")) {
    world.pageOpens({{QStringLiteral("kind"), QStringLiteral("draft")}, {QStringLiteral("draftId"), target}});
  } else {
    world.pageOpens({{QStringLiteral("kind"), QStringLiteral("thread")}, {QStringLiteral("threadKey"), target}});
  }
}

QString route(World& world) {
  return world.native().controller<NavigationController>()->threadKey();
}

QVariantMap edit(World& world) {
  return {{QStringLiteral("clientId"), QStringLiteral("qml")}, {QStringLiteral("revision"), world.nextEdit++}};
}

QVariantList attachments(World& world) {
  return world.state(QStringLiteral("turn")).toMap().value(QStringLiteral("attachments")).toList();
}

QStringList attachmentNames(World& world) {
  QStringList names;
  for (const QVariant& attachment : attachments(world)) names.append(attachment.toMap().value(QStringLiteral("name")).toString());
  return names;
}

const Steps steps([] {
  const QString q = kQuoted;

  // The composer.
  step(QStringLiteral("the composer shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    composerOn(world, c[0], QStringLiteral("server"));
  });
  step(QStringLiteral("the composer shows the draft %1").arg(q), [](World& world, const Captures& c, const Table&) {
    composerOn(world, c[0], QStringLiteral("draft"));
  });
  step(QStringLiteral("the user stops the turn"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.interrupt"));
  });
  step(QStringLiteral("the user sends %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{
                                                                   {QStringLiteral("edit"), edit(world)},
                                                                   {QStringLiteral("text"), c[0]},
                                                                   {QStringLiteral("intent"), QStringLiteral("foreground")},
                                                               });
  });
  step(QStringLiteral("the user sends the opposite way %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{
                                                                   {QStringLiteral("edit"), edit(world)},
                                                                   {QStringLiteral("text"), c[0]},
                                                                   {QStringLiteral("intent"), QStringLiteral("alternate")},
                                                               });
  });
  step(QStringLiteral("the user types %1 into the composer").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.text.set"), QVariantMap{
                                                                     {QStringLiteral("target"), route(world)},
                                                                     {QStringLiteral("edit"), edit(world)},
                                                                     {QStringLiteral("text"), c[0]},
                                                                     {QStringLiteral("cursor"), c[0].size()},
                                                                 });
  });
  step(QStringLiteral("the user picks the model %1 of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.model.select"),
                            QVariantMap{{QStringLiteral("instanceId"), c[1]}, {QStringLiteral("model"), c[0]}});
  });
  step(QStringLiteral("the user switches to the %1 and %1 modes").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.runtimeMode.set"), QVariantMap{{QStringLiteral("mode"), c[0]}});
    world.bridge().dispatch(QStringLiteral("composer.interactionMode.set"), QVariantMap{{QStringLiteral("mode"), c[1]}});
  });
  step(QStringLiteral("the composer offers the draft %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap turn = world.state(QStringLiteral("turn")).toMap();
    expect(turn.value(QStringLiteral("threadKey")) == route(world) && turn.value(QStringLiteral("draft")) == c[0],
           QStringLiteral("the composer's turn is %1").arg(show(turn)));
  });

  // A new thread's draft (DraftSteps names it).
  step(QStringLiteral("the user types %1 into the new thread").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.text.set"), QVariantMap{
                                                                     {QStringLiteral("target"), world.draftId},
                                                                     {QStringLiteral("edit"), edit(world)},
                                                                     {QStringLiteral("text"), c[0]},
                                                                     {QStringLiteral("cursor"), c[0].size()},
                                                                 });
  });
  step(QStringLiteral("the user goes back to the new thread"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("draft.open"), QVariantMap{{QStringLiteral("draftId"), world.draftId}});
  });
  step(QStringLiteral("the composer offers the new thread's text %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      const QVariantMap turn = world.state(QStringLiteral("turn")).toMap();
      return turn.value(QStringLiteral("threadKey")) == world.draftId && turn.value(QStringLiteral("draft")) == c[0];
    }, [&] { return QStringLiteral("the draft's text; the composer's turn is %1").arg(show(world.state(QStringLiteral("turn")))); });
  });

  // Images.
  step(QStringLiteral("the user attaches the image %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.attach"),
                            QVariantMap{{QStringLiteral("files"), QVariantList{QVariantMap{
                                                                      {QStringLiteral("name"), c[0]},
                                                                      {QStringLiteral("mimeType"), QStringLiteral("image/png")},
                                                                      {QStringLiteral("base64"), QStringLiteral("iVBORw0KGgo=")},
                                                                  }}}});
  });
  step(QStringLiteral("the user removes the attachment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QVariant& attachment : attachments(world)) {
      if (attachment.toMap().value(QStringLiteral("name")) == c[0]) {
        world.bridge().dispatch(QStringLiteral("composer.attachment.remove"),
                                QVariantMap{{QStringLiteral("id"), attachment.toMap().value(QStringLiteral("id"))}});
        return;
      }
    }
    fail(QStringLiteral("the composer lists %1").arg(show(attachments(world))));
  });
  step(QStringLiteral("the composer lists the attachment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return attachmentNames(world) == QStringList{c[0]}; },
                  [&] { return QStringLiteral("the attachment; the composer lists %1").arg(show(attachments(world))); });
  });
  step(QStringLiteral("the composer lists no attachments"), [](World& world, const Captures&, const Table&) {
    expect(attachments(world).isEmpty(), QStringLiteral("the composer lists %1").arg(show(attachments(world))));
  });
  step(QStringLiteral("the node stores the image %1 for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QList<QJsonObject> stored = world.node.part<FakeUploads>().stored;
    const bool found = std::any_of(stored.cbegin(), stored.cend(), [&](const QJsonObject& image) {
      return image.value(QLatin1String("name")).toString() == c[0] &&
             image.value(QLatin1String("dataUrl")).toString().startsWith(QLatin1String("data:image/png;base64,"));
    });
    QStringList names;
    for (const QJsonObject& image : stored) names.append(image.value(QLatin1String("name")).toString());
    expect(found, QStringLiteral("the node stored [%1]").arg(names.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the node stores no images"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.node.part<FakeUploads>().stored.isEmpty(), QStringLiteral("the node stored images"));
  });
  step(QStringLiteral("the message carries the image %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.command.has_value(), QStringLiteral("no command was found before"));
    const QJsonArray images = world.node.commands.at(*world.command).value(QLatin1String("attachments")).toArray();
    const bool found = std::any_of(images.begin(), images.end(), [&](const QJsonValue& image) {
      return image.toObject().value(QLatin1String("name")).toString() == c[0] &&
             !image.toObject().value(QLatin1String("id")).toString().isEmpty();
    });
    expect(found, QStringLiteral("the message carries %1").arg(show(images.toVariantList())));
  });

  // What the page is asked to show.
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
