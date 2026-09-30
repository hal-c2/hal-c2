// Alerts when a thread needs the user (AlertController,
// features/timeline/notifications.feature): threads whose rows the node
// changes, the window's focus, and a fake of the desktop's notification
// service and sound in place of NativeNotifications.

#include <QJsonArray>
#include <QMap>
#include <QVariantList>

#include "AlertController.h"
#include "CommandPaletteController.h"
#include "Harness.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "Stream.h"
#include "World.h"

namespace {

using stream::iso;

// A thread the steps drive, and where its rows come from.
struct Tracked {
  QString environment;  // empty: the node's own
  QString peer;         // another node of the cluster that serves it
  QString id;
  QJsonObject row;
  int runs = 0;
};

struct FakeAlerts {
  bool focused = true;
  bool allowed = true;
  bool enabled = false;
  // The system notifications on screen, by thread key: {title, body}.
  QMap<QString, QStringList> shown;
  // Every one shown, and the keys of those no longer on screen but still clickable.
  QStringList delivered;
  QStringList closed;
  QStringList sounds;
  QMap<QString, Tracked> threads;  // by title
  QString current;                 // the title the last steps were about
  QString lastToast;               // the title of the last in-app alert
  QStringList raised;              // the ids of the windows brought to the front
  QString firstShown;              // what the first window showed before a click
};

FakeAlerts& fake(World& world) {
  return world.node.part<FakeAlerts>();
}

AlertController& alerts(World& world) {
  FakeAlerts& state = fake(world);
  auto* controller = world.native().controller<AlertController>();
  // Set on every step: a restarted shell has a new controller.
  controller->setPresenter({
        [&state](const QString& key, const QString& title, const QString& body, bool) {
          if (!state.enabled || !state.allowed) return false;
          state.shown.insert(key, {title, body});
          state.delivered.append(key);
          return true;
        },
        [&state] {
          state.closed += state.shown.keys();
          state.shown.clear();
        },
        [&state](bool enabled) {
          state.enabled = enabled;
          if (enabled) return;
          state.closed += state.shown.keys();
          state.shown.clear();
        },
        [&state](const QString& kind) { state.sounds.append(kind); },
  });
  controller->setFocused(state.focused);
  return *controller;
}

QString keyOf(World& world, const Tracked& thread) {
  const QString environment = !thread.environment.isEmpty() ? thread.environment
                              : !thread.peer.isEmpty()      ? QStringLiteral("env-b")
                                                            : world.node.environmentId;
  return environment + QLatin1Char(':') + thread.id;
}

void send(World& world, const Tracked& thread) {
  if (!thread.environment.isEmpty()) {
    world.node.sendLinkRow(thread.environment, thread.id, thread.row);
  } else if (!thread.peer.isEmpty()) {
    world.node.sendRows(thread.peer, QJsonArray{QJsonValue(QJsonArray{thread.id, QStringLiteral("thread"), thread.row})});
  } else {
    world.node.threads.insert(thread.id, thread.row);
    world.node.sendRow(thread.id, thread.row);
  }
  world.sync();
  alerts(world);
}

Tracked& tracked(World& world, const QString& title) {
  FakeAlerts& state = fake(world);
  if (!state.threads.contains(title)) fail(QStringLiteral("no thread \"%1\" was started").arg(title));
  state.current = title;
  return state.threads[title];
}

// A thread with a run under way, in the Background's project.
Tracked& working(World& world, const QString& title, const QString& environment = {}, const QString& peer = {}) {
  alerts(world);
  FakeAlerts& state = fake(world);
  Tracked& thread = state.threads[title];
  thread.environment = environment;
  thread.peer = peer;
  thread.id = QStringLiteral("thread-") + title.toLower().replace(QLatin1Char(' '), QLatin1Char('-'));
  thread.runs += 1;
  const QString started = iso(world.now());
  thread.row = {{QStringLiteral("id"), thread.id},
                {QStringLiteral("title"), title},
                {QStringLiteral("projectId"), world.node.projects.firstKey()},
                {QStringLiteral("createdAt"), started},
                {QStringLiteral("updatedAt"), started},
                {QStringLiteral("latestRunId"), QStringLiteral("run-%1").arg(thread.runs)},
                {QStringLiteral("latestRunStartedAt"), started},
                {QStringLiteral("status"), QStringLiteral("running")}};
  state.current = title;
  send(world, thread);
  return thread;
}

void change(World& world, Tracked& thread, const QString& what) {
  world.setTime(world.now().addSecs(60));
  const QString at = iso(world.now());
  QJsonObject& row = thread.row;
  row.insert(QStringLiteral("updatedAt"), at);
  row.remove(QStringLiteral("pendingRuntimeRequest"));
  if (what == QLatin1String("completes")) {
    row.insert(QStringLiteral("status"), QStringLiteral("completed"));
    row.insert(QStringLiteral("latestRunCompletedAt"), at);
  } else if (what == QLatin1String("asks for approval")) {
    row.insert(QStringLiteral("pendingRuntimeRequest"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("command_approval")}});
  } else if (what == QLatin1String("asks the user a question")) {
    row.insert(QStringLiteral("pendingRuntimeRequest"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("user_input")}});
  } else if (what == QLatin1String("fails") || what == QLatin1String("stops at the provider's usage limit")) {
    row.insert(QStringLiteral("status"), QStringLiteral("failed"));
    row.insert(QStringLiteral("latestRunCompletedAt"), at);
    row.insert(QStringLiteral("lastErrorClass"),
               what == QLatin1String("fails") ? QStringLiteral("provider_error") : QStringLiteral("usage_limit"));
  } else {
    fail(QStringLiteral("no change \"%1\"").arg(what));
  }
  send(world, thread);
}

