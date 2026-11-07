// The phone's side of features/files/file-viewer-and-editing.feature: a
// thread's files on its own screen, and attachments in the viewer the shell
// hosts. The MC's side is the desktop harness's FakeFiles, and attachments as
// the desktop's AttachmentViewerSteps serves them.

#include <QBuffer>
#include <QDateTime>
#include <QFile>
#include <QImage>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QQuickWindow>
#include <QTcpSocket>
#include <QTemporaryDir>

#include "AttachmentViewerController.h"
#include "FakeFiles.h"
#include "FakeThreads.h"
#include "Harness.h"
#include "MediaFixtures.h"
#include "NativeShell.h"
#include "Phone.h"
#include "RightPanelController.h"
#include "ShellBridge.h"
#include "WorkspaceFiles.h"
#include "World.h"

// An image a tool call viewed, when the scenario is about one (ToolCallSteps.cpp).
bool expectViewedImage(World& world);

namespace {

#define S QStringLiteral

const QString kPeer = S("mc-b");
const QString kPeerEnvironment = S("env-b");
const QString kPeerThread = S("thread-remote");
const QString kThreadTitle = S("Tax line");

struct FakeAttachments {
  QHash<QString, QByteArray> bytes;
  QSet<QString> gone;
  bool unreachable = false;
  int signatures = 0;
  std::shared_ptr<QTemporaryDir> saves;
};

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

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(S("assets.createUrl"), [&mc](const FakeMc::Rpc& rpc) {
    if (signFile(mc, rpc)) return;
    FakeAttachments& fake = mc.part<FakeAttachments>();
    const QString id = rpc.payload.value(QLatin1String("resource")).toObject().value(QLatin1String("attachmentId")).toString();
    if (id.isEmpty()) return mc.passOn(rpc);
    // McClient's own word for a call with no connection to carry it.
    if (fake.unreachable) return mc.refuse(rpc, S("not connected"));
    ++fake.signatures;
    mc.reply(rpc, QJsonObject{{S("relativeUrl"), S("/api/assets/attachment/%1/%2").arg(id).arg(fake.signatures)},
                              {S("expiresAt"), double(QDateTime::currentDateTimeUtc().addSecs(3600).toMSecsSinceEpoch())}});
  });
  mc.onRaw(S("/api/assets/attachment/"), [&mc](QTcpSocket* socket, const QByteArray& head) {
    socket->read(head.size());
    FakeAttachments& fake = mc.part<FakeAttachments>();
    const QString id = QString::fromUtf8(head.left(head.indexOf('\r')).split(' ').value(1)).section(QLatin1Char('/'), 4, 4);
    if (fake.gone.contains(id) || !fake.bytes.contains(id)) {
      socket->write(
          "HTTP/1.1 404 Not Found\r\nConnection: "
          "close\r\nContent-Length: 0\r\n\r\n");
    } else {
      const QByteArray body = fake.bytes.value(id);
      socket->write("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\n\r\n" + body);
    }
    socket->disconnectFromHost();
  });
});

WorkspaceFiles& files(World& world) { return *world.native().controller<RightPanelController>()->files(); }

QString describe(World& world) {
  return S("the viewer has \"%1\" (%2 %3, \"%4\"); the screen says: %5")
      .arg(files(world).openPath(), files(world).mediaKind(), files(world).fileStatus(), files(world).fileProblem(),
           world.texts().join(S(" | ")));
}

// The thread on the phone's screen, opened on first need.
void inThread(World& world) {
  if (!world.thread.isEmpty()) return;
  world.thread = haveThread(world, kThreadTitle);
  openThread(world, kThreadTitle);
}

// The thread's Files screen, reached by its button.
void filesScreen(World& world) {
  inThread(world);
  if (!world.find(S("filesPanel"))) world.tap(S("openFiles"));
  world.item(S("filesPanel"));
}

