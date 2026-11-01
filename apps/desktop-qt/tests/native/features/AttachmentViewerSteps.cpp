// Steps for "Viewing attachments" of features/files/file-viewer-and-editing.feature:
// a message's images large over the ThreadView brick, a sent file fetched into
// the AttachmentViewer brick, and a draft's attachment opened from its chip.

#include <QBuffer>
#include <QClipboard>
#include <QDir>
#include <QGuiApplication>
#include <QImage>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQuickItem>
#include <QTcpSocket>
#include <QTemporaryDir>
#include <QTest>
#include <QWheelEvent>

#include "AttachmentViewerController.h"
#include "Brick.h"
#include "ComposerBrick.h"
#include "Harness.h"
#include "MediaFixtures.h"
#include "NativeShell.h"
#include "Stream.h"

using namespace stream;

namespace {

// What the MC serves as attachments: bytes by id, the ids it no longer has,
// the signatures it made, and whether it is cut off.
struct FakeAttachments {
  QHash<QString, QByteArray> bytes;
  QSet<QString> gone;
  QSet<QString> unsigned_;
  QSet<QString> broken;
  bool unreachable = false;
  int signatures = 0;
  std::shared_ptr<QTemporaryDir> saves;
};

// The sent attachment a scenario talks about before it is opened.
struct FakeSent {
  QString name;
};

QByteArray picture() {
  QImage image(200, 100, QImage::Format_RGB32);
  image.fill(Qt::darkCyan);
  QByteArray bytes;
  QBuffer buffer(&bytes);
  buffer.open(QIODevice::WriteOnly);
  image.save(&buffer, "PNG");
  return bytes;
}

void serve(World& world) {
  world.mc.onRpc(QStringLiteral("assets.createUrl"), [&mc = world.mc](const FakeMc::Rpc& rpc) {
    FakeAttachments& fake = mc.part<FakeAttachments>();
    const QString id = rpc.payload.value(QLatin1String("resource")).toObject().value(QLatin1String("attachmentId")).toString();
    // McClient's own word for a call with no connection to carry it.
    if (fake.unreachable) return mc.refuse(rpc, QStringLiteral("not connected"));
    if (fake.unsigned_.contains(id)) return mc.refuse(rpc, QStringLiteral("No such attachment."));
    ++fake.signatures;
    mc.reply(rpc, QJsonObject{{QStringLiteral("relativeUrl"), QStringLiteral("/api/assets/attachment/%1/%2").arg(id).arg(fake.signatures)},
                              {QStringLiteral("expiresAt"), double(now().addSecs(3600).toMSecsSinceEpoch())}});
  });
  world.mc.onRaw(QStringLiteral("/api/assets/attachment/"), [&mc = world.mc](QTcpSocket* socket, const QByteArray& head) {
    socket->read(head.size());
    FakeAttachments& fake = mc.part<FakeAttachments>();
    const QString id = QString::fromUtf8(head.left(head.indexOf('\r')).split(' ').value(1)).section(QLatin1Char('/'), 4, 4);
    if (fake.gone.contains(id) || fake.broken.contains(id) || !fake.bytes.contains(id)) {
      socket->write("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
    } else {
      const QByteArray body = fake.bytes.value(id);
      socket->write("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\n\r\n" + body);
    }
    socket->disconnectFromHost();
  });
}

// An item in the window, if any; a list's delegates are only reachable by
// walking the visual tree.
QQuickItem* onShow(QQuickItem* item, const QString& name) {
  if (item->objectName() == name) return item;
  for (QQuickItem* child : item->childItems()) {
    if (QQuickItem* found = onShow(child, name)) return found;
  }
  return nullptr;
}

Brick& conversation(World& world) {
  if (!world.brick) {
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nItem { ThreadView { anchors.fill: parent }\n AttachmentViewer {} }\n", QSize(1000, 800));
    world.brick->takesKeys = true;
  }
  return *world.brick;
}

// A message carrying `count` images (and what `fields` adds to the first),
// on show in the conversation.
void messageWithImages(World& world, int count, const QJsonObject& first = {}) {
  serve(world);
  lookAtThread(world, kProject);
  const QString run = startRun(world);
  QJsonArray images;
  for (int n = 1; n <= count; ++n) {
    world.mc.part<FakeAttachments>().bytes.insert(QStringLiteral("image-%1").arg(n), picture());
    QJsonObject image{{QStringLiteral("type"), QStringLiteral("image")}, {QStringLiteral("id"), QStringLiteral("image-%1").arg(n)},
                      {QStringLiteral("name"), QStringLiteral("shot-%1.png").arg(n)}, {QStringLiteral("mimeType"), QStringLiteral("image/png")},
                      {QStringLiteral("sizeBytes"), 2048}};
    if (n == 1) {
      for (auto it = first.begin(); it != first.end(); ++it) image.insert(it.key(), it.value());
    }
    images.append(image);
  }
  set(world, QStringLiteral("turn-item"), QStringLiteral("message:") + run, {{QStringLiteral("attachments"), images}});
  conversation(world);
  world.sync();
}

QObject* viewer(World& world) {
  return world.brick->root()->findChild<QObject*>(QStringLiteral("imageViewer"));
}

QVariant of(World& world, const char* property) {
  return viewer(world)->property(property);
}

QQuickItem* pictureItem(World& world) {
  return world.brick->item(QStringLiteral("imageViewerPicture"));
}

// Opens image `n`, and waits for its picture (unless it is not to load).
void openImage(World& world, int n, bool loads = true) {
  const QString name = QStringLiteral("attachmentOpenLarge-image-%1").arg(n);
  world.waitFor([&] { return onShow(world.brick->root(), name); }, QStringLiteral("the image in the conversation"));
  // A picture widens its square as it loads, moving its neighbours.
  if (loads) {
    world.waitFor([&] {
      for (int other = 1; QQuickItem* square = onShow(world.brick->root(), QStringLiteral("attachment-image-%1").arg(other)); ++other) {
        if (!square->property("pictured").toBool()) return false;
      }
      return true;
    }, QStringLiteral("the pictures in the conversation"));
  }
  // Their row settles over one frame more than the click itself draws.
  world.brick->at(world.brick->root());
  world.brick->click(name);
  world.waitFor([&] { return of(world, "visible").toBool(); }, QStringLiteral("the image viewer to open"));
  if (loads) {
    world.waitFor([&] { return pictureItem(world)->property("status").toInt() == 1 && pictureItem(world)->width() > 0; },
                  [&] { return QStringLiteral("the picture to load; its status is %1").arg(pictureItem(world)->property("status").toInt()); });
  }
}

void expectZoom(World& world, double wanted) {
  const double zoom = of(world, "zoom").toDouble();
  expect(qAbs(zoom - wanted) < 0.001, QStringLiteral("the image is at %1 times its fitted size, not %2").arg(zoom).arg(wanted));
  const double drawn = pictureItem(world)->width() / 200.0;
  expect(qAbs(drawn - wanted) < 0.001, QStringLiteral("the picture is drawn at %1 times, not %2").arg(drawn).arg(wanted));
}

void expectShowing(World& world, int n) {
  world.waitFor([&] { return of(world, "index").toInt() == n - 1; }, [&] { return QStringLiteral("image %1; the viewer shows image %2").arg(n).arg(of(world, "index").toInt() + 1); });
  const QString name = world.brick->item(QStringLiteral("imageViewerName"))->property("text").toString();
  expect(name.startsWith(QStringLiteral("shot-%1.png").arg(n)), QStringLiteral("the viewer is named %1").arg(name));
}

QPoint pictureAt(World& world, double fx = 0.5, double fy = 0.5) {
  return world.brick->at(pictureItem(world), fx, fy);
}

void clickPicture(World& world) {
  QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, pictureAt(world));
  world.sync();
}

void wheel(World& world, const QPoint& at, int delta, Qt::KeyboardModifiers modifiers = Qt::NoModifier) {
  QWheelEvent event(at, world.brick->window().mapToGlobal(at), QPoint(), QPoint(0, delta), Qt::NoButton, modifiers, Qt::NoScrollPhase, false);
  QCoreApplication::sendEvent(&world.brick->window(), &event);
  world.sync();
}

void key(World& world, Qt::Key which) {
  QTest::keyClick(&world.brick->window(), which);
  world.sync();
}

Qt::Key keyNamed(const QString& name) {
  if (name == QLatin1String("Enter")) return Qt::Key_Return;
  if (name == QLatin1String("Space")) return Qt::Key_Space;
  if (name == QLatin1String("plus")) return Qt::Key_Plus;
  if (name == QLatin1String("minus")) return Qt::Key_Minus;
  if (name == QLatin1String("0")) return Qt::Key_0;
  fail(QStringLiteral("no key %1").arg(name));
}

QVariantMap viewed(World& world) {
  return world.state(QStringLiteral("attachmentViewer")).toMap();
}

// A draft's attachment opened from its chip in the composer.
void openDraft(World& world, QVariantMap file) {
  // A file comes from where it was picked; only an image is taken as bytes.
  if (!file.value(QStringLiteral("mimeType")).toString().startsWith(QLatin1String("image/"))) {
    FakeAttachments& fake = world.mc.part<FakeAttachments>();
    if (!fake.saves) fake.saves = std::make_shared<QTemporaryDir>();
    const QString path = fake.saves->filePath(file.value(QStringLiteral("name")).toString());
    QFile picked(path);
    if (!picked.open(QIODevice::WriteOnly)) fail(picked.errorString());
    picked.write(QByteArray::fromBase64(file.take(QStringLiteral("base64")).toString().toLatin1()));
    picked.close();
    file.insert(QStringLiteral("path"), path);
    serve(world);
    world.mc.onRpc(QStringLiteral("attachments.createUploadUrl"), [&mc = world.mc](const FakeMc::Rpc& rpc) {
      mc.reply(rpc, QJsonObject{{QStringLiteral("attachmentId"), QStringLiteral("up-1")}, {QStringLiteral("relativeUrl"), QStringLiteral("/api/assets/attachment/up-1/0")}});
    });
  }
  world.bridge().dispatch(QStringLiteral("composer.attach"), QVariantMap{{QStringLiteral("files"), QVariantList{file}}});
  world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nItem {\n  Composer { width: parent.width; anchors.bottom: parent.bottom }\n  AttachmentViewer {}\n}\n", QSize(900, 700));
  world.sync();
  const QString name = file.value(QStringLiteral("name")).toString();
  world.brick->click(QStringLiteral("attachmentOpen:") + name);
  world.waitFor([&] { return viewed(world).value(QStringLiteral("name")) == name; }, QStringLiteral("the attachment to open"));
}

// A sent message's file, opened from the conversation.
void openSent(World& world, const QString& name, const QString& mimeType, const QByteArray& bytes, bool wait = true) {
  serve(world);
  FakeAttachments& fake = world.mc.part<FakeAttachments>();
  if (!fake.saves) {
    fake.saves = std::make_shared<QTemporaryDir>();
    world.native().controller<AttachmentViewerController>()->setSaveFolder(fake.saves->path());
  }
  fake.bytes.insert(QStringLiteral("file-1"), bytes);
  lookAtThread(world, kProject);
  const QString run = startRun(world);
  const QJsonObject file{{QStringLiteral("type"), QStringLiteral("file")}, {QStringLiteral("id"), QStringLiteral("file-1")},
                         {QStringLiteral("name"), name}, {QStringLiteral("mimeType"), mimeType}, {QStringLiteral("sizeBytes"), qint64(bytes.size())}};
  set(world, QStringLiteral("turn-item"), QStringLiteral("message:") + run, {{QStringLiteral("attachments"), QJsonArray{file}}});
  conversation(world);
  world.waitFor([&] { return onShow(world.brick->root(), QStringLiteral("sentFileOpen-file-1")); }, QStringLiteral("the file in the conversation"));
  world.brick->click(QStringLiteral("sentFileOpen-file-1"));
  if (wait) {
    world.waitFor([&] { const QString kind = viewed(world).value(QStringLiteral("kind")).toString(); return !kind.isEmpty() && kind != QLatin1String("loading"); }, QStringLiteral("the attachment to load"));
  }
}

void expectToast(World& world, const QString& type, const QString& title) {
  world.waitFor([&] {
    for (const QVariant& toast : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
      if (toast.toMap().value(QStringLiteral("type")) == type && toast.toMap().value(QStringLiteral("title")).toString().startsWith(title)) return true;
    }
    return false;
  }, [&] { return QStringLiteral("a %1 toast \"%2\"; toasts are %3").arg(type, title, show(world.state(QStringLiteral("toasts")))); });
}

const QByteArray kPage = "<html><body><h1>Report</h1></body></html>";

// The viewer's video, once it plays.
QQuickItem* playingVideo(World& world) {
  QQuickItem* player = nullptr;
  world.waitFor(
      [&] {
        player = world.brick->root()->findChild<QQuickItem*>(QStringLiteral("mediaPlayerView"));
        return player && player->property("playing").toBool();
      },
      [&] { return QStringLiteral("the video to play; %1").arg(show(viewed(world))); });
  return player;
}

const Steps steps([] {
  const QString q = QStringLiteral("\"([^\"]*)\"");

  // --- Stepping through a message's images.
  step(QStringLiteral("a message carries (one image|three images)(?: and the user opened the (second|third))?"), [](World& world, const Captures& c, const Table&) {
    messageWithImages(world, c[0] == QLatin1String("one image") ? 1 : 3);
    if (c.size() > 1) openImage(world, c[1] == QLatin1String("second") ? 2 : 3);
  });
  step(QStringLiteral("a message carries three images and the user zoomed the second"), [](World& world, const Captures&, const Table&) {
    messageWithImages(world, 3);
    openImage(world, 2);
    clickPicture(world);
    expectZoom(world, 2);
  });
  step(QStringLiteral("the user opens the second image"), [](World& world, const Captures&, const Table&) { openImage(world, 2); });
  step(QStringLiteral("the user opens it"), [](World& world, const Captures&, const Table&) { openImage(world, 1); });
  step(QStringLiteral("it is shown large"), [](World& world, const Captures&, const Table&) {
    expect(pictureItem(world)->isVisible() && world.brick->item(QStringLiteral("imageViewerStage"))->width() > 800, QStringLiteral("the picture is not on a window-sized stage"));
    expectShowing(world, 2);
  });
  step(QStringLiteral("the user can step to the previous and next image"), [](World& world, const Captures&, const Table&) {
    world.brick->click(QStringLiteral("imageViewerPrevious"));
    expectShowing(world, 1);
    world.brick->click(QStringLiteral("imageViewerNext"));
    expectShowing(world, 2);
  });
  step(QStringLiteral("its name is shown with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString name = world.brick->item(QStringLiteral("imageViewerName"))->property("text").toString();
    expect(name.endsWith(c[0]), QStringLiteral("the viewer is named %1").arg(name));
  });
  step(QStringLiteral("the user steps to the (next|previous) image"), [](World& world, const Captures& c, const Table&) {
    world.brick->click(c[0] == QLatin1String("next") ? QStringLiteral("imageViewerNext") : QStringLiteral("imageViewerPrevious"));
  });
  step(QStringLiteral("the (first|third) image is shown"), [](World& world, const Captures& c, const Table&) { expectShowing(world, c[0] == QLatin1String("first") ? 1 : 3); });
  step(QStringLiteral("no previous or next image is offered"), [](World& world, const Captures&, const Table&) {
    expect(!world.brick->root()->findChild<QQuickItem*>(QStringLiteral("imageViewerNext")) ||
               !world.brick->item(QStringLiteral("imageViewerNext"))->isVisible(), QStringLiteral("a next button is offered"));
  });
  step(QStringLiteral("the arrow keys do nothing"), [](World& world, const Captures&, const Table&) {
    key(world, Qt::Key_Right);
    key(world, Qt::Key_Left);
    expectShowing(world, 1);
    expect(of(world, "visible").toBool(), QStringLiteral("the viewer closed"));
  });
  step(QStringLiteral("the user presses the (right|left) arrow key( twice)?"), [](World& world, const Captures& c, const Table&) {
    const Qt::Key which = c[0] == QLatin1String("right") ? Qt::Key_Right : Qt::Key_Left;
    key(world, which);
    if (c.size() > 1) key(world, which);
  });

  // --- Zooming.
  step(QStringLiteral("the user opened an image(?: that fits the window| with focus on it)?"), [](World& world, const Captures&, const Table&) {
    messageWithImages(world, 1);
    openImage(world, 1);
  });
  step(QStringLiteral("the user clicks the image"), [](World& world, const Captures&, const Table&) { clickPicture(world); });
  step(QStringLiteral("the image is zoomed to twice its fitted size"), [](World& world, const Captures&, const Table&) { expectZoom(world, 2); });
  step(QStringLiteral("the user clicks the image again"), [](World& world, const Captures&, const Table&) { clickPicture(world); clickPicture(world); });
  step(QStringLiteral("the image is back to its fitted size"), [](World& world, const Captures&, const Table&) { expectZoom(world, 1); });
  step(QStringLiteral("the user turns the wheel up over a point"), [](World& world, const Captures&, const Table&) {
    // A picture within the window stays centred, so first make it wider.
    for (int n = 0; n < 8; ++n) wheel(world, QPoint(500, 400), 120);
    const QPoint at = pictureAt(world) + QPoint(100, 0);
    const double was = of(world, "zoom").toDouble();
    const double before = pictureItem(world)->mapFromScene(QPointF(at)).x() / was;
    wheel(world, at, 120);
    const double zoom = of(world, "zoom").toDouble();
    const double after = pictureItem(world)->mapFromScene(QPointF(at)).x() / zoom;
    // The picture grew about the point, which is still over the same spot of it.
    expect(zoom > was && qAbs(after - before) < 1, QStringLiteral("the point moved from %1 to %2 going from zoom %3 to %4").arg(before).arg(after).arg(was).arg(zoom));
  });
  step(QStringLiteral("the image is zoomed in around that point"), [](World& world, const Captures&, const Table&) { expect(of(world, "zoom").toDouble() > 1, QStringLiteral("the image did not zoom")); });
  step(QStringLiteral("the user turns the wheel down at its fitted size"), [](World& world, const Captures&, const Table&) { wheel(world, pictureAt(world), -120); });
  step(QStringLiteral("the image is left at its fitted size"), [](World& world, const Captures&, const Table&) { expectZoom(world, 1); });
  step(QStringLiteral("the user pinches or holds Control and turns the wheel"), [](World& world, const Captures&, const Table&) { wheel(world, pictureAt(world), 120, Qt::ControlModifier); });
  step(QStringLiteral("the image is zoomed faster than the wheel alone"), [](World& world, const Captures&, const Table&) { expectZoom(world, 1.5); });
  step(QStringLiteral("the user zooms in as far as it will go"), [](World& world, const Captures&, const Table&) {
    for (int n = 0; n < 40; ++n) wheel(world, pictureAt(world), 120);
  });
  step(QStringLiteral("the image is eight times its fitted size"), [](World& world, const Captures&, const Table&) { expectZoom(world, 8); });
  step(QStringLiteral("zooming further changes nothing"), [](World& world, const Captures&, const Table&) {
    wheel(world, QPoint(500, 400), 120);
    expectZoom(world, 8);
  });
  step(QStringLiteral("the user presses (Enter|Space|plus|minus|0) in the viewer"), [](World& world, const Captures& c, const Table&) {
    if (c[0] == QLatin1String("minus") || c[0] == QLatin1String("0")) {
      key(world, Qt::Key_Plus);
      key(world, Qt::Key_Plus);
    }
    key(world, keyNamed(c[0]));
  });
  step(QStringLiteral("the image zooms to twice its fitted size or returns"), [](World& world, const Captures&, const Table&) {
    expectZoom(world, 2);
    QTest::keyClick(&world.brick->window(), Qt::Key_Return);
    world.sync();
    expectZoom(world, 1);
  });
  step(QStringLiteral("the image zooms in one step"), [](World& world, const Captures&, const Table&) { expectZoom(world, 1.25); });
  step(QStringLiteral("the image zooms out one step"), [](World& world, const Captures&, const Table&) { expectZoom(world, 1.25); });
  step(QStringLiteral("the image returns to its fitted size"), [](World& world, const Captures&, const Table&) { expectZoom(world, 1); });

  // --- Looking around.
  step(QStringLiteral("the user zoomed an opened image"), [](World& world, const Captures&, const Table&) {
    messageWithImages(world, 1);
    openImage(world, 1);
    // Far enough that the picture overflows its stage.
    for (int n = 0; n < 40; ++n) wheel(world, pictureAt(world), 120);
    expectZoom(world, 8);
  });
  step(QStringLiteral("the user drags it with the mouse"), [](World& world, const Captures&, const Table&) {
    QQuickWindow& window = world.brick->window();
    const QPoint from(500, 400);
    const QPoint to(450, 380);
    QTest::mousePress(&window, Qt::LeftButton, Qt::NoModifier, from);
    QTest::mouseMove(&window, QPoint(480, 390));
    QTest::mouseMove(&window, to);
    QTest::mouseRelease(&window, Qt::LeftButton, Qt::NoModifier, to);
    world.sync();
  });
  step(QStringLiteral("the part of the image shown moves with the pointer"), [](World& world, const Captures&, const Table&) {
    expect(qAbs(of(world, "panX").toDouble() + 50) < 1, QStringLiteral("the image panned by %1").arg(of(world, "panX").toDouble()));
  });
  step(QStringLiteral("letting go does not zoom the image back out"), [](World& world, const Captures&, const Table&) { expectZoom(world, 8); });
  step(QStringLiteral("the user zooms in and presses the right arrow key"), [](World& world, const Captures&, const Table&) {
    for (int n = 0; n < 40; ++n) key(world, Qt::Key_Plus);
    key(world, Qt::Key_Right);
  });
  step(QStringLiteral("the zoomed image moves to show more to its right"), [](World& world, const Captures&, const Table&) {
    expect(of(world, "panX").toDouble() == -40, QStringLiteral("the image panned by %1").arg(of(world, "panX").toDouble()));
    expectShowing(world, 2);
  });
  step(QStringLiteral("the user returns the image to its fitted size and presses the right arrow key"), [](World& world, const Captures&, const Table&) {
    key(world, Qt::Key_0);
    key(world, Qt::Key_Right);
  });
  step(QStringLiteral("the third image is shown at its fitted size"), [](World& world, const Captures&, const Table&) {
    expectShowing(world, 3);
    world.waitFor([&] { return pictureItem(world)->property("status").toInt() == 1 && pictureItem(world)->width() > 0; }, QStringLiteral("the third picture to load"));
    expectZoom(world, 1);
  });
  step(QStringLiteral("the user zooms to twice its fitted size"), [](World& world, const Captures&, const Table&) { clickPicture(world); });
  step(QStringLiteral("%1 is announced to assistive technology").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(of(world, "announcement").toString() == c[0], QStringLiteral("announced %1").arg(of(world, "announcement").toString()));
  });

  // --- Closing.
  step(QStringLiteral("the user opened an image from the conversation"), [](World& world, const Captures&, const Table&) {
    messageWithImages(world, 1);
    openImage(world, 1);
  });
  step(QStringLiteral("the user presses Escape in the viewer"), [](World& world, const Captures&, const Table&) {
    if (!world.brick) fail(QStringLiteral("no brick takes the key"));
    key(world, Qt::Key_Escape);
  });
  step(QStringLiteral("the user clicks beside the image"), [](World& world, const Captures&, const Table&) {
    QTest::mouseClick(&world.brick->window(), Qt::LeftButton, Qt::NoModifier, QPoint(20, 700));
  });
  step(QStringLiteral("the user uses the close button"), [](World& world, const Captures&, const Table&) { world.brick->click(QStringLiteral("imageViewerClose")); });
  step(QStringLiteral("the viewer closes"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !of(world, "visible").toBool(); }, QStringLiteral("the image viewer to close"));
  });
  step(QStringLiteral("focus returns to what the user opened it from"), [](World& world, const Captures&, const Table&) {
    QQuickItem* focused = world.brick->window().activeFocusItem();
    expect(focused && focused->objectName() == QLatin1String("attachment-image-1"), QStringLiteral("focus is on %1").arg(focused ? focused->objectName() : QStringLiteral("nothing")));
  });
  step(QStringLiteral("the user opened an image and right-clicked it to open its menu"), [](World& world, const Captures&, const Table&) {
    messageWithImages(world, 1);
    openImage(world, 1);
    QTest::mouseClick(&world.brick->window(), Qt::RightButton, Qt::NoModifier, pictureAt(world));
    QObject* menu = world.brick->root()->findChild<QObject*>(QStringLiteral("imageViewerMenu"));
    world.waitFor([&] { return menu->property("opened").toBool(); }, QStringLiteral("the menu to open"));
  });
  step(QStringLiteral("the viewer's menu closes"), [](World& world, const Captures&, const Table&) {
    QObject* menu = world.brick->root()->findChild<QObject*>(QStringLiteral("imageViewerMenu"));
    world.waitFor([&] { return !menu->property("visible").toBool(); }, QStringLiteral("the menu to close"));
  });
  step(QStringLiteral("the image is still open"), [](World& world, const Captures&, const Table&) { expect(of(world, "visible").toBool(), QStringLiteral("the viewer closed")); });

  // --- Failures.
  step(QStringLiteral("the user opened an image whose picture cannot be loaded(?: and that has (an|no) address on the web)?"), [](World& world, const Captures& c, const Table&) {
    FakeAttachments& fake = world.mc.part<FakeAttachments>();
    if (c[0] == QLatin1String("no")) fake.unsigned_.insert(QStringLiteral("image-1"));
    else fake.broken.insert(QStringLiteral("image-1"));
    messageWithImages(world, 1);
    openImage(world, 1, false);
  });
  step(QStringLiteral("the image has an address on the web"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return of(world, "webAddress").toBool(); }, QStringLiteral("a signed address"));
  });
  step(QStringLiteral("the viewer says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return of(world, "failed").toBool() && world.brick->item(QStringLiteral("imageViewerProblem"))->property("text").toString() == c[0]; },
                  [&] { return QStringLiteral("the viewer says %1").arg(world.brick->item(QStringLiteral("imageViewerProblem"))->property("text").toString()); });
  });
  step(QStringLiteral("the viewer offers to open the original"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return of(world, "failed").toBool() && world.brick->item(QStringLiteral("imageViewerOriginal"))->isVisible(); }, QStringLiteral("the offer to open the original"));
  });

  // --- A Snap Shot's text.
  step(QStringLiteral("the user opened a Snap Shot (that has accessibility data|whose accessibility data is (text|JSON))"), [](World& world, const Captures& c, const Table&) {
    QJsonObject source{{QStringLiteral("kind"), QStringLiteral("snap-shot")}, {QStringLiteral("appName"), QStringLiteral("Files")}};
    if (c[1] == QLatin1String("JSON")) {
      source.insert(QStringLiteral("accessibility"), QJsonObject{{QStringLiteral("format"), QStringLiteral("tree")}, {QStringLiteral("root"), QJsonObject{{QStringLiteral("role"), QStringLiteral("window")}}}});
    } else {
      source.insert(QStringLiteral("accessibility"), QJsonObject{{QStringLiteral("format"), QStringLiteral("flat-text")}, {QStringLiteral("text"), QStringLiteral("Captured words")}, {QStringLiteral("truncated"), false}});
    }
    messageWithImages(world, 1, {{QStringLiteral("source"), source}});
    openImage(world, 1);
  });
  step(QStringLiteral("the user chooses to show its extracted text"), [](World& world, const Captures&, const Table&) { world.brick->click(QStringLiteral("imageViewerAccess")); });
  step(QStringLiteral("the text takes the picture's place"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.brick->item(QStringLiteral("imageViewerText"))->property("text") == QLatin1String("Captured words") && !pictureItem(world)->isVisible(), QStringLiteral("the picture is still shown"));
  });
  step(QStringLiteral("the user chooses to show the screenshot"), [](World& world, const Captures&, const Table&) { world.brick->click(QStringLiteral("imageViewerAccess")); });
  step(QStringLiteral("the picture is shown again"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(pictureItem(world)->isVisible(), QStringLiteral("the picture is not shown"));
  });
  step(QStringLiteral("the control to see it reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString label = world.brick->item(QStringLiteral("imageViewerAccess"))->property("text").toString();
    expect(label == c[0], QStringLiteral("the control reads %1").arg(label));
  });

  // --- A draft's attachment by kind.
  step(QStringLiteral("the user has attached %1 to a draft").arg(q), [](World& world, const Captures& c, const Table&) {
    const QHash<QString, std::pair<QString, QByteArray>> kinds{
        {QStringLiteral("receipt.png"), {QStringLiteral("image/png"), picture()}},
        {QStringLiteral("notes.md"), {QStringLiteral("text/markdown"), "# Notes\n"}},
        {QStringLiteral("build.log"), {QStringLiteral("text/plain"), "built\n"}},
        {QStringLiteral("invoice.pdf"), {QStringLiteral("application/pdf"), mediaFixture(QStringLiteral("invoice.pdf"))}},
    };
    const auto kind = kinds.value(c[0]);
    openDraft(world, {{QStringLiteral("name"), c[0]}, {QStringLiteral("mimeType"), kind.first}, {QStringLiteral("base64"), QString::fromLatin1(kind.second.toBase64())}});
  });
  step(QStringLiteral("the user opens the attachment from the draft"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(QStringLiteral("it is shown as an image"), [](World& world, const Captures&, const Table&) {
    expect(viewed(world).value(QStringLiteral("kind")) == QLatin1String("image") && world.brick->item(QStringLiteral("attachmentViewerImage"))->isVisible(), QStringLiteral("the viewer is %1").arg(show(viewed(world))));
  });
  step(QStringLiteral("it is shown as rendered Markdown that can switch to source"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.brick->root()->findChild<QQuickItem*>(QStringLiteral("attachmentViewerMarkdown")) != nullptr; }, QStringLiteral("rendered Markdown"));
    world.brick->click(QStringLiteral("attachmentViewerSource"));
    world.waitFor([&] { return world.brick->root()->findChild<QQuickItem*>(QStringLiteral("attachmentViewerText")) != nullptr; }, QStringLiteral("the source"));
  });
  step(QStringLiteral("it is shown as text"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { auto* text = world.brick->root()->findChild<QQuickItem*>(QStringLiteral("attachmentViewerText")); return text && text->property("text") == QLatin1String("built\n"); }, QStringLiteral("the text"));
  });

  step(QStringLiteral("it is shown as a document the user can page through"), [](World& world, const Captures&, const Table&) {
    QQuickItem* document = nullptr;
    world.waitFor([&] { document = world.brick->root()->findChild<QQuickItem*>(QStringLiteral("documentView")); return document && document->property("pageCount").toInt() == 2; }, QStringLiteral("the document"));
    QMetaObject::invokeMethod(document, "goTo", Q_ARG(QVariant, 1));
    world.waitFor([&] { return document->property("currentPage").toInt() == 1; }, QStringLiteral("the second page"));
  });
  step(QStringLiteral("a sent message carries the attachment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.part<FakeSent>().name = c[0];
  });
  step(QStringLiteral("the user opens the attachment from the conversation"), [](World& world, const Captures&, const Table&) {
    const QString name = world.mc.part<FakeSent>().name;
    openSent(world, name, QStringLiteral("application/pdf"), mediaFixture(name));
  });
  step(QStringLiteral("%1 is shown as a document from the environment").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { auto* document = world.brick->root()->findChild<QQuickItem*>(QStringLiteral("documentView")); return document && document->property("pageCount").toInt() == 2; }, QStringLiteral("the document"));
    expect(viewed(world).value(QStringLiteral("name")) == c[0] && world.mc.part<FakeAttachments>().signatures > 0, show(viewed(world)));
  });

  // --- A video in a message.
  step(QStringLiteral("a message carries a video"), [](World& world, const Captures&, const Table&) { world.mc.part<FakeSent>().name = QStringLiteral("clip.mp4"); });
  step(QStringLiteral("a message carries a video and an image and the user opened the video"), [](World& world, const Captures&, const Table&) {
    messageWithImages(world, 1);
    openSent(world, QStringLiteral("clip.mp4"), QStringLiteral("video/mp4"), mediaFixture(QStringLiteral("clip.mp4")));
    playingVideo(world);
  });
  step(QStringLiteral("the user opens the video"), [](World& world, const Captures&, const Table&) {
    openSent(world, QStringLiteral("clip.mp4"), QStringLiteral("video/mp4"), mediaFixture(QStringLiteral("clip.mp4")));
  });
  step(QStringLiteral("it starts playing in the viewer"), [](World& world, const Captures&, const Table&) { playingVideo(world); });
  step(QStringLiteral("the user presses the right arrow key with focus on the video"), [](World& world, const Captures&, const Table&) {
    QQuickItem* player = playingVideo(world);
    world.waitFor([&] { return player->hasActiveFocus(); }, QStringLiteral("the video to have focus"));
    QTest::keyClick(player->window(), Qt::Key_Right);
    world.sync();
  });
  step(QStringLiteral("the key is left to the video and the viewer stays on the video"), [](World& world, const Captures&, const Table&) {
    // The seek may have run the short clip to its end, so it need not still be playing.
    auto* player = world.brick->root()->findChild<QQuickItem*>(QStringLiteral("mediaPlayerView"));
    expect(player && player->hasActiveFocus() && player->property("position").toReal() > 0 && viewed(world).value(QStringLiteral("kind")) == QLatin1String("video"), show(viewed(world)));
  });

  // --- As captured.
  step(QStringLiteral("the user attached %1 and has since changed the project's %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString name = c[0].section(QLatin1Char('/'), -1);
    openDraft(world, {{QStringLiteral("name"), name}, {QStringLiteral("mimeType"), QStringLiteral("text/plain")}, {QStringLiteral("base64"), QString::fromLatin1(QByteArray("captured").toBase64())}});
    world.bridge().dispatch(QStringLiteral("attachment.viewer.close"), {});
    QFile file(world.mc.part<FakeAttachments>().saves->filePath(name));
    if (!file.open(QIODevice::WriteOnly)) fail(file.errorString());
    file.write("changed since");
  });
  step(QStringLiteral("the user opens the attachment"), [](World& world, const Captures&, const Table&) {
    if (!viewed(world).isEmpty()) return;  // A scenario's Given already opened it, failed or not.
    world.brick->click(QStringLiteral("attachmentOpen:app.ts"));
  });
  step(QStringLiteral("the captured contents are shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return viewed(world).value(QStringLiteral("text")) == QLatin1String("captured"); }, [&] { return QStringLiteral("the captured text; the viewer shows %1").arg(show(viewed(world))); });
  });

  // --- Whether a file is read as a table.
  step(QStringLiteral("the user opens %1 of type %1 rendered").arg(q), [](World& world, const Captures& c, const Table&) {
    openDraft(world, {{QStringLiteral("name"), c[0].section(QLatin1Char('/'), -1)}, {QStringLiteral("mimeType"), c[1]}, {QStringLiteral("base64"), QString::fromLatin1(QByteArray("a,b\tc\n1,2\t3\n").toBase64())}});
  });
  step(QStringLiteral("the file is shown as a (comma|tab) table"), [](World& world, const Captures& c, const Table&) {
    expect(viewed(world).value(QStringLiteral("kind")) == QLatin1String("table"), QStringLiteral("the viewer is %1").arg(show(viewed(world))));
    const QString header = c[0] == QLatin1String("comma") ? QStringLiteral("| a | b\tc |") : QStringLiteral("| a,b | c |");
    expect(viewed(world).value(QStringLiteral("rendered")).toString().startsWith(header), QStringLiteral("the table is %1").arg(viewed(world).value(QStringLiteral("rendered")).toString()));
  });
  step(QStringLiteral("the file is not shown as a table"), [](World& world, const Captures&, const Table&) {
    expect(viewed(world).value(QStringLiteral("kind")) != QLatin1String("table"), QStringLiteral("the viewer is %1").arg(show(viewed(world))));
  });

  // --- A sent attachment.
  step(QStringLiteral("the user is viewing an attachment of a sent message"), [](World& world, const Captures&, const Table&) {
    openSent(world, QStringLiteral("build.log"), QStringLiteral("text/plain"), "built\n");
    expect(viewed(world).value(QStringLiteral("kind")) == QLatin1String("text"), QStringLiteral("the viewer is %1").arg(show(viewed(world))));
  });
  step(QStringLiteral("the user saves it"), [](World& world, const Captures&, const Table&) { world.brick->click(QStringLiteral("attachmentViewerSave")); });
  step(QStringLiteral("the file is downloaded under its own name"), [](World& world, const Captures&, const Table&) {
    expectToast(world, QStringLiteral("success"), QStringLiteral("Saved build.log"));
    QFile file(world.mc.part<FakeAttachments>().saves->filePath(QStringLiteral("build.log")));
    expect(file.open(QIODevice::ReadOnly) && file.readAll() == "built\n", QStringLiteral("the saved file is missing or differs"));
  });
  step(QStringLiteral("the environment is unreachable"), [](World& world, const Captures&, const Table&) {
    serve(world);
    world.mc.part<FakeAttachments>().unreachable = true;
    openSent(world, QStringLiteral("build.log"), QStringLiteral("text/plain"), "built\n");
  });
  step(QStringLiteral("the environment cannot be reached"), [](World& world, const Captures&, const Table&) { world.mc.part<FakeAttachments>().unreachable = true; });
  step(QStringLiteral("the environment no longer has the attachment"), [](World& world, const Captures&, const Table&) {
    serve(world);
    world.mc.part<FakeAttachments>().gone.insert(QStringLiteral("file-1"));
    openSent(world, QStringLiteral("build.log"), QStringLiteral("text/plain"), "built\n");
  });
  step(QStringLiteral("the environment is reachable again and the user retries"), [](World& world, const Captures&, const Table&) {
    FakeAttachments& fake = world.mc.part<FakeAttachments>();
    fake.unreachable = false;
    fake.gone.clear();
    world.brick->click(QStringLiteral("attachmentViewerRetry"));
  });
  step(QStringLiteral("the attachment is shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return viewed(world).value(QStringLiteral("text")) == QLatin1String("built\n"); }, [&] { return QStringLiteral("the attachment; the viewer is %1").arg(show(viewed(world))); });
  });
  step(QStringLiteral("the user is told the file could not be saved with the reason"), [](World& world, const Captures&, const Table&) { expectToast(world, QStringLiteral("error"), QStringLiteral("Could not save build.log")); });

  // --- A page.
  step(QStringLiteral("the user opened an attachment as a rendered page an hour ago"), [](World& world, const Captures&, const Table&) {
    openSent(world, QStringLiteral("page.html"), QStringLiteral("text/html"), kPage);
    expect(viewed(world).value(QStringLiteral("kind")) == QLatin1String("page"), QStringLiteral("the viewer is %1").arg(show(viewed(world))));
  });
  step(QStringLiteral("the user switches to its source"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakeAttachments>().signatures = 100;
    world.brick->click(QStringLiteral("attachmentViewerSource"));
  });
  step(QStringLiteral("the source is shown without the user reconnecting"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return viewed(world).value(QStringLiteral("source")).toByteArray() == kPage; }, [&] { return QStringLiteral("the source; the viewer is %1").arg(show(viewed(world))); });
    expect(world.mc.part<FakeAttachments>().signatures == 101, QStringLiteral("the source was not read through a new address"));
  });
  step(QStringLiteral("the attachment %1 is not valid text").arg(q), [](World& world, const Captures& c, const Table&) {
    openSent(world, c[0], QStringLiteral("text/html"), kPage);
    world.mc.part<FakeAttachments>().bytes.insert(QStringLiteral("file-1"), QByteArray("<h1>caf\xE9</h1>"));
  });
  step(QStringLiteral("the user is told the source could not be loaded"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return viewed(world).value(QStringLiteral("sourceProblem")) == QLatin1String("The source could not be loaded."); }, [&] { return show(viewed(world)); });
  });
  step(QStringLiteral("the user switches back to the rendered page"), [](World& world, const Captures&, const Table&) { world.brick->click(QStringLiteral("attachmentViewerSource")); });
  step(QStringLiteral("the page is shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.brick->root()->findChild<QQuickItem*>(QStringLiteral("attachmentViewerPage")) != nullptr; }, QStringLiteral("the rendered page"));
  });

  // --- Copying.
  step(QStringLiteral("the user is viewing a text attachment that is (within|over) the preview limit"), [](World& world, const Captures& c, const Table&) {
    const QByteArray bytes = c[0] == QLatin1String("within") ? QByteArray("short\n") : QByteArray(1024 * 1024 + 10, 'x');
    QGuiApplication::clipboard()->clear();
    openSent(world, QStringLiteral("build.log"), QStringLiteral("text/plain"), bytes);
  });
  step(QStringLiteral("the user copies it"), [](World& world, const Captures&, const Table&) { world.brick->click(QStringLiteral("attachmentViewerCopy")); });
  step(QStringLiteral("the copy is all of its text"), [](World&, const Captures&, const Table&) {
    expect(QGuiApplication::clipboard()->text() == QLatin1String("short\n"), QStringLiteral("the clipboard holds %1 characters").arg(QGuiApplication::clipboard()->text().size()));
  });
  step(QStringLiteral("the copy is only the part shown, and the action says so"), [](World& world, const Captures&, const Table&) {
    expect(QGuiApplication::clipboard()->text().size() == 1024 * 1024, QStringLiteral("the clipboard holds %1 characters").arg(QGuiApplication::clipboard()->text().size()));
    const QString label = world.brick->item(QStringLiteral("attachmentViewerCopy"))->property("text").toString();
    expect(label == QLatin1String("Copy part shown"), QStringLiteral("the action reads %1").arg(label));
  });
});

}  // namespace