QVariantList toasts(World& world) {
  return world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
}

// The in-app alert about `title`, if one is shown.
std::optional<QVariantMap> toastFor(World& world, const QString& title) {
  for (const QVariant& item : toasts(world)) {
    const QVariantMap toast = item.toMap();
    if (toast.value(QStringLiteral("description")).toString() == title) return toast;
  }
  return std::nullopt;
}

QString describe(World& world) {
  const FakeAlerts& state = fake(world);
  QVariantMap shown;
  for (auto it = state.shown.begin(); it != state.shown.end(); ++it) shown.insert(it.key(), it.value());
  return QStringLiteral("toasts %1, system notifications %2, sounds %3")
      .arg(show(toasts(world)), show(shown), state.sounds.join(QLatin1Char(',')));
}

void setMode(World& world, const QString& mode) {
  world.native().controller<SettingsController>()->set(QStringLiteral("notificationMode"), mode);
  alerts(world);
}

const QMap<QString, QString>& modes() {
  static const QMap<QString, QString> labels{
      {QStringLiteral("Off"), QStringLiteral("off")},
      {QStringLiteral("Notifications only"), QStringLiteral("notifications")},
      {QStringLiteral("Sound only"), QStringLiteral("sound")},
      {QStringLiteral("Notifications with sound"), QStringLiteral("notifications-and-sound")},
  };
  return labels;
}

// The window is somewhere else while `title` completes.
void completesInBackground(World& world, const QString& title) {
  fake(world).focused = false;
  alerts(world);
  Tracked& thread = working(world, title);
  change(world, thread, QStringLiteral("completes"));
}

