// Thread notifications as this device's settings shape them: the mode chosen in
// Settings → General, the system's permission, what each notification says, and
// the app's badge (features/settings/notifications.feature). The desktop's
// notification service is AlertSteps' fake.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include "Alerts.h"
#include "Harness.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "SettingsRows.h"
#include "Stream.h"
#include "World.h"

namespace {

const QString kProject = QStringLiteral("shop");

struct Notified {
  QStringList raised;
  int runs = 0;
};

Notified& notified(World& world) {
  return world.mc.part<Notified>();
}

SettingsController* settings(World& world) {
  return world.native().controller<SettingsController>();
}

QString idOf(const QString& title) {
  return QStringLiteral("thread-") + title.toLower().replace(QLatin1Char(' '), QLatin1Char('-'));
}

QString keyOf(World& world, const QString& title) {
  return world.mc.environmentId + QLatin1Char(':') + idOf(title);
}

QJsonObject& rowOf(World& world, const QString& title) {
  return world.mc.threads[idOf(title)];
}

void send(World& world, const QString& title) {
  world.mc.sendRow(idOf(title), rowOf(world, title));
  world.sync();
}

// A thread with a run under way.
void start(World& world, const QString& title) {
  const QString at = stream::iso(world.now());
  rowOf(world, title) = {{QStringLiteral("id"), idOf(title)},
                         {QStringLiteral("title"), title},
                         {QStringLiteral("projectId"), kProject},
                         {QStringLiteral("createdAt"), at},
                         {QStringLiteral("updatedAt"), at},
                         {QStringLiteral("latestRunId"), QStringLiteral("run-%1").arg(++notified(world).runs)},
                         {QStringLiteral("latestRunStartedAt"), at},
                         {QStringLiteral("status"), QStringLiteral("running")}};
  send(world, title);
}

// What the MC's row says when the thread's run ends or waits on the user.
void happen(World& world, const QString& title, const QString& event) {
  world.setTime(world.now().addSecs(60));
  const QString at = stream::iso(world.now());
  QJsonObject& row = rowOf(world, title);
  row.insert(QStringLiteral("updatedAt"), at);
  if (event == QLatin1String("finishes")) {
    row.insert(QStringLiteral("status"), QStringLiteral("completed"));
    row.insert(QStringLiteral("latestRunCompletedAt"), at);
  } else if (event == QLatin1String("asks for approval")) {
    row.insert(QStringLiteral("pendingRuntimeRequest"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("command_approval")}});
  } else if (event == QLatin1String("asks a question")) {
    row.insert(QStringLiteral("pendingRuntimeRequest"), QJsonObject{{QStringLiteral("kind"), QStringLiteral("user_input")}});
  } else {
    row.insert(QStringLiteral("status"), QStringLiteral("failed"));
    row.insert(QStringLiteral("latestRunCompletedAt"), at);
    row.insert(QStringLiteral("lastErrorClass"), event == QLatin1String("fails") ? QStringLiteral("provider_error") : QStringLiteral("usage_limit"));
  }
  send(world, title);
}

QVariantList toasts(World& world) {
  return world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
}

QString describe(World& world) {
  const AlertsSeen seen = alertsSeen(world);
  QVariantMap shown;
  for (auto it = seen.shown.begin(); it != seen.shown.end(); ++it) shown.insert(it.key(), it.value());
  return QStringLiteral("toasts %1, system notifications %2, sounds [%3], badge %4, mode %5")
      .arg(show(toasts(world)), show(shown), seen.sounds.join(QLatin1Char(',')))
      .arg(seen.badge)
      .arg(settings(world)->setting(QStringLiteral("notificationMode")).toString());
}

