// What a draft carries besides its text, as the composer brick on screen
// takes it (ComposerBrick.h): images and files chosen, dropped and pasted,
// their uploads, and removing them (features/composer/attachments.feature).

#include <QClipboard>
#include <QDir>
#include <QFile>
#include <QGuiApplication>
#include <QDragEnterEvent>
#include <QDropEvent>
#include <QImage>
#include <QJsonArray>
#include <QJsonObject>
#include <QMimeData>
#include <QQuickItem>
#include <QTest>
#include <QUrl>

#include "Brick.h"
#include "ComposerBrick.h"
#include "ComposerController.h"
#include "Harness.h"
#include "NavigationController.h"
#include "Stream.h"
#include "World.h"

namespace {

// `attachments.createUploadUrl` and the upload it hands out, as the MC's
// (apps/server-ex lib/hal_c2/attachments.ex): an id for the pending upload
// and a signed URL that takes its bytes. `refuse` fails the upload itself.
struct FakeFileUploads {
  QList<QJsonObject> asked;
  QStringList stored;  // the ids whose bytes arrived
  QStringList deleted;
  QString refuse;
};

const FakeMc::Extension fileUploads([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("attachments.createUploadUrl"), [&mc](const FakeMc::Rpc& rpc) {
    FakeFileUploads& fake = mc.part<FakeFileUploads>();
    fake.asked.append(rpc.payload);
    const QString id = QStringLiteral("pending-%1").arg(fake.asked.size());
    const QString url = QStringLiteral("/api/attachments/upload/token-%1").arg(fake.asked.size());
    mc.onHttp(url, [&mc, id](const QJsonObject&, std::function<void(int, const QJsonObject&)> respond) {
      FakeFileUploads& fake = mc.part<FakeFileUploads>();
      if (!fake.refuse.isEmpty()) {
        respond(502, {{QStringLiteral("message"), fake.refuse}});
        return;
      }
      fake.stored.append(id);
      respond(204, {});
    });
    const auto answer = [&mc, rpc, id, url] {
      mc.reply(rpc, QJsonObject{{QStringLiteral("attachmentId"), id}, {QStringLiteral("relativeUrl"), url}, {QStringLiteral("expiresAt"), 4102444800000.0}});
    };
    if (mc.holding(QStringLiteral("uploads"))) {
      mc.defer(answer);
    } else {
      answer();
    }
  });
  mc.onRpc(QStringLiteral("attachments.delete"), [&mc](const FakeMc::Rpc& rpc) {
    mc.part<FakeFileUploads>().deleted.append(rpc.payload.value(QLatin1String("attachmentId")).toString());
    mc.reply(rpc, QJsonValue::Null);
  });
});

// What the draft read before the user took something off it.
struct Typed {
  QString text;
};

QVariantMap composer(World& world) {
  return world.state(QStringLiteral("composer")).toMap();
}

QStringList carried(World& world) {
  QStringList names;
  for (const QVariant& attachment : composer(world).value(QStringLiteral("attachments")).toList()) {
    names.append(attachment.toMap().value(QStringLiteral("name")).toString());
  }
  return names;
}

// A real image file of that name on this machine.
QUrl imageFile(World& world, const QString& name) {
  const QDir dir(world.homeDir() + QStringLiteral("/pictures"));
  expect(dir.mkpath(QStringLiteral(".")), QStringLiteral("could not make %1").arg(dir.path()));
  QImage image(4, 4, QImage::Format_RGB32);
  image.fill(Qt::darkCyan);
  expect(image.save(dir.filePath(name)), QStringLiteral("could not write %1").arg(name));
  return QUrl::fromLocalFile(dir.filePath(name));
}

// What the picker's accept hands the composer.
void choose(World& world, const QList<QUrl>& urls) {
  QVariantList list;
  for (const QUrl& url : urls) list.append(url);
  QMetaObject::invokeMethod(composerItem(world), "attach", Q_ARG(QVariant, QVariant(list)));
  world.sync();
}

