// The composer's turn against the MC: the route the composer shows, what the
// user types, picks, attaches and sends (as the brick dispatches it), the
// images the MC stores, the text the shell's composer holds, and what became
// of a send the app quit on (features/composer/sending-turns.feature,
// desktop/native-composer.feature).

#include <QBuffer>
#include <QDir>
#include <QFile>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QVariantMap>

#include "ComposerController.h"
#include "DraftController.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "Stream.h"
#include "World.h"

namespace {

// The chat images the MC stored (`assets.persistChatAttachments`); refused
// like a command, by `the MC refuses "assets.persistChatAttachments" ...`.
struct FakeUploads {
  QList<QJsonObject> stored;
};

const FakeMc::Extension uploads([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("assets.persistChatAttachments"), [&mc](const FakeMc::Rpc& rpc) {
    const QString method = QStringLiteral("assets.persistChatAttachments");
    if (mc.refusals.contains(method)) {
      mc.refuse(rpc, mc.refusals.value(method));
      return;
    }
    QJsonArray stored;
    for (const QJsonValue& value : rpc.payload.value(QLatin1String("attachments")).toArray()) {
      QJsonObject image = value.toObject();
      image.insert(QStringLiteral("threadId"), rpc.payload.value(QLatin1String("threadId")));
      mc.part<FakeUploads>().stored.append(image);
      image.remove(QStringLiteral("threadId"));
      image.remove(QStringLiteral("dataUrl"));
      image.insert(QStringLiteral("id"), QStringLiteral("image-%1").arg(mc.part<FakeUploads>().stored.size()));
      stored.append(image);
    }
    mc.reply(rpc, QJsonObject{{QStringLiteral("attachments"), stored}});
  });
});

// The text the shell's composer keeps for the thread or draft.
QString textOf(World& world, const QString& target) {
  return world.native().controller<ComposerController>()->draft(target);
}

// What the composer brick is shown.
QVariantMap shown(World& world) {
  return world.state(QStringLiteral("composer")).toMap();
}

QString route(World& world) {
  return world.native().controller<NavigationController>()->threadKey();
}

QVariantMap edit(World& world) {
  return {{QStringLiteral("clientId"), QStringLiteral("qml")}, {QStringLiteral("revision"), world.nextEdit++}};
}

QVariantList attachments(World& world) {
  return world.state(QStringLiteral("composer")).toMap().value(QStringLiteral("attachments")).toList();
}

QStringList attachmentNames(World& world) {
  QStringList names;
  for (const QVariant& attachment : attachments(world)) names.append(attachment.toMap().value(QStringLiteral("name")).toString());
  return names;
}

// A user message in the stream of `thread`, as the MC's projection keeps it;
// only the MC's copy changes while no app is connected.
void addUserMessage(World& world, const QString& thread, const QString& id, const QString& text) {
  stream::FakeStreams& fake = world.mc.part<stream::FakeStreams>();
  const QString current = std::exchange(fake.thread, thread);
  stream::change(world, QStringLiteral("message"), id,
                 {{QStringLiteral("s"), QJsonObject{{QStringLiteral("id"), id}, {QStringLiteral("role"), QStringLiteral("user")},
                                                    {QStringLiteral("createdBy"), QStringLiteral("user")}, {QStringLiteral("text"), text},
                                                    {QStringLiteral("createdAt"), stream::iso(world.now())}}}},
                 !world.mc.connected());
  fake.thread = current;
}