// The window is somewhere else while `title` finishes, with system notifications on.
void notifyInBackground(World& world, const QString& title) {
  if (!world.mc.threads.contains(idOf(title))) start(world, title);
  if (settings(world)->setting(QStringLiteral("notificationMode")) == QLatin1String("off")) {
    chooseRow(world, QStringLiteral("notificationMode"), QStringLiteral("Notifications only"));
  }
  setAlertFocus(world, false);
  happen(world, title, QStringLiteral("finishes"));
  expect(alertsSeen(world).shown.contains(keyOf(world, title)), describe(world));
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user has a thread %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.projects.insert(kProject, {{QStringLiteral("id"), kProject}, {QStringLiteral("title"), kProject},
                                         {QStringLiteral("workspaceRoot"), QStringLiteral("/work/shop")}, {QStringLiteral("scripts"), QJsonArray()}});
    world.connect();
    world.sync();
    alertsSeen(world);
    start(world, c[0]);
  });

  // The mode, as Settings → General's list sets it.
  step(QStringLiteral("the notification mode is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    if (c[0] == QLatin1String("Off")) {
      expect(settings(world)->setting(QStringLiteral("notificationMode")) == QLatin1String("off"), describe(world));
      // Still following the thread, so only the mode keeps it quiet.
      return turnRow(world, QStringLiteral("inAppNotificationsEnabled"), true);
    }
    chooseRow(world, QStringLiteral("notificationMode"), c[0]);
  });
  step(QStringLiteral("HAL-C2 is in the background"), [](World& world, const Captures&, const Table&) { setAlertFocus(world, false); });
  step(QStringLiteral("%1 (finishes|fails|asks for approval|asks a question|hits its usage limit)").arg(q), [](World& world, const Captures& c, const Table&) {
    // An archived thread's scenario says nothing of how the user is told: every way is on, in the background.
    if (rowOf(world, c[0]).contains(QLatin1String("archivedAt"))) {
      turnRow(world, QStringLiteral("inAppNotificationsEnabled"), true);
      chooseRow(world, QStringLiteral("notificationMode"), QStringLiteral("Notifications with sound"));
      setAlertFocus(world, false);
    }
    happen(world, c[0], c[1]);
  });
  step(QStringLiteral("nothing is shown or played"), [](World& world, const Captures&, const Table&) {
    const AlertsSeen seen = alertsSeen(world);
    expect(seen.shown.isEmpty() && seen.sounds.isEmpty() && toasts(world).isEmpty(), describe(world));
  });
  step(QStringLiteral("a system notification %1 is shown").arg(q), [](World& world, const Captures& c, const Table&) {
    const AlertsSeen seen = alertsSeen(world);
    expect(seen.shown.size() == 1 && seen.shown.first().value(0) == c[0] && seen.sounds.isEmpty(), describe(world));
  });
  step(QStringLiteral("the completion sound plays"), [](World& world, const Captures&, const Table&) {
    const AlertsSeen seen = alertsSeen(world);
    expect(seen.sounds == QStringList{QStringLiteral("completion")} && seen.shown.isEmpty(), describe(world));
  });
  step(QStringLiteral("a system notification is shown and the sound plays"), [](World& world, const Captures&, const Table&) {
    const AlertsSeen seen = alertsSeen(world);
    expect(seen.shown.size() == 1 && seen.sounds == QStringList{QStringLiteral("completion")}, describe(world));
  });

  // The system's permission.
  step(QStringLiteral("the system has not allowed notifications"), [](World& world, const Captures&, const Table&) { setAlertsAllowed(world, false); });
  step(QStringLiteral("the user chooses notifications only and the system refuses"), [](World& world, const Captures&, const Table&) {
    expect(settings(world)->setting(QStringLiteral("notificationMode")) == QLatin1String("off"), describe(world));
    // Picked in the list, as chooseRow does, but the setting does not stay.
    QMetaObject::invokeMethod(pageItem(world, QStringLiteral("settingsRow:notificationMode"), QStringLiteral("control")), "activated", Q_ARG(int, 1));
    world.sync();
  });
  step(QStringLiteral("the notification mode is unchanged"), [](World& world, const Captures&, const Table&) {
    expect(settings(world)->setting(QStringLiteral("notificationMode")) == QLatin1String("off") &&
               rowText(world, QStringLiteral("notificationMode")) == QLatin1String("Off"),
           QStringLiteral("the row reads \"%1\"; %2").arg(rowText(world, QStringLiteral("notificationMode")), describe(world)));
  });
  step(QStringLiteral("the user is told to allow notifications and that sound only is still available"), [](World& world, const Captures&, const Table&) {
    const QVariantList shown = toasts(world);
    expect(std::any_of(shown.cbegin(), shown.cend(), [](const QVariant& toast) {
             const QString text = at(toast, QStringLiteral("description")).toString();
             return text.startsWith(QLatin1String("Allow notifications")) && text.endsWith(QLatin1String("Sound only is still available."));
           }),
           describe(world));
  });

  // What a notification says, and clicking it.
  step(QStringLiteral("a system notification titled %1 names %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList shown = alertsSeen(world).shown.value(keyOf(world, c[1]));
    expect(shown == QStringList{c[0], c[1]}, describe(world));
  });
  step(QStringLiteral("a system notification for %1 is shown").arg(q), [](World& world, const Captures& c, const Table&) {
    notifyInBackground(world, c[0]);
    expect(world.native().controller<NavigationController>()->threadKey() != keyOf(world, c[0]), QStringLiteral("the thread is already shown"));
  });
  step(QStringLiteral("the user clicks it"), [](World& world, const Captures&, const Table&) {
    const QString key = alertsSeen(world).shown.firstKey();
    expect(clickNotification(world, key, &notified(world).raised), QStringLiteral("the click opened nothing"));
    world.sync();
  });
  step(QStringLiteral("HAL-C2 comes to the front showing %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString shown = world.native().controller<NavigationController>()->threadKey();
    expect(shown == keyOf(world, c[0]) && notified(world).raised.size() == 1,
           QStringLiteral("the window shows \"%1\"; raised: %2").arg(shown, notified(world).raised.join(QStringLiteral(", "))));
  });

  // In front.
  step(QStringLiteral("in-app notifications are on"), [](World& world, const Captures&, const Table&) {
    turnRow(world, QStringLiteral("inAppNotificationsEnabled"), true);
    // System notifications too, so only being in front keeps them away.
    chooseRow(world, QStringLiteral("notificationMode"), QStringLiteral("Notifications only"));
  });
  step(QStringLiteral("HAL-C2 is in front showing another thread"), [](World& world, const Captures&, const Table&) {
    start(world, QStringLiteral("Other work"));
    world.native().controller<NavigationController>()->open(NavigationController::Route::thread(keyOf(world, QStringLiteral("Other work"))));
    setAlertFocus(world, true);
  });
  step(QStringLiteral("HAL-C2 is in front showing %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.native().controller<NavigationController>()->open(NavigationController::Route::thread(keyOf(world, c[0])));
    setAlertFocus(world, true);
  });
  step(QStringLiteral("a toast says the thread completed and offers to open it"), [](World& world, const Captures&, const Table&) {
    const QVariantList shown = toasts(world);
    expect(shown.size() == 1 && at(shown.first(), QStringLiteral("title")) == QLatin1String("Thread completed") &&
               at(shown.first(), QStringLiteral("description")) == QLatin1String("Fix login") &&
               at(shown.first(), QStringLiteral("actions")).toList().value(0).toMap().value(QStringLiteral("label")) == QLatin1String("Open thread"),
           describe(world));
  });
  step(QStringLiteral("no toast or notification is shown"), [](World& world, const Captures&, const Table&) {
    expect(toasts(world).isEmpty() && alertsSeen(world).shown.isEmpty(), describe(world));
  });

  // Archived threads ("is archived" is ArchivedThreadsSteps').
  step(QStringLiteral("no notification is shown"), [](World& world, const Captures&, const Table&) {
    const AlertsSeen seen = alertsSeen(world);
    expect(seen.shown.isEmpty() && seen.sounds.isEmpty() && toasts(world).isEmpty(), describe(world));
    // A subagent's thread is as quiet, where another thread's finish is told.
    start(world, QStringLiteral("Helper"));
    rowOf(world, QStringLiteral("Helper")).insert(QStringLiteral("lineage"), QJsonObject{{QStringLiteral("parentThreadId"), idOf(QStringLiteral("Fix login"))},
                                                                                              {QStringLiteral("relationshipToParent"), QStringLiteral("subagent")}});
    send(world, QStringLiteral("Helper"));
    happen(world, QStringLiteral("Helper"), QStringLiteral("finishes"));
    expect(alertsSeen(world).shown.isEmpty(), describe(world));
    start(world, QStringLiteral("Other work"));
    happen(world, QStringLiteral("Other work"), QStringLiteral("finishes"));
    expect(alertsSeen(world).shown.keys() == QStringList{keyOf(world, QStringLiteral("Other work"))}, describe(world));
  });

  // The badge.
  step(QStringLiteral("two system notifications are waiting"), [](World& world, const Captures&, const Table&) {
    notifyInBackground(world, QStringLiteral("Fix login"));
    notifyInBackground(world, QStringLiteral("Other work"));
    expect(alertsSeen(world).shown.size() == 2, describe(world));
  });
  step(QStringLiteral("the app shows a badge of (\\d+)"), [](World& world, const Captures& c, const Table&) {
    expect(alertsSeen(world).badge == c[0].toInt(), describe(world));
  });
  step(QStringLiteral("the user brings HAL-C2 to the front"), [](World& world, const Captures&, const Table&) { setAlertFocus(world, true); });
  step(QStringLiteral("the notifications are dismissed and the badge is cleared"), [](World& world, const Captures&, const Table&) {
    const AlertsSeen seen = alertsSeen(world);
    expect(seen.shown.isEmpty() && seen.closed.size() == 2 && seen.badge == 0, describe(world));
  });
});

}  // namespace