// Mutes or unmutes `title` from the palette while it is shown, then leaves
// it for the usage page so its alerts are not the shown thread's.
void toggleMuteFromPalette(World& world, const QString& title, bool mute) {
  const QString key = keyOf(world, tracked(world, title));
  auto* navigation = world.native().controller<NavigationController>();
  navigation->open(NavigationController::Route::thread(key));
  world.sync();
  auto* palette = world.native().controller<CommandPaletteController>();
  palette->show();
  palette->setQuery(QStringLiteral("alerts"));
  world.waitFor([palette] { return !palette->searching(); }, QStringLiteral("the palette to settle"));
  const QString wanted = mute ? QStringLiteral("Mute alerts for this thread") : QStringLiteral("Unmute alerts for this thread");
  int row = -1;
  QStringList titles;
  for (int i = 0; i < palette->count(); ++i) {
    const QString rowTitle = palette->data(palette->index(i), CommandPaletteController::TitleRole).toString();
    titles.append(rowTitle);
    if (palette->idAt(i) == AlertController::kToggleMute && rowTitle == wanted) row = i;
  }
  expect(row >= 0, QStringLiteral("the palette offers no \"%1\": %2").arg(wanted, titles.join(QStringLiteral(", "))));
  palette->run(row);
  world.sync();
  const bool muted = alerts(world).isMuted(key);
  expect(muted == mute, QStringLiteral("%1 is %2").arg(title, muted ? QStringLiteral("muted") : QStringLiteral("not muted")));
  navigation->open(NavigationController::Route::of(QStringLiteral("usage")));
  world.sync();
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user has alerts turned on"), [](World& world, const Captures&, const Table&) {
    auto* settings = world.native().controller<SettingsController>();
    settings->set(QStringLiteral("inAppNotificationsEnabled"), true);
    settings->set(QStringLiteral("notificationMode"), QStringLiteral("notifications-and-sound"));
    alerts(world);
  });
  step(QStringLiteral("alerts are set to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(modes().contains(c[0]), QStringLiteral("no alert setting \"%1\"").arg(c[0]));
    setMode(world, modes().value(c[0]));
  });
  step(QStringLiteral("the user turns system notifications off"), [](World& world, const Captures&, const Table&) {
    setMode(world, QStringLiteral("off"));
  });
  step(QStringLiteral("the operating system has not allowed notifications"), [](World& world, const Captures&, const Table&) {
    fake(world).allowed = false;
    alerts(world);
  });
  step(QStringLiteral("the user comes back to the window"), [](World& world, const Captures&, const Table&) {
    fake(world).focused = true;
    alerts(world);
  });

  step(QStringLiteral("the thread %1 is working in the background").arg(q), [](World& world, const Captures& c, const Table&) {
    working(world, c[0]);
  });
  step(QStringLiteral("the thread %1 is working in the background on (a linked environment|another node of the cluster)").arg(q),
       [](World& world, const Captures& c, const Table&) {
         if (c[1] == QLatin1String("a linked environment")) {
           world.node.link(QStringLiteral("laptop"));
           world.sync();
           working(world, c[0], QStringLiteral("laptop"));
         } else {
           world.node.join(stream::kPeer, QStringLiteral("env-b"));
           world.sync();
           working(world, c[0], {}, stream::kPeer);
         }
       });
  step(QStringLiteral("the thread (completes|asks for approval|asks the user a question|fails|stops at the provider's usage limit)"),
       [](World& world, const Captures& c, const Table&) { change(world, tracked(world, fake(world).current), c[0]); });
  step(QStringLiteral("%1 (completes|then asks for approval)").arg(q), [](World& world, const Captures& c, const Table&) {
    if (!fake(world).threads.contains(c[0])) working(world, c[0]);
    change(world, tracked(world, c[0]), c[1] == QLatin1String("completes") ? c[1] : QStringLiteral("asks for approval"));
  });
  step(QStringLiteral("a background thread completes"), [](World& world, const Captures&, const Table&) {
    completesInBackground(world, QStringLiteral("Tax fix"));
  });
  step(QStringLiteral("%1 completed while the client was closed").arg(q), [](World& world, const Captures& c, const Table&) {
    working(world, c[0]);
    world.restart();
    // Closed: the node's row changes with nobody to tell.
    world.node.drop();
    Tracked& thread = tracked(world, c[0]);
    thread.row.insert(QStringLiteral("status"), QStringLiteral("completed"));
    thread.row.insert(QStringLiteral("latestRunCompletedAt"), iso(world.now().addSecs(60)));
    world.node.threads.insert(thread.id, thread.row);
  });
  step(QStringLiteral("the user opens the client"), [](World& world, const Captures&, const Table&) {
    alerts(world);
    world.connect();
    world.sync();
  });
  step(QStringLiteral("the user is looking at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    Tracked& thread = fake(world).threads.contains(c[0]) ? tracked(world, c[0]) : working(world, c[0]);
    world.native().controller<NavigationController>()->open(NavigationController::Route::thread(keyOf(world, thread)));
  });

  // In-app alerts.
  step(QStringLiteral("an in-app alert says %1 (needs approval|completed)").arg(q), [](World& world, const Captures& c, const Table&) {
    Tracked& thread = working(world, c[0]);
    change(world, thread, c[1] == QLatin1String("completed") ? QStringLiteral("completes") : QStringLiteral("asks for approval"));
    const auto toast = toastFor(world, c[0]);
    expect(toast.has_value(), QStringLiteral("no in-app alert: %1").arg(describe(world)));
    fake(world).lastToast = toast->value(QStringLiteral("id")).toString();
  });
  step(QStringLiteral("the user opens the thread from the alert"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("notification.action"), QVariantMap{{QStringLiteral("id"), fake(world).lastToast}});
  });
  step(QStringLiteral("the user dismisses the alert"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("notification.dismiss"), QVariantMap{{QStringLiteral("id"), fake(world).lastToast}});
  });
  step(QStringLiteral("the alert is gone"), [](World& world, const Captures&, const Table&) {
    const QString id = fake(world).lastToast;
    const QVariantList items = toasts(world);
    expect(std::none_of(items.begin(), items.end(), [&id](const QVariant& item) { return item.toMap().value(QStringLiteral("id")) == id; }),
           QStringLiteral("the alert is still shown: %1").arg(describe(world)));
  });
  step(QStringLiteral("%1 is shown").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = keyOf(world, tracked(world, c[0]));
    const QString shown = world.native().controller<NavigationController>()->threadKey();
    expect(shown == key, QStringLiteral("the window shows \"%1\", not \"%2\"").arg(shown, key));
  });
  step(QStringLiteral("%1 is not opened").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString key = keyOf(world, tracked(world, c[0]));
    expect(world.native().controller<NavigationController>()->threadKey() != key, QStringLiteral("the thread was opened"));
  });

  // What the user is told.
  step(QStringLiteral("the user is alerted %1 for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const FakeAlerts& state = fake(world);
    const auto toast = toastFor(world, c[1]);
    const bool inApp = toast && toast->value(QStringLiteral("title")) == c[0];
    const QStringList system = state.shown.value(keyOf(world, state.threads.value(c[1])));
    expect(inApp || system == QStringList{c[0], c[1]}, QStringLiteral("no alert \"%1\": %2").arg(c[0], describe(world)));
  });
  step(QStringLiteral("no alert is raised for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const FakeAlerts& state = fake(world);
    expect(!toastFor(world, c[0]) && state.delivered.isEmpty() && state.sounds.isEmpty(),
           QStringLiteral("an alert was raised: %1").arg(describe(world)));
  });
  step(QStringLiteral("an alert for %1 is raised").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    const FakeAlerts& state = fake(world);
    const bool system = state.shown.contains(keyOf(world, state.threads.value(c[0])));
    expect(toastFor(world, c[0]) || system, QStringLiteral("no alert was raised: %1").arg(describe(world)));
  });

  // Muting one thread.
  step(QStringLiteral("the user mutes alerts for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    toggleMuteFromPalette(world, c[0], true);
  });
  step(QStringLiteral("the user unmutes %1").arg(q), [](World& world, const Captures& c, const Table&) {
    toggleMuteFromPalette(world, c[0], false);
  });
  step(QStringLiteral("alerts for %1 are muted").arg(q), [](World& world, const Captures& c, const Table&) {
    working(world, c[0]);
    toggleMuteFromPalette(world, c[0], true);
  });
  step(QStringLiteral("%1 finishes its turn").arg(q), [](World& world, const Captures& c, const Table&) {
    change(world, tracked(world, c[0]), QStringLiteral("completes"));
  });
  step(QStringLiteral("alerts for other threads in %1 still arrive").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(world.node.projects.first().value(QLatin1String("title")).toString() == c[0],
           QStringLiteral("the threads are not in \"%1\"").arg(c[0]));
    Tracked& other = working(world, QStringLiteral("Docs pass"));
    change(world, other, QStringLiteral("completes"));
    expect(toastFor(world, QStringLiteral("Docs pass")).has_value(), QStringLiteral("no alert for another thread: %1").arg(describe(world)));
  });
  step(QStringLiteral("no in-app alert is shown for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(!toastFor(world, c[0]), QStringLiteral("an in-app alert was shown: %1").arg(describe(world)));
  });
  step(QStringLiteral("a system notification is (shown|not shown)"), [](World& world, const Captures& c, const Table&) {
    expect(fake(world).shown.isEmpty() == (c[0] == QLatin1String("not shown")),
           QStringLiteral("the user sees %1").arg(describe(world)));
  });
  step(QStringLiteral("no system notification is shown"), [](World& world, const Captures&, const Table&) {
    expect(fake(world).shown.isEmpty(), QStringLiteral("the user sees %1").arg(describe(world)));
  });
  step(QStringLiteral("a sound is (played|not played)"), [](World& world, const Captures& c, const Table&) {
    expect(fake(world).sounds.isEmpty() == (c[0] == QLatin1String("not played")),
           QStringLiteral("the user hears %1").arg(describe(world)));
  });
  step(QStringLiteral("the in-app alert and sound still follow the user's settings"), [](World& world, const Captures&, const Table&) {
    // Away from the window no in-app alert shows; the setting still plays its sound.
    expect(!toastFor(world, QStringLiteral("Tax fix")) && fake(world).sounds == QStringList{QStringLiteral("completion")},
           QStringLiteral("the user gets %1").arg(describe(world)));
  });

  // System notifications.
  step(QStringLiteral("a system notification says %1 completed").arg(q), [](World& world, const Captures& c, const Table&) {
    completesInBackground(world, c[0]);
    expect(fake(world).shown.size() == 1, QStringLiteral("the user sees %1").arg(describe(world)));
  });
  step(QStringLiteral("system notifications were shown for %1 and then for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    completesInBackground(world, c[0]);
    completesInBackground(world, c[1]);
    expect(fake(world).delivered.size() == 2, QStringLiteral("the user sees %1").arg(describe(world)));
  });
  step(QStringLiteral("system notifications are shown for two threads"), [](World& world, const Captures&, const Table&) {
    completesInBackground(world, QStringLiteral("Tax fix"));
    completesInBackground(world, QStringLiteral("Docs"));
    expect(fake(world).shown.size() == 2, QStringLiteral("the user sees %1").arg(describe(world)));
  });
  step(QStringLiteral("the user clicks the older notification"), [](World& world, const Captures&, const Table&) {
    FakeAlerts& state = fake(world);
    for (const auto& window : world.native().windows()) {
      QObject::connect(window->bridge(), &ShellBridge::windowCommandRequested, window.get(),
                       [&state, id = window->id()](const QString& command) {
                         if (command == QLatin1String("raise")) state.raised.append(id);
                       });
    }
    alerts(world).openThread(state.delivered.first());
  });
  step(QStringLiteral("the user last used a second window"), [](World& world, const Captures&, const Table&) {
    world.bridge().dispatch(QStringLiteral("window.new"), QVariantMap{});
    const auto& windows = world.native().windows();
    expect(windows.size() == 2, QStringLiteral("%1 windows are open").arg(windows.size()));
    world.native().setActiveWindow(windows.at(1).get());
    fake(world).firstShown = world.native().main()->controller<NavigationController>()->threadKey();
  });
  step(QStringLiteral("the second window shows %1 and comes to the front").arg(q), [](World& world, const Captures& c, const Table&) {
    const FakeAlerts& state = fake(world);
    NativeWindow* window = world.native().windows().at(1).get();
    const QString shown = window->controller<NavigationController>()->threadKey();
    expect(shown == keyOf(world, state.threads.value(c[0])), QStringLiteral("the second window shows %1").arg(shown));
    expect(state.raised == QStringList{window->id()}, QStringLiteral("raised: %1").arg(state.raised.join(QStringLiteral(", "))));
  });
  step(QStringLiteral("the first window stays where it was"), [](World& world, const Captures&, const Table&) {
    const QString shown = world.native().main()->controller<NavigationController>()->threadKey();
    expect(shown == fake(world).firstShown, QStringLiteral("the first window shows %1").arg(shown));
  });
  step(QStringLiteral("only one system notification is shown for %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const FakeAlerts& state = fake(world);
    expect(state.shown.size() == 1 && state.shown.contains(keyOf(world, state.threads.value(c[0]))),
           QStringLiteral("the user sees %1").arg(describe(world)));
  });
  step(QStringLiteral("it says %1 needs approval").arg(q), [](World& world, const Captures& c, const Table&) {
    const FakeAlerts& state = fake(world);
    expect(state.shown.value(keyOf(world, state.threads.value(c[0]))) == QStringList{QStringLiteral("Approval needed"), c[0]},
           QStringLiteral("the user sees %1").arg(describe(world)));
  });
  step(QStringLiteral("both notifications are closed"), [](World& world, const Captures&, const Table&) {
    const FakeAlerts& state = fake(world);
    expect(state.shown.isEmpty() && state.closed.size() == 2 && !state.enabled,
           QStringLiteral("the user sees %1").arg(describe(world)));
  });
  step(QStringLiteral("clicking a notification that was already on its way opens nothing"), [](World& world, const Captures&, const Table&) {
    const QString before = world.native().controller<NavigationController>()->threadKey();
    expect(!alerts(world).openThread(fake(world).delivered.last()), QStringLiteral("the click was taken"));
    expect(world.native().controller<NavigationController>()->threadKey() == before, QStringLiteral("a thread was opened"));
  });
});

}  // namespace
