// Connecting the shell to its MC, who owns what once it has, and the MCs
// clustered with it (features/desktop/native-connection.feature).

#include <QGuiApplication>
#include <QImage>
#include <QQuickItem>
#include <QSet>
#include <QUrl>
#include <QUrlQuery>
#include <QVariantList>

#include "Brick.h"
#include "Harness.h"
#include "NativeShell.h"
#include "World.h"

namespace {

struct ScriptedRun {
  int started = 0;
  // A scripted screenshot: whether the window had the MC's rows when it
  // was grabbed, and the grab.
  bool snapshotIn = false;
  QImage shot;
};

const Steps steps([] {
  const QString q = kQuoted;

  // The MC.
  step(QStringLiteral("the desktop's MC %1 serves the environment %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.name = c[0];
    world.mc.environmentId = c[1];
  });
  step(QStringLiteral("the MC is clustered with %1, which serves %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.join(c[0], c[1]);
    world.sync();
  });

  // Connecting.
  step(QStringLiteral("the desktop shell connects to its MC with the token %1").arg(q),
       [](World& world, const Captures& c, const Table&) { world.connect(c[0]); });
  step(QStringLiteral("the desktop shell connects to its MC"), [](World& world, const Captures&, const Table&) { world.connect(); });
  step(QStringLiteral("the desktop shell is connected to its MC"), [](World& world, const Captures&, const Table&) {
    world.connect();
    world.waitFor([&world] { return world.native().isActive(); },
                  QStringLiteral("the shell to start"));
  });
  // A scripted run (main.cpp --action, --key, --screenshot) starts on
  // NativeShell::ready.
  step(QStringLiteral("a scripted run is waiting for the desktop app"), [](World& world, const Captures&, const Table&) {
    int& started = world.mc.part<ScriptedRun>().started;
    QObject::connect(&world.native(), &NativeShell::ready, &world.native(), [&started] { ++started; });
  });
  step(QStringLiteral("the scripted run has not started"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(world.mc.part<ScriptedRun>().started == 0, QStringLiteral("it started"));
  });
  step(QStringLiteral("the scripted run starts once"), [](World& world, const Captures&, const Table&) {
    const int& started = world.mc.part<ScriptedRun>().started;
    world.waitFor([&] { return started > 0; }, QStringLiteral("the scripted run to start"));
    world.sync();
    expect(started == 1, QStringLiteral("it started %1 times").arg(started));
  });
  // A scripted screenshot (main.cpp --screenshot) grabs the native window on
  // NativeShell::ready; with no project that window is the home page.
  step(QStringLiteral("the desktop app runs without a display"), [](World&, const Captures&, const Table&) {
    expect(QGuiApplication::platformName() == QLatin1String("offscreen"), QStringLiteral("the platform is %1").arg(QGuiApplication::platformName()));
  });
  step(QStringLiteral("the user starts the desktop app asking for a screenshot"), [](World& world, const Captures&, const Table&) {
    ScriptedRun& run = world.mc.part<ScriptedRun>();
    QObject::connect(&world.native(), &NativeShell::ready, &world.native(), [&world, &run] {
      ++run.started;
      run.snapshotIn = world.state(QStringLiteral("sidebar")).isValid();
      world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nHomePage {}\n", QSize(900, 700));
      run.shot = world.brick->grab();
    }, Qt::SingleShotConnection);
    world.connect();
    world.waitFor([&run] { return run.started > 0; }, QStringLiteral("the scripted run to start"));
  });
  step(QStringLiteral("the screenshot is taken once the MC's first snapshot is in"), [](World& world, const Captures&, const Table&) {
    const ScriptedRun& run = world.mc.part<ScriptedRun>();
    expect(run.started == 1 && run.snapshotIn, QStringLiteral("started %1 times, with the snapshot %2").arg(run.started).arg(run.snapshotIn));
  });
  step(QStringLiteral("the screenshot shows the app's native window, not an empty view"), [](World& world, const Captures&, const Table&) {
    const QImage& shot = world.mc.part<ScriptedRun>().shot;
    expect(!shot.isNull(), QStringLiteral("nothing was grabbed"));
    // Something was drawn over the background: the home page's title and action.
    QSet<QRgb> colours;
    for (int y = 0; y < shot.height() && colours.size() < 3; y += 4) {
      for (int x = 0; x < shot.width() && colours.size() < 3; x += 4) colours.insert(shot.pixel(x, y));
    }
    expect(colours.size() >= 3, QStringLiteral("the screenshot is one flat colour"));
    const QQuickItem* title = world.brick->item(QStringLiteral("homeTitle"));
    expect(title->isVisible() && !title->property("text").toString().isEmpty(), QStringLiteral("the home page has no title"));
  });
  step(QStringLiteral("the MC holds back its snapshot"), [](World& world, const Captures&, const Table&) {
    world.mc.holdSnapshot = true;
  });
  step(QStringLiteral("the MC sends its snapshot"), [](World& world, const Captures&, const Table&) {
    world.mc.sendSnapshot();
    world.sync();
  });
  step(QStringLiteral("the MC stops accepting connections"), [](World& world, const Captures&, const Table&) {
    world.mc.stopAccepting();
  });
  step(QStringLiteral("the MC drops the connection"), [](World& world, const Captures&, const Table&) {
    world.mc.drop();
    world.waitFor([&world] { return !world.native().client()->isReady(); }, QStringLiteral("the shell to see the drop"));
  });
  step(QStringLiteral("the MC was reached with the token %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(!world.mc.connections.isEmpty(), QStringLiteral("the MC was never reached"));
    const QUrl url = world.mc.connections.first();
    expect(url.path() == QLatin1String("/ws"), QStringLiteral("connected to %1, not /ws").arg(url.path()));
    const QString token = QUrlQuery(url).queryItemValue(QStringLiteral("token"));
    expect(token == c[0], QStringLiteral("connected with the token \"%1\"").arg(token));
  });
  step(QStringLiteral("the shell subscribed to the MC's %1 shape( again)?").arg(q), [](World& world, const Captures& c, const Table&) {
    const int wanted = c.value(1).isEmpty() ? 1 : 2;
    world.waitFor([&] {
      int count = 0;
      for (const QJsonObject& sub : world.mc.subscriptions) {
        if (sub.value(QLatin1String("shape")).toObject().value(QLatin1String("type")).toString() == c[0]) count++;
      }
      return count >= wanted;
    }, QStringLiteral("%1 subscription(s) to %2").arg(wanted).arg(c[0]));
  });
  step(QStringLiteral("the (?:shell|desktop) reconnects to the MC"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&world] { return world.mc.connections.size() >= 2 && world.native().client()->isReady(); },
                  QStringLiteral("a second connection"));
  });
});

}  // namespace
