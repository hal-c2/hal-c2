// What the desktop's window says when a connection is in trouble
// (features/connections/connection-health.feature): the one notice of a
// dropped connection in the real window (ConnectionNotice, ThreadView), the
// "Some requests are slow" warning (SlowRequestController), and what a thread
// says of the cluster member it runs on while that member is down
// (ComputerNoticeController, ThreadView's threadComputerNotice).

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonObject>
#include <QLocale>
#include <QQuickItem>
#include <QQuickWindow>

#include "Brick.h"
#include "ConnectionHealthController.h"
#include "Harness.h"
#include "McClient.h"
#include "NativeShell.h"
#include "ShellStore.h"
#include "ShellWindows.h"
#include "SlowRequestController.h"
#include "Stream.h"
#include "World.h"

namespace {

using namespace stream;

const QString kSlow = QStringLiteral("Some requests are slow");

// What the scenario holds: the MC's calls it leaves unanswered, and when
// each was asked.
struct Notices {
  QList<FakeMc::Rpc> held;
  QHash<QString, QDateTime> askedAt;  // by method
  // What the scenario's own subscriptions live as long as: past the shell.
  std::unique_ptr<QObject> context = std::make_unique<QObject>();
};

Notices& notices(World& world) {
  return world.mc.part<Notices>();
}

McClient& client(World& world) {
  return *world.native().client();
}

// The desktop's own window, drawn by `shell` (DefaultShell unless the
// scenario said otherwise) from the source tree's bricks.
QQuickWindow* window(World& world,
                     const QByteArray& shell = "import HalC2.Bricks\nDefaultShell { width: 1200; height: 800 }\n") {
  const QDir dir(QDir(world.homeDir()).filePath(QStringLiteral("windows")));
  if (!dir.exists(QStringLiteral("shell.qml"))) {
    QDir().mkpath(dir.path());
    QFile file(dir.filePath(QStringLiteral("shell.qml")));
    expect(file.open(QIODevice::WriteOnly) && file.write(shell) > 0, file.fileName());
    QFile::link(QStringLiteral(HAL_C2_QML_DIR), dir.filePath(QStringLiteral("qml")));
  }
  if (world.shellSubscriptions() == 0) world.connect();
  // The controllers' singletons (Terminals, Settings…), as main.cpp registers
  // them.
  Brick::registerSingletons();
  world.native().registerQmlSingletons();
  ShellRuntime* runtime = world.showWindows().runtime(world.native().main());
  expect(runtime && runtime->window() && runtime->usingUserShell() && runtime->lastError().isEmpty(),
         QStringLiteral("the shell did not load: %1").arg(runtime ? runtime->lastError() : QString()));
  return runtime->window();
}

// The items on screen under `item` that `match` takes.
void collect(QQuickItem* item, const std::function<bool(QQuickItem*)>& match, QList<QQuickItem*>& found) {
  if (!item->isVisible()) return;
  if (match(item)) found.append(item);
  for (QQuickItem* child : item->childItems()) collect(child, match, found);
}

QList<QQuickItem*> shown(QQuickWindow* window, const std::function<bool(QQuickItem*)>& match) {
  QList<QQuickItem*> found;
  collect(window->contentItem(), match, found);
  return found;
}

QList<QQuickItem*> shownNamed(QQuickWindow* window, const QString& name) {
  return shown(window, [&](QQuickItem* item) { return item->objectName() == name; });
}

bool isButton(QQuickItem* item) {
  return item->inherits("QQuickAbstractButton");
}

QStringList texts(QQuickWindow* window) {
  QStringList found;
  for (QQuickItem* item :
       shown(window, [](QQuickItem* item) { return !item->property("text").toString().isEmpty(); })) {
    found.append(item->property("text").toString());
  }
  return found;
}

QRectF rect(QQuickItem* item) {
  return {item->mapToScene(QPointF()), QSizeF(item->width(), item->height())};
}

QVariantMap connection(World& world) {
  return world.state(QStringLiteral("connection")).toMap();
}

// From here on the MC takes no connection: a drop stays a drop, and the
// client is slow to try again.
void staysAway(World& world) {
  client(world).setRetryDelays({600000});
  world.mc.stopAccepting();
}

// The window's notice, once the drop is past its grace and it shows.
QQuickItem* reconnectingNotice(World& world, QQuickWindow* shell) {
  world.waitFor(
      [&] {
        return connection(world).value(QStringLiteral("state")) == QLatin1String("retrying") &&
               !shownNamed(shell, QStringLiteral("connectionNotice")).isEmpty();
      },
      [&] { return QStringLiteral("the notice of a reconnect; the connection is %1").arg(show(connection(world))); });
  const QList<QQuickItem*> found = shownNamed(shell, QStringLiteral("connectionNotice"));
  expect(found.size() == 1, QStringLiteral("%1 connection notices are shown").arg(found.size()));
  return found.first();
}

// Slow requests.

// The MC leaves `method` unanswered from here on, and the client asks it.
void ask(World& world, const QString& method) {
  world.mc.onRpc(method, [&world](const FakeMc::Rpc& rpc) { notices(world).held.append(rpc); });
  notices(world).askedAt.insert(method, world.now());
  client(world).call(&client(world), world.mc.environmentId, method, QJsonObject{},
                     [](const QJsonValue&, const std::optional<QString>&) {});
  world.waitFor(
      [&] {
        return std::any_of(notices(world).held.cbegin(), notices(world).held.cend(),
                           [&](const FakeMc::Rpc& rpc) { return rpc.method == method; });
      },
      QStringLiteral("the MC to be asked %1").arg(method));
}

void pass(World& world, qint64 seconds) {
  world.setTime(world.now().addSecs(seconds));
}

std::optional<QVariantMap> slowWarning(World& world) {
  for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
    if (item.toMap().value(QStringLiteral("title")) == kSlow) return item.toMap();
  }
  return std::nullopt;
}

