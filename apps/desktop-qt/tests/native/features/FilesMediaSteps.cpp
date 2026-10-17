// Media in the file viewer (features/files/file-viewer-and-editing.feature):
// an image previewed from the address the thread's environment signed, a
// preview that fails to load and its retry, and a thread on another machine
// of the cluster; and a file a reply links to (timeline/markdown.feature).
// FakeFiles signs and serves the files.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include "FilesWorkspace.h"
#include "Stream.h"

namespace {

using namespace filesteps;

QString describeMedia(World& world) {
  return QStringLiteral("the viewer has \"%1\" (%2 %3, \"%4\") from %5")
      .arg(files(world).openPath(), files(world).mediaKind(), files(world).fileStatus(), files(world).fileProblem(),
           files(world).mediaUrl().toString());
}

// Whether the panel draws its part named `objectName`.
bool drawn(World& world, const QString& objectName) {
  const QQuickItem* item = world.brick->root()->findChild<QQuickItem*>(objectName);
  return item && item->isVisible();
}

// The panel's image, once it has loaded.
QQuickItem* loadedImage(World& world) {
  showPanel(world);
  QQuickItem* image = nullptr;
  world.waitFor(
      [&] {
        image = world.brick->root()->findChild<QQuickItem*>(QStringLiteral("fileImage"));
        // QQuickImageBase::Ready
        return image && image->isVisible() && image->property("status").toInt() == 1;
      },
      [&] { return QStringLiteral("the image to load; %1").arg(describeMedia(world)); });
  return image;
}

// Every `assets.createUrl` for a workspace's file.
QList<FakeMc::Rpc> signings(World& world) {
  world.sync();
  QList<FakeMc::Rpc> calls;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    const QString tag = rpc.payload.value(QLatin1String("resource")).toObject().value(QLatin1String("_tag")).toString();
    if (rpc.method == QLatin1String("assets.createUrl") && tag.endsWith(QLatin1String("-file"))) calls.append(rpc);
  }
  return calls;
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the file is previewed as (an image|a video|audio|a document|a web page)"), [](World& world, const Captures& c, const Table&) {
    if (c[0] != QLatin1String("an image")) fail(QStringLiteral("the desktop does not preview %1 yet").arg(c[0]));
    const QString path = files(world).openPath();
    QQuickItem* image = loadedImage(world);
    expect(image->property("source").toUrl() == files(world).mediaUrl() && fakeFiles(world.mc).downloaded.contains(path),
           describeMedia(world));
    expect(!drawn(world, QStringLiteral("fileLines")) && !drawn(world, QStringLiteral("fileEdit")), QStringLiteral("the file shows as text too"));
    // Never read as text.
    for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
      expect(rpc.method != QLatin1String("projects.readFile") || rpc.payload.value(QLatin1String("relativePath")) != path,
             QStringLiteral("%1 was read as text").arg(path));
    }
  });
  step(QStringLiteral("loading %1 fails once").arg(q), [](World& world, const Captures& c, const Table&) {
    ensureViewerFile(world, c[0]);
    fakeFiles(world.mc).loadFailsOnce.insert(c[0]);
  });
  step(QStringLiteral("the user is told the (image|video|audio|document) could not be loaded"), [](World& world, const Captures& c, const Table&) {
    showPanel(world);
    world.waitFor([&] { return files(world).fileStatus() == QLatin1String("error"); }, [&] { return describeMedia(world); });
    expect(files(world).fileProblem() == QStringLiteral("The %1 could not be loaded.").arg(c[0]) && drawn(world, QStringLiteral("fileRetry")),
           describeMedia(world));
  });
  // A file a reply linked to, opened in the Files tab (timeline/markdown.feature).
  step(QStringLiteral("%1 opens as a large preview").arg(q), [](World& world, const Captures& c, const Table&) {
    if (WorkspaceFiles::mediaKindOf(c[0]) != QLatin1String("image")) fail(QStringLiteral("the desktop does not preview %1 yet").arg(c[0]));
    world.waitFor([&] { return panel(world)->activeTab() == QLatin1String("files") && files(world).openPath() == c[0]; },
                  [&] { return QStringLiteral("the %1 tab; %2").arg(panel(world)->activeTab(), describeMedia(world)); });
    QQuickItem* image = loadedImage(world);
    expect(image->property("source").toUrl() == files(world).mediaUrl() && fakeFiles(world.mc).downloaded.contains(c[0]), describeMedia(world));
  });
  step(QStringLiteral("the image is shown"), [](World& world, const Captures&, const Table&) {
    QQuickItem* image = loadedImage(world);
    expect(image->property("source").toUrl() == files(world).mediaUrl(), describeMedia(world));
  });

  // A thread of the project on another member of the cluster, open.
  step(QStringLiteral("the thread is on another machine of the cluster"), [](World& world, const Captures&, const Table&) {
    world.mc.join(stream::kPeer, stream::kPeerEnvironment);
    world.mc.sendPeerRow(stream::kPeerEnvironment, stream::kProject,
                         {{QStringLiteral("id"), stream::kProject}, {QStringLiteral("title"), stream::kProject},
                          {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + stream::kProject}, {QStringLiteral("scripts"), QJsonArray()}},
                         QStringLiteral("project"));
    world.mc.sendPeerRow(stream::kPeerEnvironment, stream::kPeerThread,
                         {{QStringLiteral("id"), stream::kPeerThread}, {QStringLiteral("title"), QStringLiteral("Remote")},
                          {QStringLiteral("projectId"), stream::kProject}, {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                          {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    world.sync();
    stream::FakeStreams& fake = world.mc.part<stream::FakeStreams>();
    fake.thread = stream::kPeerThread;
    fake.environment = stream::kPeerEnvironment;
    stream::look(world, stream::kPeerEnvironment + QLatin1Char(':') + stream::kPeerThread);
    world.waitFor([&] { return files(world).environment() == stream::kPeerEnvironment && !files(world).root().isEmpty(); },
                  QStringLiteral("the Files tab to follow the thread"));
  });
  step(QStringLiteral("the image comes from the machine the thread is on"), [](World& world, const Captures&, const Table&) {
    const QList<FakeMc::Rpc> calls = signings(world);
    expect(!calls.isEmpty(), QStringLiteral("no address was signed"));
    const QJsonObject resource = calls.last().payload.value(QLatin1String("resource")).toObject();
    expect(calls.last().environment == stream::kPeerEnvironment && resource.value(QLatin1String("threadId")) == stream::kPeerThread,
           QStringLiteral("the address was signed by \"%1\" for %2").arg(calls.last().environment, show(resource.toVariantMap())));
  });
});

}  // namespace