const Steps steps([] {
  const QString q = kQuoted;

  // The composer.
  step(QStringLiteral("the composer shows %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("thread.open"), QVariantMap{{QStringLiteral("key"), c[0]}});
  });
  // The thread open and its stream live, so the shell knows its messages.
  step(QStringLiteral("the user is reading %1").arg(q), [](World& world, const Captures& c, const Table&) {
    stream::look(world, c[0]);
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
    // The picker offers what the MC's providers list.
    const QJsonArray providers = fakeConfig(world.mc).config.value(QLatin1String("providers")).toArray();
    const bool offered = std::any_of(providers.begin(), providers.end(), [&](const QJsonValue& entry) {
      return entry.toObject().value(QLatin1String("instanceId")) == c[1];
    });
    if (!offered) {
      publishProviders(world.mc, QJsonArray{QJsonObject{
                                       {QStringLiteral("instanceId"), c[1]},
                                       {QStringLiteral("driver"), c[1]},
                                       {QStringLiteral("enabled"), true},
                                       {QStringLiteral("status"), QStringLiteral("ready")},
                                       {QStringLiteral("models"), QJsonArray{QJsonObject{{QStringLiteral("slug"), c[0]}}}},
                                   }});
      world.sync();
    }
    world.bridge().dispatch(QStringLiteral("composer.model.select"),
                            QVariantMap{{QStringLiteral("instanceId"), c[1]}, {QStringLiteral("model"), c[0]}});
  });
  step(QStringLiteral("the user switches to the %1 and %1 modes").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.runtimeMode.set"), QVariantMap{{QStringLiteral("mode"), c[0]}});
    world.bridge().dispatch(QStringLiteral("composer.interactionMode.set"), QVariantMap{{QStringLiteral("mode"), c[1]}});
  });
  step(QStringLiteral("the composer offers the draft %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap composer = shown(world);
    expect(composer.value(QStringLiteral("target")) == route(world) && composer.value(QStringLiteral("text")) == c[0],
           QStringLiteral("the composer shows %1").arg(show(composer)));
  });

  step(QStringLiteral("the composer is in %1 mode").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return shown(world).value(QStringLiteral("interactionMode")) == c[0]; },
                  [&] { return QStringLiteral("the mode; the composer shows %1").arg(show(shown(world))); });
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
      const QVariantMap composer = shown(world);
      return composer.value(QStringLiteral("target")) == world.draftId && composer.value(QStringLiteral("text")) == c[0];
    }, [&] { return QStringLiteral("the draft's text; the composer shows %1").arg(show(shown(world))); });
  });

  // Images.
  step(QStringLiteral("the user attaches the image %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QImage picture(400, 200, QImage::Format_RGB32);
    picture.fill(Qt::darkCyan);
    QByteArray png;
    QBuffer buffer(&png);
    buffer.open(QIODevice::WriteOnly);
    picture.save(&buffer, "PNG");
    world.bridge().dispatch(QStringLiteral("composer.attach"),
                            QVariantMap{{QStringLiteral("files"), QVariantList{QVariantMap{
                                                                      {QStringLiteral("name"), c[0]},
                                                                      {QStringLiteral("mimeType"), QStringLiteral("image/png")},
                                                                      {QStringLiteral("base64"), QString::fromLatin1(png.toBase64())},
                                                                  }}}});
  });
  step(QStringLiteral("the composer shows a thumbnail of %1").arg(q), [](World& world, const Captures& c, const Table&) {
    for (const QVariant& attachment : attachments(world)) {
      if (attachment.toMap().value(QStringLiteral("name")) != c[0]) continue;
      const QString preview = attachment.toMap().value(QStringLiteral("preview")).toString();
      const QImage thumbnail = QImage::fromData(QByteArray::fromBase64(preview.section(QLatin1Char(','), 1).toLatin1()));
      // The middle square of the 400x200 picture, scaled down.
      expect(preview.startsWith(QLatin1String("data:image/png;base64,")) && thumbnail.size() == QSize(128, 128),
             QStringLiteral("the thumbnail is %1x%2").arg(thumbnail.width()).arg(thumbnail.height()));
      return;
    }
    fail(QStringLiteral("the composer lists %1").arg(show(attachments(world))));
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
  step(QStringLiteral("the MC stores the image %1 for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const QList<QJsonObject> stored = world.mc.part<FakeUploads>().stored;
    const bool found = std::any_of(stored.cbegin(), stored.cend(), [&](const QJsonObject& image) {
      return image.value(QLatin1String("name")).toString() == c[0] &&
             image.value(QLatin1String("dataUrl")).toString().startsWith(QLatin1String("data:image/png;base64,"));
    });
    QStringList names;
    for (const QJsonObject& image : stored) names.append(image.value(QLatin1String("name")).toString());
    expect(found, QStringLiteral("the MC stored [%1]").arg(names.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the MC stores the image %1 for the draft's thread").arg(q), [](World& world, const Captures& c, const Table&) {
    // The draft's thread id, or once it launched, the thread the window moved to.
    const auto draft = world.native().controller<DraftController>()->draft(world.draftId);
    world.waitFor([&] { return !world.mc.part<FakeUploads>().stored.isEmpty(); }, [] { return QStringLiteral("an image stored"); });
    const QString threadId = draft ? draft->threadId : route(world).section(u':', 1);
    const QList<QJsonObject> stored = world.mc.part<FakeUploads>().stored;
    const bool found = std::any_of(stored.cbegin(), stored.cend(), [&](const QJsonObject& image) {
      return image.value(QLatin1String("name")) == c[0] && image.value(QLatin1String("threadId")) == threadId;
    });
    QStringList seen;
    for (const QJsonObject& image : stored) {
      seen.append(image.value(QLatin1String("name")).toString() + QStringLiteral(" for ") + image.value(QLatin1String("threadId")).toString());
    }
    expect(found && !threadId.isEmpty(), QStringLiteral("the MC stored [%1], not for %2").arg(seen.join(QStringLiteral(", ")), threadId));
  });
  step(QStringLiteral("the MC stores no images"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.mc.part<FakeUploads>().stored.isEmpty(), QStringLiteral("the MC stored images"));
  });
  step(QStringLiteral("the message carries the image %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.command.has_value(), QStringLiteral("no command was found before"));
    const QJsonArray images = world.mc.commands.at(*world.command).value(QLatin1String("attachments")).toArray();
    const bool found = std::any_of(images.begin(), images.end(), [&](const QJsonValue& image) {
      return image.toObject().value(QLatin1String("name")).toString() == c[0] &&
             !image.toObject().value(QLatin1String("id")).toString().isEmpty();
    });
    expect(found, QStringLiteral("the message carries %1").arg(show(images.toVariantList())));
  });

  // A send the MC still held when the app quit: it carries it out (its message
  // is in the thread), or drops it as if it never arrived.
  step(QStringLiteral("the MC carries out the send"), [](World& world, const Captures&, const Table&) {
    world.mc.effects.append([&world](const QJsonObject& command) {
      if (command.value(QLatin1String("type")) != QLatin1String("message.dispatch")) return;
      addUserMessage(world, command.value(QLatin1String("threadId")).toString(), command.value(QLatin1String("messageId")).toString(),
                     command.value(QLatin1String("text")).toString());
    });
    world.mc.answerHeld();
    world.mc.effects.removeLast();
  });
  step(QStringLiteral("the MC drops the send"), [](World& world, const Captures&, const Table&) {
    world.mc.dropHeld();
  });
  // Settled, not left waiting: shell-composer.json keeps no send to reconcile.
  step(QStringLiteral("the desktop keeps no unsent prompts"), [](World& world, const Captures&, const Table&) {
    const auto unsent = [&] {
      QFile file(QDir(world.homeDir()).filePath(QStringLiteral("data/shell-composer.json")));
      if (!file.open(QIODevice::ReadOnly)) return QJsonArray();
      return QJsonDocument::fromJson(file.readAll()).object().value(QLatin1String("unsent")).toArray();
    };
    world.waitFor([&] { return unsent().isEmpty(); },
                  [&] { return QStringLiteral("no unsent prompts; the desktop keeps %1").arg(show(unsent().toVariantList())); });
  });
  step(QStringLiteral("the thread %1 gets the user message %1 from another device").arg(q), [](World& world, const Captures& c, const Table&) {
    addUserMessage(world, c[0], QStringLiteral("message-") + c[1], c[1]);
  });

  // The text the composer keeps.
  step(QStringLiteral("the composer's text for %1 is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return textOf(world, c[0]) == c[1]; },
                  [&] { return QStringLiteral("the composer's text; it is %1").arg(show(textOf(world, c[0]))); });
  });
  step(QStringLiteral("the composer's text for %1 is the prompts:").arg(q), [](World& world, const Captures& c, const Table& table) {
    QStringList prompts;
    for (qsizetype row = 1; row < table.size(); ++row) prompts.append(table.at(row).value(0));
    const QString text = prompts.join(QStringLiteral("\n\n"));
    world.waitFor([&] { return textOf(world, c[0]) == text; },
                  [&] { return QStringLiteral("the composer's text; it is %1").arg(show(textOf(world, c[0]))); });
  });
});

}  // namespace