QString describeToasts(World& world) {
  QStringList slow;
  for (const SlowRequests::Request& request : world.native().controller<SlowRequestController>()->requests().slow())
    slow.append(request.method);
  return QStringLiteral("the toasts are %1; the slow requests are %2")
      .arg(show(world.state(QStringLiteral("toasts"))), slow.join(QStringLiteral(", ")));
}

QVariantMap waitForWarning(World& world) {
  world.waitFor([&] { return slowWarning(world).has_value(); }, [&] { return describeToasts(world); });
  return *slowWarning(world);
}

void answer(World& world, int index) {
  Notices& held = notices(world);
  expect(index < held.held.size(), QStringLiteral("only %1 requests wait").arg(held.held.size()));
  world.mc.reply(held.held.at(index), QJsonValue());
}

QString environmentLabel(World& world) {
  const QString label =
      world.native().store()->environment(world.mc.environmentId).value(QLatin1String("label")).toString();
  return label.isEmpty() ? world.mc.environmentId : label;
}

// Computers.

bool showsText(TimelineModel& model, const QString& text) {
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::TextRole).toString() == text) return true;
  }
  return false;
}

// The cluster member `name` (its environment's id and label), with a project
// and a thread the user opens in the window.
void lookAtComputer(World& world, const QString& name) {
  window(world);
  const QString mc = QStringLiteral("mc-") + name;
  const QString project = QStringLiteral("project-") + name;
  const QString thread = QStringLiteral("thread-") + name;
  world.mc.peerLabels.insert(name, name);
  world.mc.join(mc, name);
  world.mc.sendRows(
      mc,
      QJsonArray{
          QJsonValue(QJsonArray{project, QStringLiteral("project"),
                                QJsonObject{{QStringLiteral("id"), project},
                                            {QStringLiteral("title"), name},
                                            {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + name},
                                            {QStringLiteral("scripts"), QJsonArray()}}}),
          QJsonValue(QJsonArray{thread, QStringLiteral("thread"),
                                QJsonObject{{QStringLiteral("id"), thread},
                                            {QStringLiteral("title"), QStringLiteral("On ") + name},
                                            {QStringLiteral("projectId"), project},
                                            {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                                            {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}}})});
  world.mc.part<FakeStreams>().threads[thread].insert(
      QStringLiteral("turn-item\nmessage:") + name,
      QJsonObject{{QStringLiteral("id"), QStringLiteral("message:") + name},
                  {QStringLiteral("type"), QStringLiteral("user_message")},
                  {QStringLiteral("ordinal"), 1},
                  {QStringLiteral("status"), QStringLiteral("completed")},
                  {QStringLiteral("text"), QStringLiteral("Hello from ") + name},
                  {QStringLiteral("updatedAt"), iso(now())}});
  world.sync();
  look(world, name + QLatin1Char(':') + thread);
  world.waitFor([&] { return showsText(timeline(world), QStringLiteral("Hello from ") + name); },
                [&] { return QStringLiteral("the thread of %1 to arrive; %2").arg(name, describe(timeline(world))); });
}

void setOnline(World& world, const QString& name, bool online) {
  world.mc.setOnline(name, online);
  world.waitFor([&] { return world.native().store()->environmentOnline(name) == online; },
                QStringLiteral("%1 to be %2").arg(name, online ? QStringLiteral("online") : QStringLiteral("offline")));
}

QVariantMap machine(World& world, const QString& name) {
  for (const QVariant& value :
       world.state(QStringLiteral("serverUpdates")).toMap().value(QStringLiteral("machines")).toList()) {
    if (value.toMap().value(QStringLiteral("environmentId")) == name) return value.toMap();
  }
  return {};
}

// `name` runs `version`, and this app 1.4.0; `selfUpdate` is how it updates
// itself, none to leave it to its user.
void runs(World& world, const QString& name, const QString& version, const QString& selfUpdate = {}) {
  QJsonObject capabilities{{QStringLiteral("desktopAppUpdate"), true}};
  if (!selfUpdate.isEmpty()) capabilities.insert(QStringLiteral("serverSelfUpdate"), selfUpdate);
  world.mc.descriptorFields.insert(
      name, {{QStringLiteral("serverVersion"), version}, {QStringLiteral("capabilities"), capabilities}});
  world.mc.join(QStringLiteral("mc-") + name, name);
  auto* health = world.native().shared<ConnectionHealthController>();
  expect(health != nullptr, QStringLiteral("the shell has no connection health"));
  health->setClientVersion(QStringLiteral("1.4.0"));
  world.waitFor(
      [&] {
        return machine(world, name).value(QStringLiteral("version")) == version &&
               world.state(QStringLiteral("serverUpdates")).toMap().value(QStringLiteral("appVersion")) ==
                   QLatin1String("1.4.0");
      },
      [&] {
        return QStringLiteral("%1 on %2; serverUpdates is %3")
            .arg(name, version, show(world.state(QStringLiteral("serverUpdates"))));
      });
}

QVariantMap threadComputer(World& world) {
  return world.state(QStringLiteral("threadComputer")).toMap();
}

QString describeThread(World& world, QQuickWindow* shell) {
  return QStringLiteral("threadComputer is %1; the window shows %2")
      .arg(show(world.state(QStringLiteral("threadComputer"))), texts(shell).join(QStringLiteral(" | ")));
}

// The thread's notice about its computer, once it shows `title`.
QQuickItem* computerNotice(World& world, const QString& title) {
  QQuickWindow* shell = window(world);
  world.waitFor(
      [&] {
        const QList<QQuickItem*> found = shownNamed(shell, QStringLiteral("threadComputerTitle"));
        return found.size() == 1 && found.first()->property("text") == title;
      },
      [&] { return QStringLiteral("the thread to say \"%1\"; %2").arg(title, describeThread(world, shell)); });
  return shownNamed(shell, QStringLiteral("threadComputerNotice")).value(0);
}

const Steps steps([] {
  const QString q = kQuoted;

  // A dropped connection, in the real window.
  step(QStringLiteral("the user is reading a thread"), [](World& world, const Captures&, const Table&) {
    window(world);
    world.mc.projects.insert(kProject, {{QStringLiteral("id"), kProject},
                                        {QStringLiteral("title"), kProject},
                                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/") + kProject},
                                        {QStringLiteral("scripts"), QJsonArray()}});
    world.mc.sendRow(kProject, world.mc.projects.value(kProject), QStringLiteral("project"));
    lookAtThread(world, kProject);
    staysAway(world);
  });
  step(QStringLiteral("the user's shell fills its window with the built-in layout"),
       [](World& world, const Captures&, const Table&) {
         // As DefaultLayout's own comment tells a user to.
         window(world,
                "import QtQuick\nimport HalC2.Bricks\n"
                "ShellWindow { id: root; width: 1200; height: 800; "
                "DefaultLayout { anchors.fill: parent; window: root } }\n");
         staysAway(world);
       });
  step(QStringLiteral("one notice says the environment is being reconnected(, "
                      "with one Try again)?"),
       [](World& world, const Captures& c, const Table&) {
         QQuickWindow* shell = window(world);
         QQuickItem* notice = reconnectingNotice(world, shell);
         if (c[0].isEmpty()) return;
         // Its panel, as a click on its icon opens it.
         notice->setProperty("open", true);
         world.waitFor([&] { return !shownNamed(shell, QStringLiteral("connectionRetry")).isEmpty(); },
                       [&] {
                         return QStringLiteral("the notice to offer Try again; the window shows %1")
                             .arg(texts(shell).join(QStringLiteral(" | ")));
                       });
         const QList<QQuickItem*> retries = shown(shell, [](QQuickItem* item) {
           return isButton(item) && (item->property("text") == QLatin1String("Try again") ||
                                     item->objectName() == QLatin1String("threadRetry"));
         });
         expect(retries.size() == 1, QStringLiteral("%1 ways to retry are shown").arg(retries.size()));
       });
  step(QStringLiteral("the thread does not say its MC cannot be reached"),
       [](World& world, const Captures&, const Table&) {
         QQuickWindow* shell = window(world);
         world.sync();
         expect(shownNamed(shell, QStringLiteral("threadProblem")).isEmpty(),
                QStringLiteral("the thread says its MC cannot be reached; the window shows %1")
                    .arg(texts(shell).join(QStringLiteral(" | "))));
       });
  step(QStringLiteral("the notice covers neither the window controls, the "
                      "header nor the thread"),
       [](World& world, const Captures&, const Table&) {
         QQuickWindow* shell = window(world);
         QQuickItem* notice = reconnectingNotice(world, shell);
         // Its icon and the panel opened from it alike.
         for (const bool open : {false, true}) {
           notice->setProperty("open", open);
           world.waitFor([&] { return (notice->height() > 40) == open; },
                         QStringLiteral("the notice's panel to be %1").arg(open ? "open" : "closed"));
           for (const QString& name :
                {QStringLiteral("workspace"), QStringLiteral("routeView"), QStringLiteral("threadSidebar")}) {
             const QList<QQuickItem*> others = shownNamed(shell, name);
             expect(!others.isEmpty(), QStringLiteral("the window has no %1").arg(name));
             expect(!rect(notice).intersects(rect(others.first())),
                    QStringLiteral("the %1 notice lies over %2").arg(open ? "open" : "closed", name));
           }
         }
       });

  // Slow requests.
  step(QStringLiteral("the client is connected to the MC"), [](World& world, const Captures&, const Table&) {
    if (world.shellSubscriptions() == 0) world.connect();
    world.waitFor([&] { return client(world).isReady(); }, QStringLiteral("the client to connect"));
    // The client's own startup calls are answered before the clock moves.
    world.waitFor([&] { return world.native().controller<SlowRequestController>()->requests().tracking() == 0; },
                  QStringLiteral("the client's startup calls to be answered"));
  });
  step(QStringLiteral("a request to the MC is not answered for 15 seconds"), [](World& world, const Captures&,
                                                                                const Table&) {
    ask(world, QStringLiteral("projects.searchEntries"));
    pass(world, 15);
    world.waitFor([&] { return slowWarning(world).has_value(); }, [&] { return describeToasts(world); });
    expect(world.native().controller<SlowRequestController>()->requests().slow().size() == 1, describeToasts(world));
  });
  step(QStringLiteral("two requests to the MC have not been answered for 15 seconds"),
       [](World& world, const Captures&, const Table&) {
         ask(world, QStringLiteral("projects.searchEntries"));
         ask(world, QStringLiteral("git.listBranches"));
         pass(world, 15);
         waitForWarning(world);
       });
  step(QStringLiteral("(\\d+) minutes? pass(?:es)?"),
       [](World& world, const Captures& c, const Table&) { pass(world, c[0].toLongLong() * 60); });
  step(QStringLiteral("(\\d+) minutes? and (\\d+) seconds? pass"),
       [](World& world, const Captures& c, const Table&) { pass(world, c[0].toLongLong() * 60 + c[1].toLongLong()); });
  step(QStringLiteral("(\\d+) more seconds? pass(?:es)?"),
       [](World& world, const Captures& c, const Table&) { pass(world, c[0].toLongLong()); });
  step(QStringLiteral("the warning is still shown until the request is answered"),
       [](World& world, const Captures&, const Table&) {
         world.sync();
         const std::optional<QVariantMap> warning = slowWarning(world);
         expect(warning && warning->value(QStringLiteral("description")) ==
                               QLatin1String("1 request waiting longer than 15s."),
                describeToasts(world));
         answer(world, 0);
         world.waitFor([&] { return !slowWarning(world).has_value(); }, [&] { return describeToasts(world); });
       });
  step(QStringLiteral("the user shows the requests in the warning"), [](World& world, const Captures&, const Table&) {
    const QVariantMap warning = waitForWarning(world);
    for (const QVariant& action : warning.value(QStringLiteral("actions")).toList()) {
      if (action.toMap().value(QStringLiteral("label")) != QLatin1String("Show requests")) continue;
      world.bridge().dispatch(QStringLiteral("notification.action"),
                              QVariantMap{{QStringLiteral("id"), warning.value(QStringLiteral("id"))},
                                          {QStringLiteral("actionId"), action.toMap().value(QStringLiteral("id"))}});
      return;
    }
    fail(QStringLiteral("the warning offers no Show requests: %1").arg(show(warning)));
  });
  step(QStringLiteral("the warning lists each request by its method and environment"), [](World& world, const Captures&,
                                                                                          const Table&) {
    world.waitFor(
        [&] { return slowWarning(world) && slowWarning(world)->value(QStringLiteral("rows")).toList().size() == 2; },
        [&] { return describeToasts(world); });
    QStringList methods;
    for (const QVariant& row : slowWarning(world)->value(QStringLiteral("rows")).toList()) {
      methods.append(row.toMap().value(QStringLiteral("label")).toString());
      expect(row.toMap()
                 .value(QStringLiteral("text"))
                 .toString()
                 .startsWith(environmentLabel(world) + QStringLiteral(" · ")),
             QStringLiteral("the row %1 does not name %2").arg(show(row), environmentLabel(world)));
    }
    methods.sort();
    expect(methods == QStringList{QStringLiteral("git.listBranches"), QStringLiteral("projects.searchEntries")},
           describeToasts(world));
  });
  step(QStringLiteral("says when each request started"), [](World& world, const Captures&, const Table&) {
    for (const QVariant& value : slowWarning(world)->value(QStringLiteral("rows")).toList()) {
      const QVariantMap row = value.toMap();
      const QDateTime started =
          notices(world).askedAt.value(row.value(QStringLiteral("label")).toString()).toLocalTime();
      const QString when = QStringLiteral("Started ") + QLocale().toString(started.time(), QLocale::ShortFormat);
      expect(row.value(QStringLiteral("text")).toString().endsWith(when),
             QStringLiteral("the row %1 does not say \"%2\"").arg(show(row), when));
    }
  });
  step(QStringLiteral("one of them is answered"),
       [](World& world, const Captures&, const Table&) { answer(world, 0); });
  step(QStringLiteral("the other is answered"), [](World& world, const Captures&, const Table&) { answer(world, 1); });
  step(QStringLiteral("the warning says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor(
        [&] { return slowWarning(world) && slowWarning(world)->value(QStringLiteral("description")) == c[0]; },
        [&] { return describeToasts(world); });
  });
  step(QStringLiteral("the warning is gone"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !slowWarning(world).has_value(); }, [&] { return describeToasts(world); });
  });
  step(QStringLiteral("the user updates a provider"), [](World& world, const Captures&, const Table&) {
    // What Providers settings' Update asks; it installs before it answers.
    ask(world, QStringLiteral("server.updateProvider"));
  });
  step(QStringLiteral("the user sees no warning"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!slowWarning(world).has_value(), describeToasts(world));
  });
  step(QStringLiteral("a pull request lookup is not answered for (\\d+) minutes"),
       [](World& world, const Captures& c, const Table&) {
         ask(world, QStringLiteral("pullRequests.detail"));
         pass(world, c[0].toLongLong() * 60);
       });
  step(QStringLiteral("a live subscription is not answered for (\\d+) minutes"),
       [](World& world, const Captures& c, const Table&) {
         // A shape the MC never answers.
         client(world).subscribe(notices(world).context.get(),
                                 QJsonObject{{QStringLiteral("type"), QStringLiteral("pending")}},
                                 [](const QJsonObject&) {});
         world.sync();
         pass(world, c[0].toLongLong() * 60);
       });

  // The computer a thread runs on.
  step(QStringLiteral("the user is looking at a thread on %1").arg(q),
       [](World& world, const Captures& c, const Table&) { lookAtComputer(world, c[0]); });
  step(QStringLiteral("%1 drops and reconnects within two seconds").arg(q),
       [](World& world, const Captures& c, const Table&) {
         setOnline(world, c[0], false);
         pass(world, 1);
         setOnline(world, c[0], true);
         // Past when a notice would have shown.
         pass(world, 5);
       });
  step(QStringLiteral("the thread shows no notice about %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickWindow* shell = window(world);
    world.sync();
    expect(world.state(QStringLiteral("threadComputer")).isNull() &&
               shownNamed(shell, QStringLiteral("threadComputerNotice")).isEmpty() &&
               shownNamed(shell, QStringLiteral("threadProblem")).isEmpty() &&
               !texts(shell).join(u'\n').contains(c[0] + QStringLiteral(" is ")),
           describeThread(world, shell));
  });
  step(QStringLiteral("%1 has been reconnecting for more than two seconds").arg(q),
       [](World& world, const Captures& c, const Table&) {
         setOnline(world, c[0], false);
         QQuickWindow* shell = window(world);
         // Inside the two seconds the thread says nothing.
         pass(world, 1);
         expect(shownNamed(shell, QStringLiteral("threadComputerNotice")).isEmpty() &&
                    shownNamed(shell, QStringLiteral("threadProblem")).isEmpty(),
                QStringLiteral("a second in: %1").arg(describeThread(world, shell)));
         pass(world, 2);
       });
  step(QStringLiteral("the thread says %1").arg(q),
       [](World& world, const Captures& c, const Table&) { computerNotice(world, c[0]); });
  step(QStringLiteral("reconnecting by hand is not offered while it is already trying"),
       [](World& world, const Captures&, const Table&) {
         QQuickWindow* shell = window(world);
         QQuickItem* notice = shownNamed(shell, QStringLiteral("threadComputerNotice")).value(0);
         expect(notice != nullptr, describeThread(world, shell));
         QList<QQuickItem*> buttons;
         collect(notice, isButton, buttons);
         expect(buttons.isEmpty() && shownNamed(shell, QStringLiteral("threadRetry")).isEmpty(),
                QStringLiteral("a reconnect is offered; %1").arg(describeThread(world, shell)));
       });
  step(QStringLiteral("an update of %1 is running").arg(q), [](World& world, const Captures& c, const Table&) {
    runs(world, c[0], QStringLiteral("1.3.0"), QStringLiteral("boot-service"));
    // Its Update in Connections settings; the MC holds the answer until
    // the update is done.
    world.bridge().dispatch(QStringLiteral("serverUpdates.update"),
                            QVariantMap{{QStringLiteral("environmentId"), c[0]}});
    world.waitFor(
        [&] {
          return machine(world, c[0]).value(QStringLiteral("updating")).toBool() &&
                 std::any_of(world.mc.calls.cbegin(), world.mc.calls.cend(), [&](const FakeMc::Rpc& rpc) {
                   return rpc.method == QLatin1String("server.updateServer") && rpc.environment == c[0];
                 });
        },
        [&] {
          return QStringLiteral("the update of %1; serverUpdates is %2")
              .arg(c[0], show(world.state(QStringLiteral("serverUpdates"))));
        });
  });
  step(QStringLiteral("%1 drops and starts reconnecting").arg(q), [](World& world, const Captures& c, const Table&) {
    setOnline(world, c[0], false);
    // Long enough for a reconnect warning to show, were it to.
    pass(world, 5);
  });
  step(QStringLiteral("the thread shows the update's progress"), [](World& world, const Captures&, const Table&) {
    const QString name = machine(world, threadComputer(world).value(QStringLiteral("environmentId")).toString())
                             .value(QStringLiteral("label"))
                             .toString();
    computerNotice(world, QStringLiteral("Updating %1").arg(name.isEmpty() ? QStringLiteral("studio") : name));
  });
  step(QStringLiteral("no notice says %1 is reconnecting").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickWindow* shell = window(world);
    world.sync();
    expect(!texts(shell).join(u'\n').contains(QStringLiteral("%1 is reconnecting").arg(c[0])) &&
               shownNamed(shell, QStringLiteral("threadProblem")).isEmpty() && !slowWarning(world).has_value() &&
               world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList().isEmpty(),
           QStringLiteral("%1; %2").arg(describeThread(world, shell), describeToasts(world)));
  });
  step(QStringLiteral("%1 runs a different version than this client and no "
                      "update is known to be running")
           .arg(q),
       [](World& world, const Captures& c, const Table&) {
         // Newer than this app: the restart of an update made elsewhere.
         runs(world, c[0], QStringLiteral("1.5.0"));
         expect(!machine(world, c[0]).value(QStringLiteral("updating")).toBool(),
                QStringLiteral("an update of %1 is running").arg(c[0]));
       });
  step(QStringLiteral("%1 is reconnecting").arg(q),
       [](World& world, const Captures& c, const Table&) { setOnline(world, c[0], false); });
  step(QStringLiteral("the thread shows one notice %1 with %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         QQuickWindow* shell = window(world);
         computerNotice(world, c[0]);
         const QList<QQuickItem*> details = shownNamed(shell, QStringLiteral("threadComputerDetail"));
         expect(details.size() == 1 && details.first()->property("text") == c[1], describeThread(world, shell));
         expect(shownNamed(shell, QStringLiteral("threadComputerNotice")).size() == 1 &&
                    shownNamed(shell, QStringLiteral("threadProblem")).isEmpty() &&
                    shownNamed(shell, QStringLiteral("connectionNotice")).isEmpty(),
                QStringLiteral("more than one notice: %1").arg(describeThread(world, shell)));
       });
  step(QStringLiteral("no separate notice says the versions differ"), [](World& world, const Captures&, const Table&) {
    QQuickWindow* shell = window(world);
    world.sync();
    const QString all = texts(shell).join(u'\n');
    expect(connection(world).value(QStringLiteral("versionWarning")).isNull() &&
               shownNamed(shell, QStringLiteral("connectionNotice")).isEmpty() &&
               world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList().isEmpty() &&
               !all.contains(QStringLiteral("version"), Qt::CaseInsensitive),
           QStringLiteral("%1; %2").arg(describeThread(world, shell), describeToasts(world)));
  });
});

}  // namespace
