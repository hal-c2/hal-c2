// What a draft carries besides its text, as the composer brick on screen
// takes it (ComposerBrick.h): images and files chosen, dropped and pasted,
// their uploads, and removing them (features/composer/attachments.feature).

#include <QDir>
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
#include "World.h"

namespace {

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
