// Editing from one of the user's messages (RewindController;
// features/timeline/checkpoints.feature): the thread is PanelSteps' "three
// finished turns", whose second message here has a prompt of its own and an
// image the MC serves (`assets.createUrl`, then a GET of the signed URL).
// Driven from the message's own button on the ThreadView brick and the
// "Edit from here?" dialog.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QTcpSocket>
#include <QTest>

#include <memory>

#include "Brick.h"
#include "ComposerController.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "NavigationController.h"
#include "Stream.h"
#include "World.h"

namespace {

using namespace stream;

const QString kPrompt = QStringLiteral("check the tax rate");
const QByteArray kImage = QByteArrayLiteral("\x89PNG\r\n\x1a\ncart");

// What the MC was asked for while rewinding.
struct FakeRewind {
  QStringList downloaded;  // the paths of the attachment bytes it served
  bool prepared = false;
  QString second;  // the second message's row
};

// The row of the user's second message.
QString second(World& world) {
  FakeRewind& fake = world.mc.part<FakeRewind>();
  if (!fake.second.isEmpty()) return fake.second;
  TimelineModel& model = timeline(world);
  QStringList mine;
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::KindRole) == QLatin1String("message") && role(model, row, TimelineModel::AuthorRole) == QLatin1String("user")) {
      mine.append(role(model, row, TimelineModel::IdRole).toString());
    }
  }
  if (mine.size() < 3) fail(QStringLiteral("the thread has %1 messages of the user's; %2").arg(mine.size()).arg(describe(model)));
  fake.second = mine.at(1);
  return fake.second;
}

QString threadKey(World& world) {
  return world.mc.environmentId + QLatin1Char(':') + kThread;
}

ComposerController& composer(World& world) {
  return *world.native().controller<ComposerController>();
}

// The second message as the user sent it: its prompt and one image, which
// the MC still holds.
void prepare(World& world) {
  FakeRewind& fake = world.mc.part<FakeRewind>();
  if (fake.prepared) return;
  fake.prepared = true;
  set(world, QStringLiteral("turn-item"), second(world),
      {{QStringLiteral("text"), kPrompt},
       {QStringLiteral("attachments"), QJsonArray{QJsonObject{{QStringLiteral("type"), QStringLiteral("image")}, {QStringLiteral("id"), QStringLiteral("att-1")},
                                                              {QStringLiteral("name"), QStringLiteral("cart.png")}, {QStringLiteral("mimeType"), QStringLiteral("image/png")},
                                                              {QStringLiteral("sizeBytes"), kImage.size()}}}}});
  world.mc.onRpc(QStringLiteral("assets.createUrl"), [&mc = world.mc](const FakeMc::Rpc& rpc) {
    const QString id = rpc.payload.value(QLatin1String("resource")).toObject().value(QLatin1String("attachmentId")).toString();
    mc.reply(rpc, QJsonObject{{QStringLiteral("relativeUrl"), QStringLiteral("/assets/%1?signature=abc").arg(id)}, {QStringLiteral("expiresAt"), 1790000000000.0}});
  });
  world.mc.onRaw(QStringLiteral("/assets/"), [&mc = world.mc](QTcpSocket* socket, const QByteArray& head) {
    mc.part<FakeRewind>().downloaded.append(QString::fromUtf8(head.left(head.indexOf('\r')).split(' ').value(1)));
    socket->readAll();
    socket->write("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nConnection: close\r\nContent-Length: " + QByteArray::number(kImage.size()) + "\r\n\r\n" + kImage);
    socket->disconnectFromHost();
  });
}

// The open thread with the dialog that asks before rewinding.
Brick& view(World& world) {
  if (!world.brick) {
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nItem { ThreadView { anchors.fill: parent }\n EditFromHereDialog {} }\n", QSize(820, 1000));
  }
  return *world.brick;
}

QQuickItem* find(QQuickItem* item, const std::function<bool(QQuickItem*)>& matches) {
  if (matches(item)) return item;
  for (QQuickItem* child : item->childItems()) {
    if (QQuickItem* found = find(child, matches)) return found;
  }
  return nullptr;
}