// Drops `data` on the composer's card, as the platform delivers a drag.
void drop(World& world, QMimeData& data) {
  Brick& brick = composerBrick(world);
  const QPoint at = brick.at(composerEditor(world));
  QDragEnterEvent enter(at, Qt::CopyAction, &data, Qt::LeftButton, Qt::NoModifier);
  QCoreApplication::sendEvent(&brick.window(), &enter);
  QDragMoveEvent move(at, Qt::CopyAction, &data, Qt::LeftButton, Qt::NoModifier);
  QCoreApplication::sendEvent(&brick.window(), &move);
  QDropEvent event(at, Qt::CopyAction, &data, Qt::LeftButton, Qt::NoModifier);
  QCoreApplication::sendEvent(&brick.window(), &event);
  world.sync();
}

QVariantMap attachment(World& world, const QString& name) {
  for (const QVariant& entry : composer(world).value(QStringLiteral("attachments")).toList()) {
    if (entry.toMap().value(QStringLiteral("name")) == name) return entry.toMap();
  }
  return {};
}

void waitForUpload(World& world, const QString& name, const QString& status) {
  world.waitFor([&] { return !attachment(world, name).isEmpty() && attachment(world, name).value(QStringLiteral("status")) == status; },
                [&] { return QStringLiteral("%1's upload to be \"%2\"; the draft carries %3").arg(name, status, show(composer(world).value(QStringLiteral("attachments")))); });
}

// A file of that name on this machine.
QUrl plainFile(World& world, const QString& name, const QByteArray& content = "create table carts (id integer);\n") {
  const QDir dir(world.homeDir() + QStringLiteral("/documents"));
  expect(dir.mkpath(QStringLiteral(".")), QStringLiteral("could not make %1").arg(dir.path()));
  QFile file(dir.filePath(name));
  expect(file.open(QIODevice::WriteOnly) && file.write(content) == content.size(), QStringLiteral("could not write %1").arg(name));
  return QUrl::fromLocalFile(dir.filePath(name));
}

QList<QJsonObject> commandsOf(World& world, const QString& type) {
  world.sync();
  QList<QJsonObject> found;
  for (const QJsonObject& command : world.mc.commands) {
    if (command.value(QLatin1String("type")) == type) found.append(command);
  }
  return found;
}

QVariantList toasts(World& world) {
  return world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
}

bool told(World& world, const QString& title, const QString& description = {}) {
  const QVariantList shown = toasts(world);
  return std::any_of(shown.cbegin(), shown.cend(), [&](const QVariant& toast) {
    return toast.toMap().value(QStringLiteral("title")) == title && (description.isEmpty() || toast.toMap().value(QStringLiteral("description")) == description);
  });
}

QString draftText(World& world) {
  const auto route = world.native().controller<NavigationController>()->route();
  return world.native().controller<ComposerController>()->draft(route.kind == QLatin1String("draft") ? route.draftId : route.threadKey);
}

// 40 KiB of log lines.
QString logOutput() {
  QString log;
  for (int line = 1; log.size() < 40 * 1024; ++line) log += QStringLiteral("%1 PASS cart totals add up with the tax line\n").arg(line, 5);
  return log.left(40 * 1024);
}

void paste(World& world, bool asText) {
  composerBrick(world);
  QGuiApplication::clipboard()->setText(logOutput());
  expect(pressInComposer(world, asText ? QStringLiteral("mod+shift+v") : QStringLiteral("mod+v")), QStringLiteral("the composer did not take the paste"));
}

void expectInserted(World& world) {
  settleComposer(world);
  expect(composerEditor(world)->property("text") == logOutput() && draftText(world) == logOutput(),
         QStringLiteral("the draft holds %1 characters").arg(draftText(world).size()));
  // Where it can be edited.
  typeInComposer(world, QStringLiteral("!"));
  expect(composerEditor(world)->property("text").toString().size() == logOutput().size() + 1, QStringLiteral("the editor did not take a key"));
}