void openFile(World& world, const QString& path) {
  FakeFiles& fake = fakeFiles(world.mc);
  if (!fake.files.contains(path)) {
    fake.files.insert(path, path.endsWith(QLatin1String(".html")) ? S("<html><body><h1>Shop</h1></body></html>\n")
                                                                  : S("export const value = 1;\nexport const other = 2;\n"));
  }
  filesScreen(world);
  world.bridge().dispatch(S("files.open"), QVariantMap{{S("path"), path}});
  world.waitFor([&] { return files(world).openPath() == path && files(world).fileStatus() != QLatin1String("loading"); },
                [&] { return describe(world); });
}

QVariantMap viewed(World& world) { return world.state(S("attachmentViewer")).toMap(); }

// A draft's attachment opened from its chip in the composer.
void openDraft(World& world, const QString& name, const QString& mimeType, const QByteArray& bytes) {
  inThread(world);
  QVariantMap file{{S("name"), name}, {S("mimeType"), mimeType}};
  if (mimeType.startsWith(QLatin1String("image/"))) {
    file.insert(S("base64"), QString::fromLatin1(bytes.toBase64()));
  } else {
    // A file comes from where it was picked; only an image is taken as bytes.
    FakeAttachments& fake = world.mc.part<FakeAttachments>();
    if (!fake.saves) fake.saves = std::make_shared<QTemporaryDir>();
    QFile picked(fake.saves->filePath(name));
    if (!picked.open(QIODevice::WriteOnly)) fail(picked.errorString());
    picked.write(bytes);
    file.insert(S("path"), picked.fileName());
    world.mc.onRpc(S("attachments.createUploadUrl"), [&mc = world.mc](const FakeMc::Rpc& rpc) {
      mc.reply(rpc, QJsonObject{{S("attachmentId"), S("up-1")}, {S("relativeUrl"), S("/api/assets/attachment/up-1/0")}});
    });
  }
  world.bridge().dispatch(S("composer.attach"), QVariantMap{{S("files"), QVariantList{file}}});
  world.tap(S("attachmentOpen:") + name);
  world.waitFor([&] { return viewed(world).value(S("name")) == name; }, S("the attachment to open"));
}

// A message of the thread carrying `attachments`.
void sendMessage(World& world, const QJsonArray& attachments) {
  inThread(world);
  const QString run = S("run-1");
  setEntity(world.mc, world.thread, S("run"), run, {{S("id"), run}, {S("ordinal"), 1}, {S("status"), S("completed")}});
  setEntity(world.mc, world.thread, S("turn-item"), S("message:") + run,
            {{S("id"), S("message:") + run},
             {S("type"), S("user_message")},
             {S("runId"), run},
             {S("ordinal"), 2},
             {S("status"), S("completed")},
             {S("text"), S("Add a tax line to the cart")},
             {S("updatedAt"), S("2026-09-23T09:00:00Z")},
             {S("attachments"), attachments}});
}

// A sent message's file, opened from the conversation.
void openSent(World& world, const QString& name, const QString& mimeType, const QByteArray& bytes, bool wait = true) {
  FakeAttachments& fake = world.mc.part<FakeAttachments>();
  if (!fake.saves) {
    fake.saves = std::make_shared<QTemporaryDir>();
    world.native().controller<AttachmentViewerController>()->setSaveFolder(fake.saves->path());
  }
  fake.bytes.insert(S("file-1"), bytes);
  sendMessage(world, {QJsonObject{{S("type"), S("file")},
                                  {S("id"), S("file-1")},
                                  {S("name"), name},
                                  {S("mimeType"), mimeType},
                                  {S("sizeBytes"), qint64(bytes.size())}}});
  world.tap(S("sentFileOpen-file-1"));
  if (wait) {
    world.waitFor(
        [&] {
          const QString kind = viewed(world).value(S("kind")).toString();
          return !kind.isEmpty() && kind != QLatin1String("loading");
        },
        S("the attachment to load"));
  }
}