// The second message's own "Edit from here".
void editFromSecond(World& world) {
  prepare(world);
  Brick& brick = view(world);
  // The message's row, by its text.
  QQuickItem* body = nullptr;
  world.waitFor([&] {
    brick.grab();
    body = find(brick.window().contentItem(), [](QQuickItem* item) {
      return item->objectName() == QLatin1String("userMessageBody") && find(item, [](QQuickItem* child) { return child->property("text").toString() == kPrompt; }) != nullptr;
    });
    return body != nullptr;
  }, QStringLiteral("the second message to be drawn"));
  // Its actions show while the pointer is over it.
  QTest::mouseMove(&brick.window(), brick.at(body, 0.5, 0.5) + QPoint(0, 4));
  QTest::mouseMove(&brick.window(), brick.at(body, 0.5, 0.5));
  QQuickItem* button = nullptr;
  world.waitFor([&] {
    button = find(body->parentItem(), [](QQuickItem* item) { return item->objectName() == QLatin1String("editFromHere") && item->isVisible(); });
    return button != nullptr;
  }, QStringLiteral("the message to offer Edit from here"));
  QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(button));
  world.sync();
}

QList<QJsonObject> rollbacks(World& world) {
  QList<QJsonObject> found;
  for (const QJsonObject& command : std::as_const(world.mc.commands)) {
    if (command.value(QLatin1String("type")) == QLatin1String("checkpoint.rollback")) found.append(command);
  }
  return found;
}