QQuickItem* chip(World& world, const QString& name) {
  QQuickItem* item = composerPart(world, QStringLiteral("attachment:") + name);
  expect(item != nullptr, QStringLiteral("the composer shows no %1; the draft carries %2").arg(name, carried(world).join(u", ")));
  return item;
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user chooses %1 to attach").arg(q), [](World& world, const Captures& c, const Table&) {
    composerBrick(world);
    choose(world, {imageFile(world, c[0])});
  });
  step(QStringLiteral("the user drops %1 and %1 onto the composer").arg(q), [](World& world, const Captures& c, const Table&) {
    composerBrick(world);
    QMimeData data;
    data.setUrls({imageFile(world, c[0]), imageFile(world, c[1])});
    drop(world, data);
    world.mc.part<Typed>().text = c[0] + QLatin1Char('\n') + c[1];
  });
  step(QStringLiteral("the draft carries %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (!world.checking) {
      // With something typed beside it.
      const QString text = QStringLiteral("What is wrong here?");
      world.bridge().dispatch(QStringLiteral("composer.text.set"),
                              QVariantMap{{QStringLiteral("target"), world.native().controller<NavigationController>()->threadKey()},
                                          {QStringLiteral("text"), text}, {QStringLiteral("cursor"), text.size()}});
      composerBrick(world);
      choose(world, {imageFile(world, c[0])});
    }
    world.waitFor([&] { return carried(world) == QStringList{c[0]}; }, [&] { return QStringLiteral("the draft to carry %1; it carries %2").arg(c[0], carried(world).join(u", ")); });
    expect(chip(world, c[0])->isVisible(), QStringLiteral("%1 is not shown").arg(c[0]));
  });
  step(QStringLiteral("the draft carries both images"), [](World& world, const Captures&, const Table&) {
    const QStringList dropped = world.mc.part<Typed>().text.split(QLatin1Char('\n'));
    world.waitFor([&] { return carried(world) == dropped; }, [&] { return QStringLiteral("the draft to carry %1; it carries %2").arg(dropped.join(u", "), carried(world).join(u", ")); });
    for (const QString& name : dropped) expect(chip(world, name)->isVisible(), QStringLiteral("%1 is not shown").arg(name));
  });
  step(QStringLiteral("sending the message sends the image with it"), [](World& world, const Captures&, const Table&) {
    const QStringList names = carried(world);
    typeInComposer(world, QStringLiteral("look"));
    pressInComposer(world, QStringLiteral("Enter"));
    const auto message = [&]() -> QJsonObject {
      for (const QJsonObject& command : world.mc.commands) {
        if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch")) return command;
      }
      return {};
    };
    world.waitFor([&] { return !message().isEmpty(); }, [&] { return QStringLiteral("the message; the MC has %1").arg(world.describeCommands()); });
    const QJsonArray sent = message().value(QLatin1String("attachments")).toArray();
    expect(sent.size() == 1 && sent.first().toObject().value(QLatin1String("name")) == names.value(0) &&
               !sent.first().toObject().value(QLatin1String("id")).toString().isEmpty(),
           QStringLiteral("the message carries %1").arg(show(sent.toVariantList())));
  });
  // A file's upload.
  step(QStringLiteral("the upload of %1 failed").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.part<FakeFileUploads>().refuse = QStringLiteral("The MC holding this upload is unavailable.");
    composerBrick(world);
    QMimeData data;
    data.setUrls({plainFile(world, c[0])});
    drop(world, data);
    waitForUpload(world, c[0], QStringLiteral("failed"));
    world.mc.part<Typed>().text = c[0];
  });
  step(QStringLiteral("the user tries to send the message"), [](World& world, const Captures&, const Table&) {
    QMetaObject::invokeMethod(composerItem(world), "focusInput");
    typeInComposer(world, QStringLiteral("Review this"));
    pressInComposer(world, QStringLiteral("Enter"));
  });
  step(QStringLiteral("the user is asked to retry or remove failed uploads before sending"), [](World& world, const Captures&, const Table&) {
    expect(told(world, QStringLiteral("Retry or remove failed uploads before sending.")), QStringLiteral("the toasts are %1").arg(show(toasts(world))));
    expect(commandsOf(world, QStringLiteral("message.dispatch")).isEmpty() && composerEditor(world)->property("text") == QLatin1String("Review this"),
           QStringLiteral("the message went, or the draft was lost"));
  });
  step(QStringLiteral("the user retries the upload and it succeeds"), [](World& world, const Captures&, const Table&) {
    const QString name = world.mc.part<Typed>().text;
    world.mc.part<FakeFileUploads>().refuse.clear();
    Brick& brick = composerBrick(world);
    QQuickItem* retry = composerPart(world, QStringLiteral("attachmentRetry:") + name);
    expect(retry && retry->isVisible(), QStringLiteral("%1 offers no retry").arg(name));
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(retry));
    waitForUpload(world, name, QString());
  });
  step(QStringLiteral("the message can be sent"), [](World& world, const Captures&, const Table&) {
    const QString name = world.mc.part<Typed>().text;
    QMetaObject::invokeMethod(composerItem(world), "focusInput");
    pressInComposer(world, QStringLiteral("Enter"));
    world.waitFor([&] { return !commandsOf(world, QStringLiteral("message.dispatch")).isEmpty(); }, [&] { return QStringLiteral("the message; the toasts are %1").arg(show(toasts(world))); });
    const QJsonArray sent = commandsOf(world, QStringLiteral("message.dispatch")).last().value(QLatin1String("attachments")).toArray();
    const QJsonObject file = sent.first().toObject();
    expect(sent.size() == 1 && file.value(QLatin1String("type")) == QLatin1String("file") && file.value(QLatin1String("name")) == name &&
               world.mc.part<FakeFileUploads>().stored.contains(file.value(QLatin1String("id")).toString()),
           QStringLiteral("the message carries %1; the MC stored %2").arg(show(sent.toVariantList()), world.mc.part<FakeFileUploads>().stored.join(u", ")));
  });
  step(QStringLiteral("the draft carries a file that is still uploading"), [](World& world, const Captures&, const Table&) {
    world.mc.hold(QStringLiteral("uploads"));
    const QString text = QStringLiteral("Read the schema");
    world.bridge().dispatch(QStringLiteral("composer.text.set"),
                            QVariantMap{{QStringLiteral("target"), world.native().controller<NavigationController>()->threadKey()}, {QStringLiteral("text"), text}, {QStringLiteral("cursor"), text.size()}});
    composerBrick(world);
    QMimeData data;
    data.setUrls({plainFile(world, QStringLiteral("schema.sql"))});
    drop(world, data);
    waitForUpload(world, QStringLiteral("schema.sql"), QStringLiteral("uploading"));
  });
  step(QStringLiteral("the user is asked to wait for file uploads before stashing"), [](World& world, const Captures&, const Table&) {
    expect(told(world, QStringLiteral("Wait for file uploads before stashing this prompt")), QStringLiteral("the toasts are %1").arg(show(toasts(world))));
  });
  step(QStringLiteral("the draft is unchanged"), [](World& world, const Captures&, const Table&) {
    expect(draftText(world) == QLatin1String("Read the schema") && carried(world) == QStringList{QStringLiteral("schema.sql")} &&
               world.state(QStringLiteral("composerStash")).toMap().value(QStringLiteral("entries")).toList().isEmpty(),
           QStringLiteral("the draft reads \"%1\" with %2").arg(draftText(world), carried(world).join(u", ")));
  });

  step(QStringLiteral("the user pastes a copied picture into the prompt"), [](World& world, const Captures&, const Table&) {
    composerBrick(world);
    QImage picture(4, 4, QImage::Format_RGB32);
    picture.fill(Qt::red);
    QGuiApplication::clipboard()->setImage(picture);
    expect(pressInComposer(world, QStringLiteral("mod+v")), QStringLiteral("the composer did not take the paste"));
  });

  // Large pastes.
  step(QStringLiteral("the user pastes 40 KiB of log output"), [](World& world, const Captures&, const Table&) { paste(world, false); });
  step(QStringLiteral("the user pastes 40 KiB of log output with Paste as Text"), [](World& world, const Captures&, const Table&) { paste(world, true); });
  step(QStringLiteral("the paste is attached as a text file instead of being inserted"), [](World& world, const Captures&, const Table&) {
    waitForUpload(world, QStringLiteral("pasted-text.txt"), QString());
    const QVariantMap file = attachment(world, QStringLiteral("pasted-text.txt"));
    const QJsonObject asked = world.mc.part<FakeFileUploads>().asked.value(0);
    expect(file.value(QStringLiteral("kind")) == QLatin1String("file") && asked.value(QLatin1String("sizeBytes")).toInt() == 40 * 1024 &&
               asked.value(QLatin1String("mimeType")) == QLatin1String("text/plain") && composerEditor(world)->property("text").toString().isEmpty(),
           QStringLiteral("the draft carries %1, the MC was asked %2").arg(show(file), show(asked.toVariantMap())));
  });
  step(QStringLiteral("the user is told the paste was attached"), [](World& world, const Captures&, const Table&) {
    expect(told(world, QStringLiteral("Large paste attached as pasted-text.txt")), QStringLiteral("the toasts are %1").arg(show(toasts(world))));
  });
  step(QStringLiteral("the user removes the attachment and pastes the log as plain text instead"), [](World& world, const Captures&, const Table&) {
    Brick& brick = composerBrick(world);
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(chip(world, QStringLiteral("pasted-text.txt"))));
    world.sync();
    expect(carried(world).isEmpty() && world.mc.part<FakeFileUploads>().deleted == QStringList{QStringLiteral("pending-1")},
           QStringLiteral("the draft carries %1; the MC dropped %2").arg(carried(world).join(u", "), world.mc.part<FakeFileUploads>().deleted.join(u", ")));
    QMetaObject::invokeMethod(composerItem(world), "focusInput");
    paste(world, true);
  });
  step(QStringLiteral("the text is inserted into the draft where it can be edited"), [](World& world, const Captures&, const Table&) { expectInserted(world); });
  step(QStringLiteral("nothing is attached"), [](World& world, const Captures&, const Table&) {
    expect(carried(world).isEmpty() && world.mc.part<FakeFileUploads>().asked.isEmpty(), QStringLiteral("the draft carries %1").arg(carried(world).join(u", ")));
  });

  // Folders.
  step(QStringLiteral("the environment is (local|remote)"), [](World& world, const Captures& c, const Table&) {
    // Remote: the MC the shell is connected to runs on another machine.
    if (c[0] == QLatin1String("remote")) world.bridge().setMcOrigin(QUrl(QStringLiteral("https://mc.example.test")));
    expect(world.bridge().localFolders() == (c[0] == QLatin1String("local")), QStringLiteral("the shell's MC is not %1").arg(c[0]));
  });
  const auto dropFolder = [](World& world, const QString& relative) {
    const QDir dir(world.homeDir() + QStringLiteral("/checkout/") + relative);
    expect(dir.mkpath(QStringLiteral(".")), QStringLiteral("could not make %1").arg(dir.path()));
    composerBrick(world);
    QMimeData data;
    data.setUrls({QUrl::fromLocalFile(dir.path())});
    drop(world, data);
  };
  step(QStringLiteral("the user drops the folder %1 onto the composer").arg(q), [dropFolder](World& world, const Captures& c, const Table&) { dropFolder(world, c[0]); });
  step(QStringLiteral("the user drops a folder onto the composer"), [dropFolder](World& world, const Captures&, const Table&) { dropFolder(world, QStringLiteral("src/components")); });
  step(QStringLiteral("the draft references the folder %1").arg(q), [](World& world, const Captures& c, const Table&) {
    settleComposer(world);
    const QString path = QDir(world.homeDir() + QStringLiteral("/checkout/") + c[0]).absolutePath();
    const QString link = QStringLiteral("[%1](%2)").arg(c[0].section(u'/', -1), path);
    expect(draftText(world).contains(link) && carried(world).isEmpty() && composerEditor(world)->property("text") == draftText(world),
           QStringLiteral("the draft reads \"%1\"").arg(draftText(world)));
  });
  step(QStringLiteral("the user is told folders cannot be dropped into remote environments"), [](World& world, const Captures&, const Table&) {
    expect(told(world, QStringLiteral("Folders can't be dropped into remote environments")), QStringLiteral("the toasts are %1").arg(show(toasts(world))));
    expect(draftText(world).isEmpty(), QStringLiteral("the draft reads \"%1\"").arg(draftText(world)));
  });
  step(QStringLiteral("the user is told to type the folder path instead"), [](World& world, const Captures&, const Table&) {
    expect(told(world, QStringLiteral("Folders can't be dropped into remote environments"), QStringLiteral("Type the folder path with @ instead.")),
           QStringLiteral("the toasts are %1").arg(show(toasts(world))));
  });

  // Snap Shots on the draft.
  const auto snapShot = [](World& world, QJsonObject source) {
    source.insert(QStringLiteral("kind"), QStringLiteral("snap-shot"));
    source.insert(QStringLiteral("capturedAt"), QStringLiteral("2026-09-23T10:00:00Z"));
    if (!source.contains(QLatin1String("appName"))) source.insert(QStringLiteral("appName"), QStringLiteral("Terminal"));
    if (!source.contains(QLatin1String("windowTitle"))) source.insert(QStringLiteral("windowTitle"), QStringLiteral("npm test"));
    world.native().controller<ComposerController>()->attachImage(world.native().controller<NavigationController>()->threadKey(),
                                                                 QStringLiteral("window-terminal.png"), QStringLiteral("image/png"), QByteArray("png"), source);
    world.sync();
  };
  step(QStringLiteral("the draft carries a Snap Shot of the %1 window titled %1").arg(q), [snapShot](World& world, const Captures& c, const Table&) {
    snapShot(world, {{QStringLiteral("appName"), c[0]}, {QStringLiteral("windowTitle"), c[1]}});
  });
  step(QStringLiteral("the draft carries a Snap Shot (with the window's accessibility text|with accessibility elements that have no names|without accessibility data)"),
       [snapShot](World& world, const Captures& c, const Table&) {
         if (c[0].startsWith(QLatin1String("with the"))) {
           snapShot(world, {{QStringLiteral("accessibleText"), QStringLiteral("Tests: 12 passed, 0 failed")}});
         } else if (c[0].startsWith(QLatin1String("with accessibility"))) {
           const QJsonObject group{{QStringLiteral("role"), QStringLiteral("group")}, {QStringLiteral("bounds"), QJsonValue::Null}, {QStringLiteral("children"), QJsonArray()}};
           snapShot(world, {{QStringLiteral("accessibility"),
                             QJsonObject{{QStringLiteral("format"), QStringLiteral("element-tree")},
                                         {QStringLiteral("coordinateSpace"), QStringLiteral("captured-image")},
                                         {QStringLiteral("imageSize"), QJsonObject{{QStringLiteral("width"), 800}, {QStringLiteral("height"), 600}}},
                                         {QStringLiteral("truncated"), false},
                                         {QStringLiteral("root"), QJsonObject{{QStringLiteral("role"), QStringLiteral("window")}, {QStringLiteral("bounds"), QJsonValue::Null},
                                                                              {QStringLiteral("children"), QJsonArray{group, group}}}}}}});
         } else {
           snapShot(world, {});
         }
       });
  step(QStringLiteral("the user looks at the attachment"), [](World& world, const Captures&, const Table&) { composerBrick(world); });
  step(QStringLiteral("it names the app %1 and the window %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString label = chip(world, QStringLiteral("window-terminal.png"))->property("text").toString();
    expect(chip(world, QStringLiteral("window-terminal.png"))->isVisible() && label == QStringLiteral("%1 · %2").arg(c[0], c[1]), QStringLiteral("the attachment reads \"%1\"").arg(label));
  });
  step(QStringLiteral("the user opens the Snap Shot's accessibility data"), [](World& world, const Captures&, const Table&) {
    Brick& brick = composerBrick(world);
    QQuickItem* button = composerPart(world, QStringLiteral("attachmentAccessibility:window-terminal.png"));
    expect(button && button->isVisible(), QStringLiteral("the attachment offers no accessibility data"));
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(button));
    world.waitFor([&] { return composerPart(world, QStringLiteral("attachmentAccessibilityText")) != nullptr && composerPart(world, QStringLiteral("attachmentAccessibilityText"))->isVisible(); },
                  QStringLiteral("the accessibility data to open"));
  });
  const QHash<QString, QString> seen{
      {QStringLiteral("the captured text"), QStringLiteral("Tests: 12 passed, 0 failed")},
      {QStringLiteral("that the elements have no readable names or values"), QStringLiteral("Structured accessibility elements were included, but they have no readable names or values.")},
      {QStringLiteral("that the app did not provide accessibility data"), QStringLiteral("The app or capture backend did not provide verified accessibility data.")}};
  step(QStringLiteral("the user sees (the captured text|that the elements have no readable names or values|that the app did not provide accessibility data)"),
       [seen](World& world, const Captures& c, const Table&) {
         const QString text = composerPart(world, QStringLiteral("attachmentAccessibilityText"))->property("text").toString();
         expect(text == seen.value(c[0]), QStringLiteral("the accessibility data reads \"%1\"").arg(text));
       });

  // Answering the agent's question (question-answers.feature).
  const auto answerField = [](World& world) {
    QQuickItem* field = composerPart(world, QStringLiteral("questionAnswer-database"));
    expect(field && field->isVisible(), QStringLiteral("the question takes no typed answer"));
    return field;
  };
  const auto typeAnswer = [answerField](World& world, const QString& text) {
    Brick& brick = composerBrick(world);
    QQuickItem* field = answerField(world);
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(field));
    expect(field->hasActiveFocus(), QStringLiteral("the answer field did not take the keyboard"));
    typeInComposer(world, text);
    expect(field->property("text") == text, QStringLiteral("the answer reads \"%1\"").arg(field->property("text").toString()));
  };
  const auto answerFiles = [](World& world) {
    const QVariantMap request = world.state(QStringLiteral("turn")).toMap().value(QStringLiteral("questions")).toList().value(0).toMap();
    return request.value(QStringLiteral("questions")).toList().value(0).toMap().value(QStringLiteral("attachments")).toList();
  };
  const auto submit = [](World& world) {
    Brick& brick = composerBrick(world);
    QQuickItem* button = composerPart(world, QStringLiteral("questionSubmit"));
    expect(button && button->isVisible() && button->isEnabled(), QStringLiteral("the answer cannot be submitted"));
    QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(button));
    world.sync();
  };
  step(QStringLiteral("the user has a separate draft %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("composer.text.set"),
                            QVariantMap{{QStringLiteral("target"), world.native().controller<NavigationController>()->threadKey()}, {QStringLiteral("text"), c[0]}, {QStringLiteral("cursor"), c[0].size()}});
  });
  step(QStringLiteral("the user types %1 and attaches %1").arg(q), [typeAnswer, answerFiles](World& world, const Captures& c, const Table&) {
    typeAnswer(world, c[0]);
    // What the answer's file picker hands the question.
    QQuickItem* requests = composerPart(world, QStringLiteral("turnRequests"));
    QMetaObject::invokeMethod(requests, "attachTo", Q_ARG(QVariant, QStringLiteral("database")), Q_ARG(QVariant, QVariant(QVariantList{plainFile(world, c[1])})));
    world.waitFor([&] { return answerFiles(world).size() == 1 && answerFiles(world).first().toMap().value(QStringLiteral("status")).toString().isEmpty(); },
                  [&] { return QStringLiteral("%1 to upload; the answer carries %2").arg(c[1], show(answerFiles(world))); });
    QQuickItem* shown = composerPart(world, QStringLiteral("attachment:") + c[1]);
    expect(shown && shown->isVisible(), QStringLiteral("the answer does not show %1").arg(c[1]));
  });
  step(QStringLiteral("submits the answer"), [submit](World& world, const Captures&, const Table&) { submit(world); });
  step(QStringLiteral("the agent receives %1 with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QList<QJsonObject> answers = commandsOf(world, QStringLiteral("runtime-request.respond"));
    expect(answers.size() == 1, QStringLiteral("the MC has %1").arg(world.describeCommands()));
    const QJsonArray files = answers.first().value(QLatin1String("attachmentsByQuestionId")).toObject().value(QLatin1String("database")).toArray();
    const QJsonObject file = files.first().toObject();
    expect(answers.first().value(QLatin1String("answers")).toObject().value(QLatin1String("database")) == c[0] && files.size() == 1 &&
               file.value(QLatin1String("name")) == c[1] && file.value(QLatin1String("type")) == QLatin1String("file") &&
               world.mc.part<FakeFileUploads>().stored.contains(file.value(QLatin1String("id")).toString()),
           QStringLiteral("the agent received %1").arg(show(answers.first().toVariantMap())));
  });
  step(QStringLiteral("the normal draft still reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(draftText(world) == c[0] && carried(world).isEmpty() && commandsOf(world, QStringLiteral("message.dispatch")).isEmpty(),
           QStringLiteral("the draft reads \"%1\" with %2").arg(draftText(world), carried(world).join(u", ")));
  });
  step(QStringLiteral("the question only allows its listed options"), [](World& world, const Captures&, const Table&) {
    // The question as the agent asked it, again without a typed answer.
    const QVariantMap request = world.state(QStringLiteral("turn")).toMap().value(QStringLiteral("questions")).toList().value(0).toMap();
    QJsonObject asked = QJsonObject::fromVariantMap(request.value(QStringLiteral("questions")).toList().value(0).toMap());
    asked.insert(QStringLiteral("allowCustomAnswer"), false);
    asked.remove(QStringLiteral("attachments"));
    stream::set(world, QStringLiteral("runtime-request"), request.value(QStringLiteral("requestId")).toString(), {{QStringLiteral("status"), QStringLiteral("resolved")}});
    const QString id = QStringLiteral("request-fixed");
    stream::set(world, QStringLiteral("runtime-request"), id,
                {{QStringLiteral("id"), id}, {QStringLiteral("status"), QStringLiteral("pending")}, {QStringLiteral("responseCapability"), QJsonObject{{QStringLiteral("type"), QStringLiteral("live")}}}});
    stream::addItem(world, QStringLiteral("user_input_request"), {{QStringLiteral("requestId"), id}, {QStringLiteral("status"), QStringLiteral("waiting")}, {QStringLiteral("questions"), QJsonArray{asked}}});
    world.waitFor([&] { return composer(world).value(QStringLiteral("editorDisabled")).toBool(); }, QStringLiteral("the composer to see the question"));
  });
  step(QStringLiteral("the user tries to attach a file"), [](World& world, const Captures&, const Table&) {
    composerBrick(world);
    QMimeData data;
    data.setUrls({plainFile(world, QStringLiteral("schema.sql"))});
    drop(world, data);
  });
  step(QStringLiteral("the user is told this question cannot accept attachments"), [](World& world, const Captures&, const Table&) {
    expect(told(world, QStringLiteral("This question cannot accept attachments.")), QStringLiteral("the toasts are %1").arg(show(toasts(world))));
    expect(carried(world).isEmpty() && world.mc.part<FakeFileUploads>().asked.isEmpty(), QStringLiteral("the file was taken"));
  });
  step(QStringLiteral("the user typed %1").arg(q), [typeAnswer](World& world, const Captures& c, const Table&) { typeAnswer(world, c[0]); });
  step(QStringLiteral("submitting the answer fails"), [submit](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(QStringLiteral("runtime-request.respond"), QStringLiteral("connection closed"));
    submit(world);
  });
  step(QStringLiteral("the answer still reads %1").arg(q), [answerField](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return told(world, QStringLiteral("Failed to submit answers.")); }, [&] { return QStringLiteral("the failure; the toasts are %1").arg(show(toasts(world))); });
    expect(answerField(world)->property("text") == c[0], QStringLiteral("the answer reads \"%1\"").arg(answerField(world)->property("text").toString()));
    // And can be sent again.
    QQuickItem* button = composerPart(world, QStringLiteral("questionSubmit"));
    world.waitFor([&] { return button->isEnabled(); }, QStringLiteral("the answer to be offered again"));
  });

  step(QStringLiteral("the draft carries no attachments"), [](World& world, const Captures&, const Table&) {
    expect(carried(world).isEmpty(), QStringLiteral("the draft carries %1").arg(carried(world).join(u", ")));
  });
  step(QStringLiteral("the typed text is unchanged"), [](World& world, const Captures&, const Table&) {
    settleComposer(world);
    const QString text = world.native().controller<ComposerController>()->draft(world.native().controller<NavigationController>()->threadKey());
    expect(!text.isEmpty() && text == world.mc.part<Typed>().text && composerEditor(world)->property("text") == text,
           QStringLiteral("the draft reads \"%1\"").arg(text));
  });
});

}  // namespace

bool removeComposerAttachment(World& world, const QString& name) {
  if (!composerBrickShown(world) || !carried(world).contains(name)) return false;
  settleComposer(world);
  world.mc.part<Typed>().text = world.native().controller<ComposerController>()->draft(world.native().controller<NavigationController>()->threadKey());
  Brick& brick = composerBrick(world);
  QTest::mouseClick(&brick.window(), Qt::LeftButton, Qt::NoModifier, brick.at(chip(world, name)));
  world.sync();
  return true;
}