void expectToast(World& world, const QString& type, const QString& title, const QString& description = {}) {
  world.waitFor(
      [&] {
        for (const QVariant& toast : world.state(S("toasts")).toMap().value(S("items")).toList()) {
          const QVariantMap fields = toast.toMap();
          if (fields.value(S("type")) == type && fields.value(S("title")).toString().startsWith(title) &&
              (description.isEmpty() || fields.value(S("description")) == description))
            return true;
        }
        return false;
      },
      [&] { return S("a %1 toast \"%2\"; toasts are %3").arg(type, title, show(world.state(S("toasts")))); });
}

QQuickItem* shownMedia(World& world, const QString& objectName) {
  QQuickItem* media = world.item(objectName);
  return media;
}

void expectShowing(World& world, int n) {
  world.waitFor(
      [&] { return world.item(S("imageViewerName"))->property("text").toString().startsWith(S("shot-%1.png").arg(n)); },
      [&] { return S("image %1; the viewer is named %2").arg(n).arg(world.item(S("imageViewerName"))->property("text").toString()); });
}

const Steps steps([] {
  const QString q = kQuoted;

  step(S("%1 holds the text file %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QString lines;
    for (int line = 1; line <= 12; ++line) lines += S("line %1\n").arg(line);
    fakeFiles(world.mc).files.insert(c[1], lines);
  });
  step(S("%1 in %1 is 3 MB").arg(q), [](World& world, const Captures& c, const Table&) {
    FakeFiles& fake = fakeFiles(world.mc);
    fake.files.insert(c[0], S("a line of the log\n").repeated(200));
    fake.truncated.insert(c[0], 3 * 1024 * 1024);
  });
  // A path has a dot or a slash; a bare name is a thread.
  step(S("the user opens \"([^\"]*[./][^\"]*)\""), [](World& world, const Captures& c, const Table&) { openFile(world, c[0]); });
  step(S("the user is told the preview is limited to the first 1 MB of the "
         "file"),
       [](World& world, const Captures&, const Table&) {
         const QString notice = S("Preview limited to the first 1 MB of a 3,145,728 byte file.");
         world.waitFor([&] { return world.shows(notice); }, [&] { return describe(world); });
       });

  // --- Media.
  step(S("the file is previewed as (an image|a video|audio|a document|a web "
         "page)"),
       [](World& world, const Captures& c, const Table&) {
         const QString path = files(world).openPath();
         if (c[0] == QLatin1String("a web page")) {
           world.waitFor([&] { return files(world).rendered() && world.find(S("fileOpenPreview")); }, [&] { return describe(world); });
           return;
         }
         if (c[0] == QLatin1String("a document")) {
           QQuickItem* document = shownMedia(world, S("documentView"));
           world.waitFor([&] { return document->property("pageCount").toInt() > 0; }, [&] { return describe(world); });
         } else if (c[0] == QLatin1String("an image")) {
           world.waitFor(
               [&] {
                 QQuickItem* image = world.find(S("fileImage"));
                 return image && image->property("status").toInt() == 1 && image->property("source").toUrl() == files(world).mediaUrl();
               },
               [&] { return describe(world); });
         } else {
           QQuickItem* player = shownMedia(world, S("mediaPlayerView"));
           expect(player->property("video").toBool() == (c[0] == QLatin1String("a video")), describe(world));
           world.waitFor([&] { return player->property("loaded").toBool(); }, [&] { return describe(world); });
         }
         expect(fakeFiles(world.mc).downloaded.contains(path), describe(world));
         expect(!world.find(S("fileLines")), S("the file shows as text too"));
       });
  step(S("the thread is on another machine of the cluster"), [](World& world, const Captures&, const Table&) {
    world.mc.join(kPeer, kPeerEnvironment);
    world.mc.sendPeerRow(
        kPeerEnvironment, S("shop"),
        {{S("id"), S("shop")}, {S("title"), S("shop")}, {S("workspaceRoot"), S("/work/shop")}, {S("scripts"), QJsonArray()}}, S("project"));
    world.mc.sendPeerRow(kPeerEnvironment, kPeerThread,
                         {{S("id"), kPeerThread},
                          {S("title"), S("Remote")},
                          {S("projectId"), S("shop")},
                          {S("createdAt"), S("2026-09-23T09:00:00Z")},
                          {S("updatedAt"), S("2026-09-23T09:00:00Z")}});
    openThread(world, S("Remote"));
    world.thread = kPeerThread;
    world.waitFor([&] { return files(world).environment() == kPeerEnvironment && !files(world).root().isEmpty(); },
                  S("the Files tab to follow the thread"));
  });
  step(S("the image comes from the machine the thread is on"), [](World& world, const Captures&, const Table&) {
    world.sync();
    FakeMc::Rpc signing;
    for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
      if (rpc.method == QLatin1String("assets.createUrl")) signing = rpc;
    }
    expect(signing.environment == kPeerEnvironment &&
               signing.payload.value(QLatin1String("resource")).toObject().value(QLatin1String("threadId")) == kPeerThread,
           S("the address was signed by \"%1\"").arg(signing.environment));
  });
  step(S("loading %1 fails once").arg(q), [](World& world, const Captures& c, const Table&) {
    fakeFiles(world.mc).files.insert(c[0], S("media"));
    fakeFiles(world.mc).loadFailsOnce.insert(c[0]);
  });
  step(S("the user is told the (image|video|audio|document) could not be "
         "loaded"),
       [](World& world, const Captures& c, const Table&) {
         world.waitFor([&] { return files(world).fileStatus() == QLatin1String("error"); }, [&] { return describe(world); });
         expect(files(world).fileProblem() == S("The %1 could not be loaded.").arg(c[0]) && world.find(S("fileRetry")), describe(world));
       });
  step(S("the user retries"), [](World& world, const Captures&, const Table&) { world.tap(S("fileRetry")); });
  step(S("the image is shown"), [](World& world, const Captures&, const Table&) {
    if (expectViewedImage(world)) return;
    world.waitFor(
        [&] {
          QQuickItem* image = world.find(S("fileImage"));
          return image && image->property("status").toInt() == 1;
        },
        [&] { return describe(world); });
  });
  step(S("the audio plays"), [](World& world, const Captures&, const Table&) {
    QQuickItem* player = shownMedia(world, S("mediaPlayerView"));
    world.waitFor([&] { return player->property("loaded").toBool(); }, [&] { return describe(world); });
    QMetaObject::invokeMethod(player, "toggle");
    world.waitFor([&] { return player->property("playing").toBool(); }, [&] { return describe(world); });
  });

  // --- The way out of the phone's files.
  step(S("the user steps back from the file"), [](World& world, const Captures&, const Table&) { world.back(); });
  step(S("the thread is on screen again, and its files can be opened again"), [](World& world, const Captures&, const Table&) {
    world.item(S("routeView"));
    expect(!world.find(S("filesPanel")) && shownThread(world) == kThreadTitle, S("the screen says: %1").arg(world.texts().join(S(" | "))));
    world.tap(S("openFiles"));
    world.item(S("filesPanel"));
  });

  // --- Copying.
  step(S("the user is reading %1 in the viewer").arg(q), [](World& world, const Captures& c, const Table&) {
    world.clipboard.clear();
    openFile(world, c[0]);
    expect(files(world).fileStatus() == QLatin1String("ready"), describe(world));
  });
  // The phone layout has no palette: it comes with a hardware keyboard at a
  // tablet's size.
  step(S("the user copies the file's text from the (viewer|command palette)"), [](World& world, const Captures& c, const Table&) {
    if (c[0] == QLatin1String("viewer")) {
      world.tap(S("fileCopy"));
      return;
    }
    world.resize(1024, 768);
    world.item(S("desktopLayout"));
    world.press(S("mod+k"));
    world.awaitPopup(S("commandPalette"));
    world.type(S("Copy file contents"));
    world.waitFor([&] { return world.shows(S("Copy file contents")); }, S("the palette to offer it"));
    world.press(S("Return"));
  });
  step(S("the whole of %1 is on the clipboard").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString wanted = fakeFiles(world.mc).files.value(c[0]);
    world.waitFor([&] { return !wanted.isEmpty() && world.clipboard == wanted; },
                  [&] { return S("the clipboard holds \"%1\"").arg(world.clipboard); });
  });
  step(S("the user is told the file's text was copied"), [](World& world, const Captures&, const Table&) {
    expectToast(world, S("success"), S("File contents copied"), files(world).openPath());
  });
  step(S("the first megabyte of %1 is on the clipboard").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString wanted = fakeFiles(world.mc).files.value(c[0]);
    world.waitFor([&] { return fakeFiles(world.mc).truncated.contains(c[0]) && world.clipboard == wanted; },
                  [&] { return S("the clipboard holds \"%1\"").arg(world.clipboard); });
  });
  step(S("the user is told only the first 1 MB of %1 was copied").arg(q), [](World& world, const Captures& c, const Table&) {
    expectToast(world, S("success"), S("File contents copied"), S("Only the first 1 MB of %1.").arg(c[0]));
  });

  // --- Attachments.
  step(S("the user has attached %1 to a draft").arg(q), [](World& world, const Captures& c, const Table&) {
    const QHash<QString, std::pair<QString, QByteArray>> kinds{{S("receipt.png"), {S("image/png"), picture()}},
                                                               {S("notes.md"), {S("text/markdown"), "# Notes\n"}},
                                                               {S("build.log"), {S("text/plain"), "built\n"}},
                                                               {S("invoice.pdf"), {S("application/pdf"), mediaFixture(S("invoice.pdf"))}}};
    openDraft(world, c[0], kinds.value(c[0]).first, kinds.value(c[0]).second);
  });
  step(S("the user opens the attachment from the draft"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(S("it is shown as an image"), [](World& world, const Captures&, const Table&) {
    expect(viewed(world).value(S("kind")) == QLatin1String("image"), show(viewed(world)));
    world.item(S("attachmentViewerImage"));
  });
  step(S("it is shown as rendered Markdown that can switch to source"), [](World& world, const Captures&, const Table&) {
    world.item(S("attachmentViewerMarkdown"));
    world.tap(S("attachmentViewerSource"));
    world.item(S("attachmentViewerText"));
  });
  step(S("it is shown as text"), [](World& world, const Captures&, const Table&) {
    world.waitFor(
        [&] {
          QQuickItem* text = world.find(S("attachmentViewerText"));
          return text && text->property("text") == QLatin1String("built\n");
        },
        S("the text"));
  });
  step(S("it is shown as a document the user can page through"), [](World& world, const Captures&, const Table&) {
    QQuickItem* document = world.item(S("documentView"));
    world.waitFor([&] { return document->property("pageCount").toInt() == 2; }, S("the document's two pages"));
    QMetaObject::invokeMethod(document, "goTo", Q_ARG(QVariant, 1));
    world.waitFor([&] { return document->property("currentPage").toInt() == 1; }, S("the second page"));
  });
  step(S("a sent message carries the attachment %1").arg(q),
       [](World& world, const Captures& c, const Table&) { world.mc.part<FakeSent>().name = c[0]; });
  step(S("the user opens the attachment from the conversation"), [](World& world, const Captures&, const Table&) {
    const QString name = world.mc.part<FakeSent>().name;
    openSent(world, name, S("application/pdf"), mediaFixture(name));
  });
  step(S("%1 is shown as a document from the environment").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* document = world.item(S("documentView"));
    world.waitFor([&] { return document->property("pageCount").toInt() == 2; }, S("the document's two pages"));
    expect(viewed(world).value(S("name")) == c[0] && world.mc.part<FakeAttachments>().signatures > 0, show(viewed(world)));
  });

  // --- Images.
  step(S("a message carries three images"), [](World& world, const Captures&, const Table&) {
    FakeAttachments& fake = world.mc.part<FakeAttachments>();
    QJsonArray images;
    for (int n = 1; n <= 3; ++n) {
      fake.bytes.insert(S("image-%1").arg(n), picture());
      images.append(QJsonObject{{S("type"), S("image")},
                                {S("id"), S("image-%1").arg(n)},
                                {S("name"), S("shot-%1.png").arg(n)},
                                {S("mimeType"), S("image/png")},
                                {S("sizeBytes"), 2048}});
    }
    sendMessage(world, images);
  });
  step(S("the user opens the second image"), [](World& world, const Captures&, const Table&) {
    // A picture widens its square as it loads, moving its neighbours.
    world.waitFor(
        [&] {
          for (int n = 1; n <= 3; ++n) {
            QQuickItem* square = world.find(S("attachment-image-%1").arg(n));
            if (!square || !square->property("pictured").toBool()) return false;
          }
          return true;
        },
        S("the pictures in the conversation"));
    world.sync();
    world.tap(S("attachmentOpenLarge-image-2"));
    world.waitFor(
        [&] {
          QQuickItem* image = world.find(S("imageViewerPicture"));
          return image && image->property("status").toInt() == 1 && image->width() > 0;
        },
        S("the picture to load"));
  });
  step(S("it is shown large"), [](World& world, const Captures&, const Table&) {
    expect(world.item(S("imageViewerStage"))->width() >= world.window().width() * 0.9,
           S("the stage is %1 wide in a window %2 wide").arg(world.item(S("imageViewerStage"))->width()).arg(world.window().width()));
    expectShowing(world, 2);
  });
  step(S("the user can step to the previous and next image"), [](World& world, const Captures&, const Table&) {
    world.tap(S("imageViewerPrevious"));
    expectShowing(world, 1);
    world.tap(S("imageViewerNext"));
    expectShowing(world, 2);
  });

  // --- As captured.
  step(S("the user attached %1 and has since changed the project's %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString name = c[0].section(QLatin1Char('/'), -1);
    openDraft(world, name, S("text/plain"), "captured");
    world.bridge().dispatch(S("attachment.viewer.close"), {});
    QFile file(world.mc.part<FakeAttachments>().saves->filePath(name));
    if (!file.open(QIODevice::WriteOnly)) fail(file.errorString());
    file.write("changed since");
  });
  step(S("the user opens the attachment"), [](World& world, const Captures&, const Table&) {
    if (!viewed(world).isEmpty()) return;  // A scenario's Given already opened it, failed or not.
    world.tap(S("attachmentOpen:app.ts"));
  });
  step(S("the captured contents are shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return viewed(world).value(S("text")) == QLatin1String("captured"); }, [&] { return show(viewed(world)); });
  });

  // --- A sent attachment.
  step(S("the user is viewing an attachment of a sent message"),
       [](World& world, const Captures&, const Table&) { openSent(world, S("build.log"), S("text/plain"), "built\n"); });
  step(S("the user saves it"), [](World& world, const Captures&, const Table&) { world.tap(S("attachmentViewerSave")); });
  step(S("the file is downloaded under its own name"), [](World& world, const Captures&, const Table&) {
    expectToast(world, S("success"), S("Saved build.log"));
    QFile file(world.mc.part<FakeAttachments>().saves->filePath(S("build.log")));
    expect(file.open(QIODevice::ReadOnly) && file.readAll() == "built\n", S("the saved file is missing or differs"));
  });
  step(S("the environment is unreachable"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakeAttachments>().unreachable = true;
    openSent(world, S("build.log"), S("text/plain"), "built\n");
  });
  step(S("the environment no longer has the attachment"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakeAttachments>().gone.insert(S("file-1"));
    openSent(world, S("build.log"), S("text/plain"), "built\n");
  });
  step(S("the environment is reachable again and the user retries"), [](World& world, const Captures&, const Table&) {
    FakeAttachments& fake = world.mc.part<FakeAttachments>();
    fake.unreachable = false;
    fake.gone.clear();
    world.tap(S("attachmentViewerRetry"));
  });
  step(S("the attachment is shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return viewed(world).value(S("text")) == QLatin1String("built\n"); }, [&] { return show(viewed(world)); });
  });
});

}  // namespace