QStringList answers(World& world) {
  QStringList texts;
  TimelineModel& model = timeline(world);
  for (int row = 0; row < model.rowCount(); ++row) {
    const QString text = role(model, row, TimelineModel::TextRole).toString();
    if (text.startsWith(QLatin1String("Answer "))) texts.append(text);
  }
  return texts;
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the composer holds the draft %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.text.set"), QVariantMap{{QStringLiteral("target"), threadKey(world)}, {QStringLiteral("text"), c[0]}, {QStringLiteral("cursor"), c[0].size()}});
    expect(composer(world).draft(threadKey(world)) == c[0], QStringLiteral("the draft reads \"%1\"").arg(composer(world).draft(threadKey(world))));
  });
  step(QStringLiteral("the user edits from the second message and reverts the files too"), [](World& world, const Captures&, const Table&) {
    editFromSecond(world);
    Brick& brick = view(world);
    world.waitFor([&] { return brick.shows(QStringLiteral("Edit from here?")); }, [&] { return QStringLiteral("the question; the shell shows %1").arg(show(world.state(QStringLiteral("toasts")))); });
    expect(rollbacks(world).isEmpty(), QStringLiteral("the thread was rewound before the user answered"));
    brick.click(QStringLiteral("editFromHereRevertFiles"));
  });
  step(QStringLiteral("the conversation rewinds to before the second message"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return rollbacks(world).size() == 1; }, [&] { return QStringLiteral("the rollback; the MC has %1; the shell shows %2").arg(world.describeCommands(), show(world.state(QStringLiteral("toasts")))); });
    const QJsonObject rollback = rollbacks(world).first();
    expect(rollback.value(QLatin1String("threadId")) == kThread && rollback.value(QLatin1String("checkpointId")) == QLatin1String("cp-1") &&
               rollback.value(QLatin1String("scopeId")) == QLatin1String("scope-1") && rollback.value(QLatin1String("restoreFiles")).toBool(),
           QStringLiteral("the rollback was %1").arg(show(rollback.toVariantMap())));
    // Turn 1 stays; the second message and what followed are gone.
    world.waitFor([&] { return answers(world) == QStringList{QStringLiteral("Answer 1")}; }, [&] { return describe(timeline(world)); });
    expect(timeline(world).indexOf(second(world)) < 0, QStringLiteral("the second message is still shown"));
  });
  step(QStringLiteral("the second message's prompt and attachments are added to the draft"), [](World& world, const Captures&, const Table&) {
    const QString wanted = QStringLiteral("also check tax\n\n") + kPrompt;
    world.waitFor([&] { return composer(world).draft(threadKey(world)) == wanted && composer(world).attachments(threadKey(world)).size() == 1; },
                  [&] { return QStringLiteral("the draft reads \"%1\" with %2 attachments").arg(composer(world).draft(threadKey(world))).arg(composer(world).attachments(threadKey(world)).size()); });
    const QVariantMap image = composer(world).attachments(threadKey(world)).first().toMap();
    expect(image.value(QStringLiteral("name")) == QLatin1String("cart.png") && image.value(QStringLiteral("mimeType")) == QLatin1String("image/png") &&
               image.value(QStringLiteral("sizeBytes")).toInt() == kImage.size(),
           QStringLiteral("the draft carries %1").arg(show(image)));
    // Read from the MC by the address it signed.
    expect(world.mc.part<FakeRewind>().downloaded == QStringList{QStringLiteral("/assets/att-1?signature=abc")},
           QStringLiteral("the MC served %1").arg(world.mc.part<FakeRewind>().downloaded.join(u", ")));
  });

  step(QStringLiteral("the user starts editing from the second message"), [](World& world, const Captures&, const Table&) {
    editFromSecond(world);
    world.waitFor([&] { return view(world).shows(QStringLiteral("Edit from here?")); }, QStringLiteral("the question to be asked"));
  });
  step(QStringLiteral("the conversation and the workspace are unchanged"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.state(QStringLiteral("rewind")).isNull() && rollbacks(world).isEmpty(), QStringLiteral("the MC has %1").arg(world.describeCommands()));
    expect(answers(world).size() == 3 && timeline(world).indexOf(second(world)) >= 0, describe(timeline(world)));
    expect(composer(world).draft(threadKey(world)).isEmpty() && world.mc.part<FakeRewind>().downloaded.isEmpty(), QStringLiteral("the draft or the attachments were touched"));
  });

  // Why a rewind cannot happen.
  step(QStringLiteral("the provider cannot rewind its history"), [](World& world, const Captures&, const Table&) {
    QJsonObject& row = world.mc.threads[kThread];
    row.insert(QStringLiteral("modelSelection"), QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("opencode")}, {QStringLiteral("model"), QStringLiteral("big-pickle")}});
    world.mc.sendRow(kThread, row);
    publishProviders(world.mc, QJsonArray{QJsonObject{{QStringLiteral("instanceId"), QStringLiteral("opencode")}, {QStringLiteral("driver"), QStringLiteral("opencode")},
                                                      {QStringLiteral("status"), QStringLiteral("ready")}, {QStringLiteral("models"), QJsonArray()},
                                                      {QStringLiteral("supportsConversationRollback"), false}}});
    world.sync();
  });
  step(QStringLiteral("the message's attachments are still preparing"), [](World& world, const Captures&, const Table&) {
    // A message with an image is on its way: the MC has not answered for its upload yet.
    world.mc.hold(QStringLiteral("answers"));
    world.mc.onRpc(QStringLiteral("assets.persistChatAttachments"), [&mc = world.mc](const FakeMc::Rpc& rpc) {
      mc.defer([&mc, rpc] { mc.reply(rpc, QJsonObject{{QStringLiteral("attachments"), QJsonArray()}}); });
    });
    composer(world).attachImage(threadKey(world), QStringLiteral("receipt.png"), QStringLiteral("image/png"), kImage);
    world.bridge().dispatch(QStringLiteral("composer.submit"), QVariantMap{{QStringLiteral("text"), QStringLiteral("and this receipt")}, {QStringLiteral("intent"), QStringLiteral("foreground")}});
    expect(composer(world).attachmentsPending(threadKey(world)), QStringLiteral("no attachment is on its way"));
  });
  step(QStringLiteral("the composer has no room for the attachments"), [](World& world, const Captures&, const Table&) {
    for (int n = 0; n < 100; ++n) composer(world).attachImage(threadKey(world), QStringLiteral("shot-%1.png").arg(n), QStringLiteral("image/png"), kImage);
    expect(composer(world).attachments(threadKey(world)).size() == 100, QStringLiteral("the draft carries %1 attachments").arg(composer(world).attachments(threadKey(world)).size()));
  });
  step(QStringLiteral("the user edits from the second message"), [](World& world, const Captures&, const Table&) {
    editFromSecond(world);
    // Asked, the user keeps the files as they are.
    if (!world.state(QStringLiteral("rewind")).isNull()) {
      world.waitFor([&] { return view(world).item(QStringLiteral("editFromHereKeepFiles"))->isVisible(); }, QStringLiteral("the question to be asked"));
      view(world).click(QStringLiteral("editFromHereKeepFiles"));
      world.sync();
    }
    // Refused, nothing was rewound.
    expect(rollbacks(world).isEmpty(), QStringLiteral("the thread was rewound: %1").arg(world.describeCommands()));
  });
});

}  // namespace

bool cancelRewindQuestion(World& world) {
  if (world.state(QStringLiteral("rewind")).isNull()) return false;
  view(world).click(QStringLiteral("editFromHereCancel"));
  world.sync();
  return true;
}
