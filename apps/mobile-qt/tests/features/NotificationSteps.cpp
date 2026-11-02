// Alerts and the ongoing activity card (features/mobile/notifications.feature):
// the phone's Settings → Notifications tapped as the user does, the MC's side
// of push as apps/server-ex/lib/hal_c2/push decides it (what it pushes, to
// which endpoint, held for quiet hours or a mute), and what the system shows
// of it (FakePushSystem). A push travels as the real one does: encrypted to
// the phone's keys, and handed over when a step lets the distributor deliver.

#include <QDateTime>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQuickItem>
#include <QTimeZone>

#include "FakeThreads.h"
#include "Harness.h"
#include "Phone.h"
#include "ShellBridge.h"
#include "World.h"
#include "push/PushCrypto.h"
#include "push/PushInbox.h"

namespace {

using S = QString;

constexpr qint64 kMinute = 60 * 1000;

// The MC's side of push.
struct FakePush {
  QJsonObject registration;
  // The last registration the phone made, kept after it unregisters, as an
  // MC that never heard it would.
  QJsonObject lastRegistration;
  int registrations = 0;
  int unregistrations = 0;
  // Every push, in order: where it went and what it said.
  struct Sent {
    QString endpoint;
    QJsonObject message;
    QByteArray body;
  };
  QList<Sent> sent;
  // Alerts waiting for quiet hours to end.
  QList<QJsonObject> held;
  // What the MC's activity rows have of each thread.
  QMap<QString, push::ActivityRow> phases;
  QHash<QString, QString> runs;
  int runCount = 0;
  // The thread "the agent" works in.
  QString current;
  // "the app is in the foreground": agents' events leave it there.
  bool keepForeground = false;
  bool dispatching = false;
  bool providers = false;
  int sentWork = 0;
  // An alert a step is still putting together.
  QJsonObject draft;
  // Where the app was before the user tapped an alert.
  QVariantMap routeBefore;
  QString threadBefore;
};

const FakeMc::Extension pushes([](FakeMc& mc) {
  mc.onRpc(S("hal-c2.registerPush"), [&mc](const FakeMc::Rpc& rpc) {
    FakePush& fake = mc.part<FakePush>();
    fake.registration = rpc.payload;
    fake.lastRegistration = rpc.payload;
    ++fake.registrations;
    mc.reply(rpc, QJsonObject());
  });
  mc.onRpc(S("hal-c2.unregisterPush"), [&mc](const FakeMc::Rpc& rpc) {
    FakePush& fake = mc.part<FakePush>();
    fake.registration = {};
    ++fake.unregistrations;
    mc.reply(rpc, QJsonObject());
  });
});

FakePush& pushOf(World& world) { return world.mc.part<FakePush>(); }

QString iso(qint64 ms) { return QDateTime::fromMSecsSinceEpoch(ms, QTimeZone::UTC).toString(Qt::ISODateWithMs); }

QByteArray fromBase64Url(const QJsonValue& value) {
  return QByteArray::fromBase64(value.toString().toLatin1(), QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals);
}

QString screenTexts(World& world) { return world.texts().join(S(" | ")); }

QVariantMap notifications(World& world) { return world.state(S("notifications")).toMap(); }

// The distributor hands over what reached it, as far as Android lets it.
void flush(World& world) {
  if (world.isOpen()) world.sync();
  world.push->deliver();
}

// The MC pushes `message` to the phone it has registered, if any.
void pushToPhone(World& world, QJsonObject message) {
  FakePush& fake = pushOf(world);
  if (world.isOpen()) world.sync();
  if (fake.registration.isEmpty()) return;
  message.insert(S("v"), 1);
  if (!message.contains(QLatin1String("sentAt"))) message.insert(S("sentAt"), double(world.push->clock));
  if (fake.registration.value(QLatin1String("liveActivity")).toBool() && !message.contains(QLatin1String("activity"))) {
    message.insert(S("activity"), push::activity(fake.phases.values(), world.push->clock));
  }
  const QJsonObject keys = fake.registration.value(QLatin1String("keys")).toObject();
  const QByteArray body = push::encrypt(QJsonDocument(message).toJson(QJsonDocument::Compact), fromBase64Url(keys.value(QLatin1String("p256dh"))),
                                        fromBase64Url(keys.value(QLatin1String("auth"))));
  expect(!body.isEmpty(), S("the push could not be encrypted to the phone's keys %1").arg(show(keys.toVariantMap())));
  const QString endpoint = fake.registration.value(QLatin1String("endpoint")).toString();
  fake.sent.append({endpoint, message, body});
  world.push->inFlight.append({endpoint, body});
}

// The same push again, as a distributor that retries delivers it.
void deliverAgain(World& world) {
  flush(world);
  const FakePush& fake = pushOf(world);
  expect(!fake.sent.isEmpty(), S("the MC has pushed nothing"));
  world.push->inFlight.append({fake.sent.last().endpoint, fake.sent.last().body});
}

// The phone's quiet hours as the MC has them: whether `at` falls in them.
bool quiet(const QJsonObject& registration, qint64 at) {
  const QJsonObject hours = registration.value(QLatin1String("quietHours")).toObject();
  if (hours.isEmpty()) return false;
  const int minute = int((((at / kMinute) + hours.value(QLatin1String("utcOffsetMinutes")).toInt()) % 1440 + 1440) % 1440);
  const int start = hours.value(QLatin1String("start")).toInt();
  const int end = hours.value(QLatin1String("end")).toInt();
  return start < end ? minute >= start && minute < end : minute >= start || minute < end;
}

// What the MC pushes for these alerts (`kind` completed, failed, approval or
// input): one alert, or one for all of them; nothing for a muted thread, and
// held while quiet hours last.
void alert(World& world, QList<QJsonObject> due) {
  FakePush& fake = pushOf(world);
  if (world.isOpen()) world.sync();
  const QJsonArray muted = fake.registration.value(QLatin1String("mutedThreads")).toArray();
  due.removeIf([&](const QJsonObject& one) { return muted.contains(world.mc.environmentId + QLatin1Char(':') + one.value(QLatin1String("threadId")).toString()); });
  if (quiet(fake.registration, world.push->clock)) {
    const bool through = fake.registration.value(QLatin1String("quietHours")).toObject().value(QLatin1String("allowApprovals")).toBool();
    QList<QJsonObject> now;
    for (const QJsonObject& one : std::as_const(due)) {
      if (through && one.value(QLatin1String("kind")) == QLatin1String("approval")) {
        now.append(one);
      } else {
        fake.held.append(one);
      }
    }
    due = now;
  }
  if (due.isEmpty()) return;
  QJsonObject pushed = due.first();
  if (due.size() > 1) {
    QStringList ids;
    QStringList titles;
    for (const QJsonObject& one : std::as_const(due)) {
      ids.append(one.value(QLatin1String("id")).toString());
      titles.append(one.value(QLatin1String("title")).toString());
    }
    pushed.insert(S("id"), S("grouped:") + QString::fromLatin1(ids.join(QLatin1Char('\n')).toUtf8().toBase64()));
    pushed.insert(S("kind"), S("grouped"));
    pushed.insert(S("title"), S("%1 agents finished").arg(due.size()));
    pushed.insert(S("body"), titles.join(QLatin1Char('\n')));
  }
  pushToPhone(world, {{S("alert"), pushed}});
}

// The clock moves on; alerts quiet hours held go once they end.
void advance(World& world, qint64 ms) {
  world.push->clock += ms;
  FakePush& fake = pushOf(world);
  if (fake.held.isEmpty() || quiet(fake.registration, world.push->clock)) return;
  for (const QJsonObject& one : std::exchange(fake.held, {})) pushToPhone(world, {{S("alert"), one}});
}

// The clock moves on to `time` by the phone's own clock, the next one there is.
void advanceTo(World& world, const QString& time) {
  const int offset = pushOf(world).registration.value(QLatin1String("quietHours")).toObject().value(QLatin1String("utcOffsetMinutes")).toInt();
  const QDate day = QDateTime::fromMSecsSinceEpoch(world.push->clock, QTimeZone::UTC).date();
  qint64 at = QDateTime(day.addDays(-1), QTime::fromString(time, S("HH:mm")), QTimeZone::UTC).toMSecsSinceEpoch() - offset * kMinute;
  while (at <= world.push->clock) at += 24 * 60 * kMinute;
  advance(world, at - world.push->clock);
}

QString projectTitle(World& world, const QString& thread) {
  const QString project = world.mc.threads.value(thread).value(QLatin1String("projectId")).toString();
  return world.mc.projects.value(project).value(QLatin1String("title")).toString(project);
}

// A thread's work moves to `phase` (the MC's activity phases) on the MC: its
// row, and the activity it pushes from.
void setPhase(World& world, const QString& thread, const QString& phase) {
  FakePush& fake = pushOf(world);
  // Each change a moment after the last, so pushes about it are told apart by
  // when they were sent.
  world.push->clock += 1000;
  const qint64 now = world.push->clock;
  const QString previous = fake.phases.value(thread).phase;
  const bool finished = phase == QLatin1String("completed") || phase == QLatin1String("failed");
  if (!fake.runs.contains(thread) ||
      (!finished && (previous.isEmpty() || previous == QLatin1String("completed") || previous == QLatin1String("failed")))) {
    fake.runs.insert(thread, S("run-%1").arg(++fake.runCount));
  }
  const QString run = fake.runs.value(thread);
  QJsonObject row{{S("latestRunId"), run}, {S("updatedAt"), iso(now)}, {S("latestRunRequestedAt"), iso(now)}};
  if (finished) {
    row.insert(S("status"), phase);
    row.insert(S("activeRunId"), QJsonValue::Null);
    row.insert(S("latestRunCompletedAt"), iso(now));
    row.insert(S("pendingRuntimeRequest"), QJsonValue::Null);
  } else {
    row.insert(S("status"), S("running"));
    row.insert(S("activeRunId"), run);
    const bool approval = phase == QLatin1String("waiting_for_approval");
    const bool input = phase == QLatin1String("waiting_for_input");
    row.insert(S("pendingRuntimeRequest"), approval ? QJsonValue(QJsonObject{{S("kind"), S("command_approval")}})
                                           : input  ? QJsonValue(QJsonObject{{S("kind"), S("user_input")}})
                                                    : QJsonValue::Null);
  }
  updateRow(world.mc, thread, row);
  fake.phases.insert(thread, {phase, world.mc.threads.value(thread).value(QLatin1String("title")).toString(), projectTitle(world, thread),
                              world.mc.environmentId, thread, now});
}

// The alert the MC owes the user for a thread that reached `kind`.
QJsonObject dueAlert(World& world, const QString& thread, const QString& kind) {
  static const QHash<QString, QString> bodies{{S("completed"), S("Agent finished")},
                                              {S("failed"), S("Agent failed")},
                                              {S("approval"), S("Approval needed")},
                                              {S("input"), S("Question for you")}};
  return {{S("id"), S("%1:%2:%3:%4").arg(world.mc.environmentId, thread, kind, pushOf(world).runs.value(thread))},
          {S("kind"), kind},
          {S("title"), world.mc.threads.value(thread).value(QLatin1String("title")).toString()},
          {S("body"), bodies.value(kind)},
          {S("link"), S("hal-c2://threads/%1/%2").arg(world.mc.environmentId, thread)},
          {S("environmentId"), world.mc.environmentId},
          {S("threadId"), thread}};
}

// An agent in the thread reaches `event`, and the MC pushes what it owes.
void agentEvent(World& world, const QString& thread, const QString& event) {
  static const QHash<QString, std::pair<QString, QString>> events{
      {S("finishes its turn"), {S("completed"), S("completed")}},
      {S("fails"), {S("failed"), S("failed")}},
      {S("needs approval for a command"), {S("waiting_for_approval"), S("approval")}},
      {S("needs approval"), {S("waiting_for_approval"), S("approval")}},
      {S("asks the user a question"), {S("waiting_for_input"), S("input")}},
      {S("needs the user's input"), {S("waiting_for_input"), S("input")}},
  };
  const auto [phase, kind] = events.value(event);
  expect(!phase.isEmpty(), S("no agent event %1").arg(event));
  pushOf(world).current = thread;
  setPhase(world, thread, phase);
  alert(world, {dueAlert(world, thread, kind)});
}

// An event the user is away for: the app goes to the background first,
// unless the scenario keeps it in front.
void awayEvent(World& world, const QString& title, const QString& event) {
  if (!pushOf(world).keepForeground) world.background();
  agentEvent(world, haveThread(world, title), event);
}

// The app on its home screen, whatever it showed.
void goHome(World& world) {
  if (!world.isOpen()) world.open();
  world.foreground();
  const auto home = [&] { return world.state(S("route")).toMap().value(S("kind")) == QLatin1String("home") && world.find(S("homeScreen")) != nullptr; };
  for (int tries = 0; tries < 6 && !home(); ++tries) {
    world.back();
    world.sync();
  }
  world.waitFor(home, [&] { return S("the home screen; the screen says: %1").arg(screenTexts(world)); });
}

// Home's bar, Settings, and its Notifications page.
void openNotificationSettings(World& world) {
  if (world.isOpen() && world.find(S("notificationsSettings")) != nullptr) return;
  goHome(world);
  world.tap(S("settings"));
  world.item(S("settingsSections"));
  QQuickItem* row = nullptr;
  world.waitFor(
      [&] {
        row = world.findWhere([](QQuickItem* candidate) {
          return candidate->objectName().startsWith(QLatin1String("settingsRow")) &&
                 candidate->property("modelData").toMap().value(QStringLiteral("to")).toString() == QLatin1String("/settings/notifications");
        });
        return row != nullptr;
      },
      [&] { return S("Notifications among the settings; the screen says: %1").arg(screenTexts(world)); });
  world.tap(row);
  world.item(S("notificationsSettings"));
}

QString textOf(World& world, const QString& objectName) { return world.item(objectName)->property("text").toString(); }

// The phone allows HAL-C2's notifications and is registered with the MC.
void turnOn(World& world) {
  FakePush& fake = pushOf(world);
  if (world.push->granted == PushSystem::Permission::Granted && !fake.registration.isEmpty()) return;
  if (!world.isOpen()) world.open();
  world.foreground();
  world.push->granted = PushSystem::Permission::Granted;
  world.bridge().dispatch(S("notifications.enable"));
  world.waitFor([&] { return !fake.registration.isEmpty(); },
                [&] { return S("the phone to register with the MC; notifications are %1").arg(show(notifications(world))); });
}

void liveActivityOn(World& world) {
  turnOn(world);
  if (notifications(world).value(S("liveActivity")).toBool()) return;
  world.bridge().dispatch(S("notifications.setLiveActivity"), QVariantMap{{S("on"), true}});
  world.waitFor([&] { return notifications(world).value(S("liveActivity")).toBool(); }, S("live activity updates to be on"));
}

// The app's process ends and a new one starts, as after the system changes
// under it; it comes back on its home screen.
void restart(World& world) {
  world.close();
  world.open();
  threadList(world);
}

// The MC turns a message into a run, as its projection does.
void runOnMessages(World& world) {
  FakePush& fake = pushOf(world);
  if (fake.dispatching) return;
  fake.dispatching = true;
  world.mc.effects.append([&world](const QJsonObject& command) {
    if (command.value(QLatin1String("type")) != QLatin1String("message.dispatch")) return;
    const QString thread = command.value(QLatin1String("threadId")).toString();
    pushOf(world).current = thread;
    setPhase(world, thread, S("running"));
    QMetaObject::invokeMethod(&world.mc, [&world] { pushToPhone(world, {}); }, Qt::QueuedConnection);
  });
}

int dispatches(World& world, const QString& thread) {
  world.sync();
  return int(std::count_if(world.mc.commands.cbegin(), world.mc.commands.cend(), [&](const QJsonObject& command) {
    return command.value(QLatin1String("type")) == QLatin1String("message.dispatch") && command.value(QLatin1String("threadId")) == thread;
  }));
}

// The user opens the thread, types into its composer and sends.
void sendMessage(World& world, const QString& title) {
  FakePush& fake = pushOf(world);
  runOnMessages(world);
  if (!fake.providers) {
    fake.providers = true;
    offerProviders(world.mc, {QJsonObject{{S("instanceId"), S("claudeAgent")},
                                          {S("driver"), S("claudeAgent")},
                                          {S("displayName"), S("Claude")},
                                          {S("enabled"), true},
                                          {S("installed"), true},
                                          {S("status"), S("ready")},
                                          {S("models"), QJsonArray{QJsonObject{{S("slug"), S("claude-sonnet")}, {S("name"), S("Sonnet")}}}}}});
  }
  const QString thread = haveThread(world, title);
  world.thread = thread;
  if (shownThread(world) != title) {
    goHome(world);
    openThread(world, title);
  }
  const int before = dispatches(world, thread);
  QQuickItem* input = world.item(S("input"));
  world.waitFor([&] { return input->isEnabled(); }, S("the composer to take text"));
  world.tap(input);
  world.type(S("Make it so"));
  world.tap(S("primaryAction"));
  world.waitFor([&] { return dispatches(world, thread) > before; }, [&] { return S("the message to reach the MC; the screen says: %1").arg(screenTexts(world)); });
  world.sync();
}

// The card on the lock screen, once what reached the phone is shown; fails
// when it does not come to satisfy `holds`.
QJsonObject awaitCard(World& world, const std::function<bool(const QJsonObject&)>& holds, const QString& what) {
  QJsonObject shown;
  world.waitFor(
      [&] {
        world.push->deliver();
        const auto card = world.push->card();
        if (!card) return false;
        shown = *card;
        return holds(shown);
      },
      [&] {
        const auto card = world.push->card();
        return S("%1; the card is %2").arg(what, card ? show(card->toVariantMap()) : S("not there"));
      });
  return shown;
}

QJsonObject currentCard(World& world) {
  flush(world);
  const auto card = world.push->card();
  expect(card.has_value(), S("no activity card is shown"));
  return *card;
}

bool mentions(const QJsonObject& card, const QString& title) {
  if (card.value(QLatin1String("title")).toString() == title) return true;
  for (const QJsonValue& line : card.value(QLatin1String("lines")).toArray()) {
    if (line.toString().contains(title)) return true;
  }
  return false;
}

QList<QJsonObject> shownAlerts(World& world, const QString& title = {}) {
  flush(world);
  QList<QJsonObject> found;
  for (const FakePushSystem::Posted& posted : std::as_const(world.push->alertsShown)) {
    if (title.isEmpty() || posted.effect.value(QLatin1String("title")) == title) found.append(posted.effect);
  }
  return found;
}

QString describeAlerts(World& world) {
  QStringList shown;
  for (const FakePushSystem::Posted& posted : std::as_const(world.push->alertsShown)) shown.append(show(posted.effect.toVariantMap()));
  return shown.isEmpty() ? S("none") : shown.join(S("; "));
}

void expectNoAlert(World& world) {
  expect(shownAlerts(world).isEmpty(), S("the phone shows %1").arg(describeAlerts(world)));
}

void expectAlertFor(World& world, const QString& title) {
  expect(!shownAlerts(world, title).isEmpty(), S("no alert for %1; the phone shows %2").arg(title, describeAlerts(world)));
}

// The user taps the newest alert, and what it links to opens.
void tapAlert(World& world) {
  flush(world);
  expect(!world.push->alertsShown.isEmpty(), S("no alert to tap"));
  FakePush& fake = pushOf(world);
  if (world.isOpen()) {
    fake.routeBefore = world.state(S("route")).toMap();
    fake.threadBefore = shownThread(world);
  }
  const QString link = world.push->tapAlert(world.push->alertsShown.size() - 1);
  if (link.isEmpty()) return;
  if (world.isOpen()) world.foreground();
  world.followLink(link);
}

// The project `title` beside "shop", on the MC.
QString haveProject(World& world, const QString& title) {
  if (!world.mc.projects.contains(title)) {
    world.mc.projects.insert(title, {{S("id"), title}, {S("title"), title}, {S("workspaceRoot"), S("/work/") + title}, {S("scripts"), QJsonArray()},
                                     {S("createdAt"), S("2026-09-01T09:00:00Z")}, {S("updatedAt"), S("2026-09-01T09:00:00Z")}});
    world.mc.sendRow(title, world.mc.projects.value(title), S("project"));
  }
  return title;
}

struct Covered {
  QString title;
  QString phase;
  QString project = QStringLiteral("shop");
};

// Threads in these phases on the MC, which pushes their activity to a phone
// in the background.
void cover(World& world, const QList<Covered>& threads) {
  liveActivityOn(world);
  pushOf(world).keepForeground = false;
  world.background();
  for (const Covered& covered : threads) {
    const QString thread = haveThread(world, covered.title);
    if (covered.project != QLatin1String("shop")) updateRow(world.mc, thread, {{S("projectId"), haveProject(world, covered.project)}});
    setPhase(world, thread, covered.phase);
    // Newer first: each a moment after the last.
    world.push->clock += 1000;
  }
  pushToPhone(world, {});
  flush(world);
}

QList<Covered> several(int count, const QString& phase, const QString& prefix = QStringLiteral("Agent")) {
  QList<Covered> threads;
  for (int index = 1; index <= count; ++index) threads.append({S("%1 %2").arg(prefix).arg(index), phase});
  return threads;
}

const Steps steps([] {
  // Settings → Notifications.

  step(S("the user turns on device notifications"), [](World& world, const Captures&, const Table&) {
    openNotificationSettings(world);
    QQuickItem* toggle = world.item(S("notificationsDevice"));
    expect(!toggle->property("checked").toBool(), S("device notifications are already on"));
    world.tap(toggle);
  });

  step(S("the user (allows|refuses) notifications when the phone asks"), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.push->asking(); }, S("the system to ask for notification permission"));
    world.push->answer(c[0] == QLatin1String("allows"));
  });

  step(S("the user is told notifications are (enabled|disabled)"), [](World& world, const Captures& c, const Table&) {
    const QString expected = S("Notifications are %1.").arg(c[0]);
    world.waitFor([&] { return textOf(world, S("notificationsStatus")) == expected; },
                  [&] { return S("%1; the screen says: %2").arg(expected, screenTexts(world)); });
    if (c[0] == QLatin1String("enabled")) {
      world.waitFor([&] { return !pushOf(world).registration.isEmpty(); }, S("the phone to register with the MC"));
      expect(world.item(S("notificationsDevice"))->property("checked").toBool(), S("the switch shows notifications off"));
    } else {
      expect(pushOf(world).registration.isEmpty(), S("the phone registered with the MC"));
    }
  });

  step(S("device notifications are on"), [](World& world, const Captures&, const Table&) { turnOn(world); });

  step(S("the user turns off device notifications"), [](World& world, const Captures&, const Table&) {
    openNotificationSettings(world);
    QQuickItem* toggle = world.item(S("notificationsDevice"));
    expect(toggle->property("checked").toBool(), S("device notifications are off"));
    world.tap(toggle);
  });

  step(S("the phone's notification settings for HAL-C2 open"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.push->settingsOpened > 0; }, S("the system's notification settings to open"));
    // Android owns the way back: the switch stays as the system has it.
    expect(world.item(S("notificationsDevice"))->property("checked").toBool(), S("the switch turned off with the system still allowing"));
  });

  step(S("the installed app build cannot receive notifications"), [](World& world, const Captures&, const Table&) {
    world.push->installed = false;
    restart(world);
  });

  step(S("the user opens notification settings"), [](World& world, const Captures&, const Table&) { openNotificationSettings(world); });

  step(S("the user is told to install a newer app build"), [](World& world, const Captures&, const Table&) {
    expect(textOf(world, S("notificationsUnsupported")).contains(QLatin1String("Install a newer build")), S("the screen says: %1").arg(screenTexts(world)));
    expect(world.find(S("notificationsDevice")) == nullptr, S("the screen still offers to turn notifications on"));
  });

  // The user blocks HAL-C2 in the system settings and comes back to the app,
  // which reads it again.
  step(S("the system blocks HAL-C2 notifications"), [](World& world, const Captures&, const Table&) {
    world.push->granted = PushSystem::Permission::Denied;
    if (!world.isOpen()) return;
    world.background();
    world.foreground();
  });

  // Blocked while the app is away, which has not seen it yet.
  step(S("the system has blocked notifications for HAL-C2"), [](World& world, const Captures&, const Table&) {
    world.push->granted = PushSystem::Permission::Denied;
  });

  step(S("the user allows HAL-C2 notifications in the system settings"), [](World& world, const Captures&, const Table&) {
    flush(world);
    world.background();
    world.push->granted = PushSystem::Permission::Granted;
  });

  step(S("the user returns to the app"), [](World& world, const Captures&, const Table&) { world.foreground(); });

  step(S("notification settings show the phone as allowed"), [](World& world, const Captures&, const Table&) {
    openNotificationSettings(world);
    world.waitFor([&] { return textOf(world, S("notificationsPermission")) == QLatin1String("System permission: Allowed"); },
                  [&] { return S("the permission to show as allowed; the screen says: %1").arg(screenTexts(world)); });
  });

  // The distributor.

  step(S("the user picked %1 as the phone's UnifiedPush distributor").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.push->installedDistributors = {{S("io.heckel.ntfy"), S("ntfy")}, {S("org.unifiedpush.distributor.nextpush"), S("NextPush")}};
    world.push->granted = PushSystem::Permission::Granted;
    openNotificationSettings(world);
    world.tap(S("notificationsDevice"));
    QString id;
    for (const PushSystem::Distributor& distributor : std::as_const(world.push->installedDistributors)) {
      if (distributor.label == c[0]) id = distributor.id;
    }
    expect(!id.isEmpty(), S("%1 is not installed").arg(c[0]));
    world.tap(S("notificationsDistributor:") + id);
    world.waitFor([&] { return pushOf(world).registration.value(QLatin1String("distributor")) == id; },
                  [&] { return S("the phone to register through %1; notifications are %2").arg(c[0], show(notifications(world))); });
  });

  step(S("%1 sends the alert to the phone's endpoint at that distributor").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == world.mc.label, S("the phone is paired with %1").arg(world.mc.label));
    const QList<FakePush::Sent>& sent = pushOf(world).sent;
    const auto alerted = std::find_if(sent.cbegin(), sent.cend(), [](const FakePush::Sent& one) { return one.message.contains(QLatin1String("alert")); });
    expect(alerted != sent.cend(), S("the MC pushed no alert"));
    expect(alerted->endpoint == FakePushSystem::endpointOf(world.push->subscribed) && world.push->subscribed == QLatin1String("io.heckel.ntfy"),
           S("the alert went to %1, and the phone is registered with %2").arg(alerted->endpoint, world.push->subscribed));
  });

  step(S("no HAL-C2-hosted service carries the alert"), [](World& world, const Captures&, const Table&) {
    for (const FakePush::Sent& one : std::as_const(pushOf(world).sent)) {
      expect(QUrl(one.endpoint).host() == QLatin1String("ntfy.sh"), S("a push went to %1").arg(one.endpoint));
    }
  });

  step(S("%1 has several threads whose turns finished days ago").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(c[0] == world.mc.label, S("the phone is paired with %1").arg(world.mc.label));
    for (const QString& title : {S("Old work 1"), S("Old work 2"), S("Old work 3")}) {
      const QString thread = haveThread(world, title);
      updateRow(world.mc, thread, {{S("latestRunId"), S("run-old-") + thread}, {S("status"), S("completed")},
                                   {S("latestRunCompletedAt"), S("2026-09-19T10:00:00Z")}, {S("updatedAt"), S("2026-09-19T10:00:00Z")}});
    }
  });

  // The MC's process comes back: the phone connects again and registers anew.
  step(S("the MC starts"), [](World& world, const Captures&, const Table&) {
    const int before = pushOf(world).registrations;
    world.mc.drop();
    world.waitFor([&] { return pushOf(world).registrations > before; }, S("the phone to register with the restarted MC"));
  });

  step(S("no alert is pushed for those threads"), [](World& world, const Captures&, const Table&) {
    for (const FakePush::Sent& one : std::as_const(pushOf(world).sent)) {
      expect(!one.message.contains(QLatin1String("alert")), S("the MC pushed %1").arg(show(one.message.toVariantMap())));
    }
    expectNoAlert(world);
    const auto card = world.push->card();
    expect(!card, S("the lock screen shows %1").arg(card ? show(card->toVariantMap()) : S()));
  });

  // Agents' events.

  step(S("the app is in the background"), [](World& world, const Captures&, const Table&) {
    pushOf(world).keepForeground = false;
    world.background();
  });

  step(S("the app is in the foreground"), [](World& world, const Captures&, const Table&) {
    pushOf(world).keepForeground = true;
    if (!world.isOpen()) world.open();
    world.foreground();
  });

  step(S("the app goes to the background"), [](World& world, const Captures&, const Table&) {
    flush(world);
    pushOf(world).keepForeground = false;
    world.background();
  });

  step(S("the app (?:is|was) not running"), [](World& world, const Captures&, const Table&) {
    turnOn(world);
    world.close();
  });

  step(S("an agent in %1 (finishes its turn|fails|needs approval for a command|asks the user a question|needs the user's input)").arg(kQuoted),
       [](World& world, const Captures& c, const Table&) { awayEvent(world, c[0], c[1]); });

  step(S("an agent finishes its turn"), [](World& world, const Captures&, const Table&) { awayEvent(world, S("Fix checkout"), S("finishes its turn")); });

  step(S("agents in five threads finish their turns together"), [](World& world, const Captures&, const Table&) {
    if (!pushOf(world).keepForeground) world.background();
    QList<QJsonObject> due;
    for (const QString& title : {S("Fix checkout"), S("Add search"), S("Tidy docs"), S("Speed up tests"), S("Bump deps")}) {
      const QString thread = haveThread(world, title);
      setPhase(world, thread, S("completed"));
      due.append(dueAlert(world, thread, S("completed")));
    }
    alert(world, due);
  });

  step(S("the user is reading %1 on the desktop").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    updateRow(world.mc, haveThread(world, c[0]), {{S("lastVisitedAt"), iso(world.push->clock)}});
  });

  step(S("the alert reaches the phone more than ten minutes after that"), [](World& world, const Captures&, const Table&) {
    world.push->clock += 11 * kMinute;
    flush(world);
  });

  step(S("the same alert is delivered again"), [](World& world, const Captures&, const Table&) { deliverAgain(world); });

  // Alerts on the phone.

  step(S("the phone shows an alert for %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    if (!world.checking) {
      if (world.isOpen()) turnOn(world);
      if (world.isOpen()) world.background();
      agentEvent(world, haveThread(world, c[0]), S("finishes its turn"));
    }
    expectAlertFor(world, c[0]);
  });

  step(S("the phone shows an alert"), [](World& world, const Captures&, const Table&) {
    expect(!shownAlerts(world).isEmpty(), S("the phone shows no alert"));
  });

  step(S("the phone shows no alert"), [](World& world, const Captures&, const Table&) { expectNoAlert(world); });

  step(S("the phone shows one alert for %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    flush(world);
    const auto posted = std::count_if(world.push->alertsPosted.cbegin(), world.push->alertsPosted.cend(),
                                      [&](const FakePushSystem::Posted& one) { return one.effect.value(QLatin1String("title")) == c[0]; });
    expect(posted == 1, S("the phone put up %1 alerts for %2").arg(posted).arg(c[0]));
  });

  step(S("the phone shows one alert titled %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QList<QJsonObject> shown = shownAlerts(world);
    expect(shown.size() == 1 && shown.first().value(QLatin1String("title")) == c[0], S("the phone shows %1").arg(describeAlerts(world)));
  });

  step(S("the alert lists the title of each of the five threads"), [](World& world, const Captures&, const Table&) {
    const QString body = shownAlerts(world).value(0).value(QLatin1String("body")).toString();
    for (const QString& title : {S("Fix checkout"), S("Add search"), S("Tidy docs"), S("Speed up tests"), S("Bump deps")}) {
      expect(body.split(QLatin1Char('\n')).contains(title), S("the alert reads %1").arg(body));
    }
  });

  step(S("a repeat delivery of that alert does not change it"), [](World& world, const Captures&, const Table&) {
    const auto before = world.push->alertsPosted.size();
    const QList<QJsonObject> shown = shownAlerts(world);
    deliverAgain(world);
    flush(world);
    expect(world.push->alertsPosted.size() == before && shownAlerts(world) == shown, S("the phone now shows %1").arg(describeAlerts(world)));
  });

  step(S("the user taps the alert"), [](World& world, const Captures&, const Table&) { tapAlert(world); });

  step(S("%1 is shown once").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return shownThread(world) == c[0]; }, [&] { return S("%1; the screen says: %2").arg(c[0], screenTexts(world)); });
    // Whatever was still on its way (the link the app started with, the rows) has come.
    world.sync();
    QCoreApplication::processEvents();
    expect(shownThread(world) == c[0], S("the app moved on to %1").arg(shownThread(world)));
  });

  step(S("going back does not show %1 again").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.back();
    world.waitFor([&] { return world.find(S("threadScreen")) == nullptr && world.find(S("homeScreen")) != nullptr; },
                  [&] { return S("the home screen; the screen shows %1 and says: %2").arg(shownThread(world), screenTexts(world)); });
    expect(shownThread(world) != c[0], S("%1 is shown again").arg(c[0]));
  });

  // Alerts whose links name no thread.
  step(S("the phone shows an alert whose link (points outside HAL-C2|is malformed|names neither an environment nor a thread)"),
       [](World& world, const Captures& c, const Table&) {
         turnOn(world);
         FakePush& fake = pushOf(world);
         fake.routeBefore = world.state(S("route")).toMap();
         fake.threadBefore = shownThread(world);
         world.background();
         const QString link = c[0] == QLatin1String("points outside HAL-C2") ? S("https://example.com/threads/env-a/tax-line")
                              : c[0] == QLatin1String("is malformed")         ? S("hal-c2://threads/%%zz/tax line?")
                                                                              : S("hal-c2://threads");
         pushToPhone(world, {{S("alert"), QJsonObject{{S("id"), S("odd:") + c[0]}, {S("kind"), S("completed")}, {S("title"), S("Tax line")},
                                                      {S("body"), S("Agent finished")}, {S("link"), link}}}});
         expect(!shownAlerts(world).isEmpty(), S("the alert did not reach the phone"));
       });

  step(S("the app stays where it was"), [](World& world, const Captures&, const Table&) {
    const FakePush& fake = pushOf(world);
    world.foreground();
    world.sync();
    expect(world.state(S("route")).toMap().value(S("kind")) == fake.routeBefore.value(S("kind")) && shownThread(world) == fake.threadBefore,
           S("the app went from %1 to %2").arg(show(fake.routeBefore), show(world.state(S("route")))));
  });

  step(S("no error is shown"), [](World& world, const Captures&, const Table&) {
    const QVariantList toasts = world.state(S("toasts")).toMap().value(S("toasts")).toList();
    expect(toasts.isEmpty(), S("the app shows %1").arg(show(toasts)));
  });

  step(S("the phone shows an alert for %1 whose link is not a thread link").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    turnOn(world);
    world.background();
    const QString thread = haveThread(world, c[0]);
    pushOf(world).draft = {{S("id"), S("odd:") + thread}, {S("kind"), S("completed")}, {S("title"), c[0]}, {S("body"), S("Agent finished")},
                           {S("link"), S("https://example.com/") + thread}};
  });

  step(S("the alert names the environment and the thread"), [](World& world, const Captures&, const Table&) {
    QJsonObject draft = std::exchange(pushOf(world).draft, {});
    const QString thread = draft.value(QLatin1String("id")).toString().mid(4);
    draft.insert(S("environmentId"), world.mc.environmentId);
    draft.insert(S("threadId"), thread);
    pushToPhone(world, {{S("alert"), draft}});
    expectAlertFor(world, draft.value(QLatin1String("title")).toString());
  });

  // Force-stopped.

  step(S("the user force-stopped the app on Android"), [](World& world, const Captures&, const Table&) {
    turnOn(world);
    world.close();
    world.push->forceStop();
  });

  step(S("later alerts arrive again"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !world.push->subscribed.isEmpty(); }, S("the app to ask its distributor for an endpoint again"));
    world.sync();
    world.background();
    agentEvent(world, haveThread(world, S("Add search")), S("finishes its turn"));
    expectAlertFor(world, S("Add search"));
  });

  // Live activity.

  step(S("live activity updates are on"), [](World& world, const Captures&, const Table&) { liveActivityOn(world); });

  step(S("the user sends a message in %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) { sendMessage(world, c[0]); });

  step(S("the lock screen shows that agent work is in progress"), [](World& world, const Captures&, const Table&) {
    awaitCard(world, [](const QJsonObject& card) { return card.value(QLatin1String("ongoing")).toBool(); }, S("a card for work in progress"));
  });

  step(S("the lock screen shows (?:that )?agent work (?:is )?in progress for %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    if (!world.checking) {
      liveActivityOn(world);
      sendMessage(world, c[0]);
    }
    awaitCard(world, [&](const QJsonObject& card) { return card.value(QLatin1String("ongoing")).toBool() && mentions(card, c[0]); },
              S("a card for %1 at work").arg(c[0]));
  });

  // The agent the user follows: the app keeps the state it is in.
  step(S("the agent finishes its turn"), [](World& world, const Captures&, const Table&) {
    expect(!pushOf(world).current.isEmpty(), S("no agent is at work"));
    agentEvent(world, pushOf(world).current, S("finishes its turn"));
  });

  step(S("the lock screen (?:still )?shows that the agent work completed"), [](World& world, const Captures&, const Table&) {
    const QJsonObject card = awaitCard(
        world, [](const QJsonObject& card) { return !card.value(QLatin1String("ongoing")).toBool() && card.value(QLatin1String("text")).toString().startsWith(QLatin1String("Done")); },
        S("a card for finished work"));
    for (const char* key : {"chip", "action", "dismissAction"}) {
      expect(!card.contains(QLatin1String(key)), S("the finished card still has the %1 %2").arg(QLatin1String(key), show(card.value(QLatin1String(key)).toVariant())));
    }
  });

  step(S("the result stays visible for up to 15 minutes"), [](World& world, const Captures&, const Table&) {
    const qint64 timeout = qint64(currentCard(world).value(QLatin1String("timeoutMs")).toDouble());
    expect(timeout > 0 && timeout <= 15 * kMinute, S("the card stays for %1 ms").arg(timeout));
    world.push->clock += 14 * kMinute;
    expect(world.push->card().has_value(), S("the card went before 15 minutes"));
    world.push->clock += kMinute + 1;
    expect(!world.push->card().has_value(), S("the card is still there after 15 minutes"));
  });

  step(S("the lock screen shows a single card covering both threads"), [](World& world, const Captures&, const Table&) {
    const QJsonObject card = awaitCard(world, [](const QJsonObject& card) { return card.value(QLatin1String("lines")).toArray().size() == 2; },
                                       S("one card for two threads"));
    expect(mentions(card, S("Fix checkout")) && mentions(card, S("Add search")), S("the card reads %1").arg(show(card.toVariantMap())));
    for (const FakePushSystem::Posted& posted : std::as_const(world.push->cardsPosted)) {
      expect(posted.effect.value(QLatin1String("id")).toInt() == push::kCardId, S("a second card was posted: %1").arg(show(posted.effect.toVariantMap())));
    }
  });

  step(S("the user turns live activity updates (on|off)"), [](World& world, const Captures& c, const Table&) {
    openNotificationSettings(world);
    QQuickItem* toggle = world.item(S("notificationsLiveActivity"));
    expect(toggle->property("checked").toBool() != (c[0] == QLatin1String("on")), S("live activity updates are already %1").arg(c[0]));
    world.tap(toggle);
    world.sync();
  });

  step(S("sending work starts (no|a) live activity"), [](World& world, const Captures& c, const Table&) {
    sendMessage(world, S("Sent work %1").arg(++pushOf(world).sentWork));
    if (c[0] == QLatin1String("a")) {
      awaitCard(world, [](const QJsonObject& card) { return card.value(QLatin1String("ongoing")).toBool(); }, S("a card for work in progress"));
    } else {
      flush(world);
      const auto card = world.push->card();
      expect(!card, S("the lock screen shows %1").arg(card ? show(card->toVariantMap()) : S()));
    }
  });

  step(S("live activity updates stay off"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!notifications(world).value(S("liveActivity")).toBool() && !world.item(S("notificationsLiveActivity"))->property("checked").toBool(),
           S("live activity updates are %1").arg(show(notifications(world))));
  });

  step(S("the user is told notification permission is needed"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return textOf(world, S("notificationsMessage")).contains(QLatin1String("needs notification permission")); },
                  [&] { return S("the screen says: %1").arg(screenTexts(world)); });
  });

  // The phone in the user's hand.

  step(S("the user is on an Android (?:(\\d+) )?phone"), [](World& world, const Captures& c, const Table&) {
    // The group is optional: an Android phone of the version HAL-C2 targets.
    const int sdk = c.value(0).isEmpty() ? 35 : c.value(0).toInt() + 20;
    if (world.push->androidSdk != sdk) {
      world.push->androidSdk = sdk;
      restart(world);
    }
    turnOn(world);
  });

  step(S("the agent activity is shown as a live update"), [](World& world, const Captures&, const Table&) {
    const QJsonObject card = awaitCard(world, [](const QJsonObject& card) { return card.value(QLatin1String("ongoing")).toBool(); }, S("a card"));
    expect(card.value(QLatin1String("promoted")).toBool() && !card.value(QLatin1String("chip")).toString().isEmpty(),
           S("the card is %1").arg(show(card.toVariantMap())));
  });

  step(S("the agent activity is shown as an ongoing notification"), [](World& world, const Captures&, const Table&) {
    const QJsonObject card = awaitCard(world, [](const QJsonObject& card) { return card.value(QLatin1String("ongoing")).toBool(); }, S("a card"));
    expect(!card.value(QLatin1String("promoted")).toBool(), S("the card asks to be a live update: %1").arg(show(card.toVariantMap())));
  });

  step(S("the user is offered the live update settings"), [](World& world, const Captures&, const Table&) {
    openNotificationSettings(world);
    world.tap(S("notificationsLiveUpdateSettings"));
    world.waitFor([&] { return world.push->liveUpdateSettingsOpened > 0; }, S("the live update settings to open"));
  });

  step(S("the user is not offered the live update settings"), [](World& world, const Captures&, const Table&) {
    openNotificationSettings(world);
    expect(world.find(S("notificationsLiveUpdateSettings")) == nullptr, S("the screen offers the live update settings"));
  });

  step(S("the ongoing agent activity card is showing"), [](World& world, const Captures&, const Table&) {
    liveActivityOn(world);
    flush(world);
    if (!world.push->card()) sendMessage(world, S("Fix checkout"));
    awaitCard(world, [](const QJsonObject& card) { return card.value(QLatin1String("ongoing")).toBool(); }, S("the activity card"));
  });

  step(S("the user dismisses the card"), [](World& world, const Captures&, const Table&) {
    flush(world);
    world.push->dismissCard();
  });

  step(S("the card is gone"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!world.push->card(), S("the card is still there"));
  });

  step(S("alerts still arrive when an agent finishes"), [](World& world, const Captures&, const Table&) {
    world.background();
    agentEvent(world, pushOf(world).current, S("finishes its turn"));
    expectAlertFor(world, S("Fix checkout"));
    expect(!world.push->card(), S("the dismissed card came back"));
  });

  step(S("the lock screen shows work in progress for a turn that already ended"), [](World& world, const Captures&, const Table&) {
    liveActivityOn(world);
    sendMessage(world, S("Fix checkout"));
    awaitCard(world, [](const QJsonObject& card) { return card.value(QLatin1String("ongoing")).toBool(); }, S("a card for work in progress"));
    // The turn ends while the app is away, and the push that said so was lost.
    world.background();
    const QString thread = pushOf(world).current;
    setPhase(world, thread, S("completed"));
    world.sync();
    world.push->inFlight.clear();
    expect(currentCard(world).value(QLatin1String("ongoing")).toBool(), S("the card already shows the turn ended"));
  });

  step(S("the lock screen shows the current state of the agent work"), [](World& world, const Captures&, const Table&) {
    awaitCard(world, [](const QJsonObject& card) { return !card.value(QLatin1String("ongoing")).toBool() && card.value(QLatin1String("text")).toString().startsWith(QLatin1String("Done")); },
              S("a card for the finished turn"));
  });

  step(S("no agent is working in any environment"), [](World& world, const Captures&, const Table&) {
    for (auto it = world.mc.threads.cbegin(); it != world.mc.threads.cend(); ++it) {
      expect(!it->contains(QLatin1String("activeRunId")) || it->value(QLatin1String("activeRunId")).isNull(), S("%1 is at work").arg(it.key()));
    }
  });

  step(S("the lock screen shows no agent activity"), [](World& world, const Captures&, const Table&) {
    flush(world);
    const auto card = world.push->card();
    expect(!card && world.push->cardsPosted.isEmpty(), S("the lock screen shows %1").arg(card ? show(card->toVariantMap()) : S("a card it took down")));
  });

  step(S("an agent in %1 was started from the desktop and is working").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.background();
    const QString thread = haveThread(world, c[0]);
    pushOf(world).current = thread;
    setPhase(world, thread, S("running"));
    world.sync();
    world.push->inFlight.clear();
  });

  step(S("two hours pass without a new update"), [](World& world, const Captures&, const Table&) {
    flush(world);
    world.push->clock += 120 * kMinute + 1;
  });

  step(S("%1 no longer pushes to the phone").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const FakePush& fake = pushOf(world);
    expect(fake.registration.isEmpty() && fake.unregistrations > 0,
           S("%1 still has the phone registered: %2").arg(c[0], show(fake.registration.toVariantMap())));
  });

  // An MC that did not hear the phone go pushes as it did before.
  step(S("%1 pushes an alert to the phone as it was registered").arg(kQuoted), [](World& world, const Captures&, const Table&) {
    FakePush& fake = pushOf(world);
    expect(!fake.lastRegistration.isEmpty(), S("the phone never registered"));
    const QJsonObject keys = fake.lastRegistration.value(QLatin1String("keys")).toObject();
    const QJsonObject alert{{S("id"), S("env:late:completed:run-9")}, {S("kind"), S("completed")}, {S("title"), S("Fix checkout")},
                            {S("body"), S("Agent finished")},      {S("environmentId"), world.mc.environmentId}, {S("threadId"), S("late")}};
    const QJsonObject message{{S("v"), 1}, {S("sentAt"), double(world.push->clock)}, {S("alert"), alert}};
    const QByteArray body = push::encrypt(QJsonDocument(message).toJson(QJsonDocument::Compact), fromBase64Url(keys.value(QLatin1String("p256dh"))),
                                          fromBase64Url(keys.value(QLatin1String("auth"))));
    world.push->inFlight.append({fake.lastRegistration.value(QLatin1String("endpoint")).toString(), body});
    world.push->deliver();
  });

  step(S("the lock screen activity ends"), [](World& world, const Captures&, const Table&) {
    const auto card = world.push->card();
    expect(!card, S("the lock screen shows %1").arg(card ? show(card->toVariantMap()) : S()));
  });

  step(S("the lock screen shows that the agent work in %1 completed").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    liveActivityOn(world);
    sendMessage(world, c[0]);
    agentEvent(world, pushOf(world).current, S("finishes its turn"));
    awaitCard(world, [](const QJsonObject& card) { return !card.value(QLatin1String("ongoing")).toBool(); }, S("a card for finished work"));
  });

  step(S("an older update saying the work is still running arrives late"), [](World& world, const Captures&, const Table&) {
    FakePush& fake = pushOf(world);
    push::ActivityRow running = fake.phases.value(fake.current);
    running.phase = S("running");
    running.at = world.push->clock - kMinute;
    pushToPhone(world, {{S("sentAt"), double(world.push->clock - kMinute)}, {S("activity"), push::activity({running}, world.push->clock - kMinute)}});
    flush(world);
  });

  step(S("the user dismissed the agent activity card for %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    liveActivityOn(world);
    sendMessage(world, c[0]);
    agentEvent(world, pushOf(world).current, S("finishes its turn"));
    awaitCard(world, [](const QJsonObject& card) { return !card.value(QLatin1String("ongoing")).toBool(); }, S("a card for finished work"));
    world.push->dismissCard();
  });

  step(S("the agent starts a new turn in %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QString thread = haveThread(world, c[0]);
    pushOf(world).current = thread;
    world.push->clock += kMinute;
    setPhase(world, thread, S("running"));
    pushToPhone(world, {});
  });

  step(S("the ongoing agent activity card is shown again"), [](World& world, const Captures&, const Table&) {
    awaitCard(world, [](const QJsonObject& card) { return card.value(QLatin1String("ongoing")).toBool(); }, S("the card back for the new turn"));
  });

  step(S("the finished update for %1 is delivered again").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QList<FakePush::Sent>& sent = pushOf(world).sent;
    expect(!sent.isEmpty() && mentions(push::card(sent.last().message.value(QLatin1String("activity")).toObject(), 1, 35), c[0]),
           S("the MC pushed no update for %1").arg(c[0]));
    deliverAgain(world);
  });

  step(S("no agent activity card is shown"), [](World& world, const Captures&, const Table&) {
    flush(world);
    const auto card = world.push->card();
    expect(!card, S("the lock screen shows %1").arg(card ? show(card->toVariantMap()) : S()));
  });

  step(S("the agent's status changes"), [](World& world, const Captures&, const Table&) {
    flush(world);
    pushOf(world).draft = {{S("cards"), int(world.push->cardsPosted.size())}};
    agentEvent(world, pushOf(world).current, S("needs approval"));
  });

  step(S("the card updates without a sound"), [](World& world, const Captures&, const Table&) {
    const int before = pushOf(world).draft.value(QLatin1String("cards")).toInt();
    const QJsonObject card = awaitCard(world, [&](const QJsonObject&) { return world.push->cardsPosted.size() > before; }, S("the card to change"));
    const QJsonObject channel = [&] {
      for (const QJsonValue& value : std::as_const(world.push->channels)) {
        if (value.toObject().value(QLatin1String("id")) == card.value(QLatin1String("channel"))) return value.toObject();
      }
      return QJsonObject();
    }();
    expect(card.value(QLatin1String("silent")).toBool() && channel.value(QLatin1String("importance")) == QLatin1String("low"),
           S("the card %1 on the channel %2").arg(show(card.toVariantMap()), show(channel.toVariantMap())));
  });

  step(S("alerts for finished agents still make a sound"), [](World& world, const Captures&, const Table&) {
    world.background();
    agentEvent(world, haveThread(world, S("Add search")), S("finishes its turn"));
    const QList<QJsonObject> shown = shownAlerts(world, S("Add search"));
    expect(!shown.isEmpty(), S("no alert; the phone shows %1").arg(describeAlerts(world)));
    for (const QJsonValue& value : std::as_const(world.push->channels)) {
      if (value.toObject().value(QLatin1String("id")) != shown.first().value(QLatin1String("channel"))) continue;
      expect(value.toObject().value(QLatin1String("importance")) == QLatin1String("high"), S("alerts go to %1").arg(show(value.toObject().toVariantMap())));
      return;
    }
    fail(S("the alert's channel %1 does not exist").arg(shown.first().value(QLatin1String("channel")).toString()));
  });

  step(S("the agent in %1 (is waiting for approval|is asking the user a question)").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    liveActivityOn(world);
    const QString thread = haveThread(world, c[0]);
    pushOf(world).current = thread;
    setPhase(world, thread, c[1] == QLatin1String("is waiting for approval") ? S("waiting_for_approval") : S("waiting_for_input"));
  });

  step(S("the card offers %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QJsonObject card = awaitCard(world, [&](const QJsonObject& card) { return card.value(QLatin1String("action")) == c[0]; }, S("the card to offer %1").arg(c[0]));
    expect(!card.value(QLatin1String("link")).toString().isEmpty(), S("the card opens nothing"));
  });

  step(S("the user taps %1 on the card").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QJsonObject card = currentCard(world);
    expect(card.value(QLatin1String("action")) == c[0], S("the card offers %1").arg(card.value(QLatin1String("action")).toString()));
    world.foreground();
    world.followLink(card.value(QLatin1String("link")).toString());
  });

  // The card's text.

  step(S("the ongoing agent activity card covers (.+)"), [](World& world, const Captures& c, const Table&) {
    const QString what = c[0];
    if (what == QLatin1String("one thread waiting for approval and others working")) {
      cover(world, {{S("Agent 1"), S("running")}, {S("Agent 2"), S("running")}, {S("Agent 3"), S("waiting_for_approval")}});
    } else if (what == QLatin1String("two threads waiting for approval or answers")) {
      cover(world, {{S("Agent 1"), S("waiting_for_approval")}, {S("Agent 2"), S("waiting_for_input")}});
    } else if (what == QLatin1String("three threads working")) {
      cover(world, several(3, S("running")));
    } else if (what == QLatin1String("two threads working and one failed")) {
      cover(world, {{S("Agent 1"), S("running")}, {S("Agent 2"), S("running")}, {S("Agent 3"), S("failed")}});
    } else if (what == QLatin1String("two threads finished and one failed")) {
      cover(world, {{S("Agent 1"), S("completed")}, {S("Agent 2"), S("completed")}, {S("Agent 3"), S("failed")}});
    } else if (what == QLatin1String("three threads finished")) {
      cover(world, several(3, S("completed")));
    } else if (what == QLatin1String("two working threads in \"shop\"")) {
      cover(world, several(2, S("running")));
    } else if (what == QLatin1String("only \"Fix checkout\" in \"shop\"")) {
      cover(world, {{S("Fix checkout"), S("running")}});
    } else if (what == QLatin1String("five threads in different states")) {
      // Newest first within a status: the approval came after the question.
      cover(world, {{S("Add search"), S("waiting_for_input")}, {S("Fix checkout"), S("waiting_for_approval")}, {S("Write guide"), S("running"), S("docs")},
                    {S("Speed up tests"), S("failed")}, {S("Fix typos"), S("completed"), S("docs")}});
    } else {
      fail(S("no card covering %1").arg(what));
    }
  });

  step(S("the card is titled %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QJsonObject card = currentCard(world);
    expect(card.value(QLatin1String("title")) == c[0], S("the card is titled %1").arg(card.value(QLatin1String("title")).toString()));
  });

  step(S("the card says %1 and that two are active").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QString subtext = currentCard(world).value(QLatin1String("subtext")).toString();
    expect(subtext == c[0] + S(" · 2 active"), S("the card says %1").arg(subtext));
  });

  step(S("the card says %1 beside its status").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QString text = currentCard(world).value(QLatin1String("text")).toString();
    expect(text == S("Working · ") + c[0], S("the card says %1").arg(text));
  });

  step(S("the card shows no progress bar"), [](World& world, const Captures&, const Table&) {
    const QJsonObject card = currentCard(world);
    expect(!card.contains(QLatin1String("progress")) && !card.contains(QLatin1String("progressMax")), S("the card is %1").arg(show(card.toVariantMap())));
  });

  // Android shows a card's lines when it is expanded, which the card has already.
  step(S("the user expands the card"), [](World& world, const Captures&, const Table&) { currentCard(world); });

  step(S("each thread is listed on its own line with its status before its title"), [](World& world, const Captures&, const Table&) {
    const QJsonArray lines = currentCard(world).value(QLatin1String("lines")).toArray();
    const QList<std::pair<QString, QString>> expected{{S("Approval"), S("Fix checkout")}, {S("Input"), S("Add search")}, {S("Failed"), S("Speed up tests")},
                                                      {S("Working"), S("Write guide")}, {S("Done"), S("Fix typos")}};
    expect(lines.size() == expected.size(), S("the card lists %1").arg(show(lines.toVariantList())));
    for (qsizetype index = 0; index < expected.size(); ++index) {
      expect(lines.at(index).toString().startsWith(expected.at(index).first + QLatin1Char(' ') + expected.at(index).second),
             S("line %1 reads %2").arg(index + 1).arg(lines.at(index).toString()));
    }
  });

  step(S("a thread's project is named when the threads are from different projects"), [](World& world, const Captures&, const Table&) {
    const QJsonArray lines = currentCard(world).value(QLatin1String("lines")).toArray();
    expect(lines.at(0).toString().endsWith(S(" · shop")) && lines.at(3).toString().endsWith(S(" · docs")),
           S("the card lists %1").arg(show(lines.toVariantList())));
  });

  step(S("a thread is renamed while its approval is waiting"), [](World& world, const Captures&, const Table&) {
    const QString thread = pushOf(world).current;
    setPhase(world, thread, S("waiting_for_approval"));
    world.push->clock += 5 * kMinute;
    updateRow(world.mc, thread, {{S("title"), S("Fix the checkout total")}, {S("updatedAt"), iso(world.push->clock)}});
    awaitCard(world, [](const QJsonObject& card) { return mentions(card, S("Fix the checkout total")); }, S("the card to show the new title"));
  });

  step(S("the card shows no time and no running timer"), [](World& world, const Captures&, const Table&) {
    const QJsonObject card = currentCard(world);
    expect(!card.value(QLatin1String("showWhen")).toBool() && !card.contains(QLatin1String("chronometer")) && !card.contains(QLatin1String("when")),
           S("the card is %1").arg(show(card.toVariantMap())));
  });

  step(S("the live update covers (.+)"), [](World& world, const Captures& c, const Table&) {
    const QString what = c[0];
    if (what == QLatin1String("one agent working")) {
      cover(world, several(1, S("running")));
    } else if (what == QLatin1String("an agent waiting for approval")) {
      cover(world, several(1, S("waiting_for_approval")));
    } else if (what == QLatin1String("an agent asking a question")) {
      cover(world, several(1, S("waiting_for_input")));
    } else if (what == QLatin1String("an agent waiting for an update")) {
      cover(world, several(1, S("stale")));
    } else if (what == QLatin1String("two agents working")) {
      cover(world, several(2, S("running")));
    } else if (what == QLatin1String("ten agents working")) {
      cover(world, several(10, S("running")));
    } else {
      fail(S("no live update covering %1").arg(what));
    }
  });

  step(S("the live update chip reads %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QJsonObject card = currentCard(world);
    expect(card.value(QLatin1String("promoted")).toBool() && card.value(QLatin1String("chip")) == c[0], S("the card is %1").arg(show(card.toVariantMap())));
  });

  step(S("the ongoing agent activity card shows that the agent work completed"), [](World& world, const Captures&, const Table&) {
    liveActivityOn(world);
    sendMessage(world, S("Fix checkout"));
    agentEvent(world, pushOf(world).current, S("finishes its turn"));
    awaitCard(world, [](const QJsonObject& card) { return !card.value(QLatin1String("ongoing")).toBool(); }, S("a card for finished work"));
    goHome(world);
  });

  step(S("the card can be swiped away"), [](World& world, const Captures&, const Table&) {
    expect(!currentCard(world).value(QLatin1String("ongoing")).toBool(), S("the card is pinned"));
  });

  step(S("tapping the card opens %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.followLink(currentCard(world).value(QLatin1String("link")).toString());
    world.waitFor([&] { return shownThread(world) == c[0]; }, [&] { return S("%1; the screen says: %2").arg(c[0], screenTexts(world)); });
  });

  step(S("the card offers no buttons"), [](World& world, const Captures&, const Table&) {
    const QJsonObject card = currentCard(world);
    expect(card.value(QLatin1String("action")).toString().isEmpty() && card.value(QLatin1String("dismissAction")).toString().isEmpty(),
           S("the card is %1").arg(show(card.toVariantMap())));
  });

  step(S("the card shows no live update chip"), [](World& world, const Captures&, const Table&) {
    const QJsonObject card = currentCard(world);
    expect(card.value(QLatin1String("chip")).toString().isEmpty() && !card.value(QLatin1String("promoted")).toBool(), S("the card is %1").arg(show(card.toVariantMap())));
  });

  // The system's own settings.

  step(S("the user opens the notification settings of HAL-C2 in the system settings"), [](World& world, const Captures&, const Table&) {
    openNotificationSettings(world);
    world.tap(S("notificationsOpenSettings"));
    world.waitFor([&] { return world.push->settingsOpened > 0; }, S("the system settings to open"));
  });

  step(S("%1 and %1 are listed as separate categories").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QHash<QString, QString> ids;
    for (const QJsonValue& value : std::as_const(world.push->channels)) {
      ids.insert(value.toObject().value(QLatin1String("name")).toString(), value.toObject().value(QLatin1String("id")).toString());
    }
    expect(ids.contains(c[0]) && ids.contains(c[1]) && ids.value(c[0]) != ids.value(c[1]), S("the system lists %1").arg(show(world.push->channels.toVariantList())));
  });

  step(S("the phone hides sensitive notification content on the lock screen"), [](World& world, const Captures&, const Table&) {
    world.push->hideSensitive = true;
  });

  step(S("the lock screen does not show the thread's title or text"), [](World& world, const Captures&, const Table&) {
    QList<QJsonObject> shown = shownAlerts(world);
    expect(!shown.isEmpty(), S("no alert reached the phone"));
    if (const auto card = world.push->card()) shown.append(*card);
    for (const QJsonObject& item : std::as_const(shown)) {
      const QString lockScreen = item.value(QLatin1String("publicTitle")).toString() + QLatin1Char('\n') + item.value(QLatin1String("publicText")).toString();
      expect(item.value(QLatin1String("visibility")) == QLatin1String("private") && !lockScreen.contains(QLatin1String("Fix checkout")) &&
                 !lockScreen.contains(QLatin1String("Agent finished")),
             S("the lock screen shows %1").arg(show(item.toVariantMap())));
    }
  });

  // Stale and future pushes.

  step(S("an update arrives that is dated an hour ahead"), [](World& world, const Captures&, const Table&) {
    world.background();
    const QString thread = haveThread(world, S("Add search"));
    setPhase(world, thread, S("completed"));
    QJsonObject due = dueAlert(world, thread, S("completed"));
    const qint64 ahead = world.push->clock + 60 * kMinute;
    pushToPhone(world, {{S("sentAt"), double(ahead)}, {S("alert"), due}, {S("activity"), push::activity(pushOf(world).phases.values(), ahead)}});
    flush(world);
  });

  step(S("the phone shows nothing for it"), [](World& world, const Captures&, const Table&) {
    expectNoAlert(world);
    expect(!world.push->card(), S("the lock screen shows a card"));
  });

  step(S("a current update arrives for %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    agentEvent(world, haveThread(world, c[0]), S("finishes its turn"));
  });

  step(S("the phone shows it"), [](World& world, const Captures&, const Table&) { expectAlertFor(world, S("Fix checkout")); });

  // Mutes and quiet hours.

  const auto mute = [](World& world, const QString& title, bool muted) {
    turnOn(world);
    pushOf(world).keepForeground = false;
    const QString thread = haveThread(world, title);
    if (shownThread(world) != title) {
      goHome(world);
      openThread(world, title);
    }
    world.tap(muted ? S("muteAlerts") : S("unmuteAlerts"));
    const QString key = world.mc.environmentId + QLatin1Char(':') + thread;
    world.waitFor([&] { return pushOf(world).registration.value(QLatin1String("mutedThreads")).toArray().contains(key) == muted; },
                  [&] { return S("the MC to have %1 %2; it has %3").arg(key, muted ? S("muted") : S("unmuted"), show(pushOf(world).registration.toVariantMap())); });
    world.item(muted ? S("unmuteAlerts") : S("muteAlerts"));
  };

  step(S("the user mutes alerts for %1").arg(kQuoted), [mute](World& world, const Captures& c, const Table&) { mute(world, c[0], true); });
  step(S("alerts for %1 are muted").arg(kQuoted), [mute](World& world, const Captures& c, const Table&) { mute(world, c[0], true); });
  step(S("the user unmutes %1").arg(kQuoted), [mute](World& world, const Captures& c, const Table&) { mute(world, c[0], false); });

  const auto quietHours = [](World& world, const QString& start, const QString& end, bool approvals) {
    turnOn(world);
    openNotificationSettings(world);
    world.tap(S("notificationsQuietStart"));
    world.type(start);
    world.tap(S("notificationsQuietEnd"));
    world.type(end);
    if (approvals) world.tap(S("notificationsQuietAllowApprovals"));
    world.tap(S("notificationsQuietSave"));
    world.waitFor(
        [&] {
          const QJsonObject hours = pushOf(world).registration.value(QLatin1String("quietHours")).toObject();
          return hours.value(QLatin1String("start")).toInt() == QTime::fromString(start, S("HH:mm")).msecsSinceStartOfDay() / kMinute &&
                 hours.value(QLatin1String("end")).toInt() == QTime::fromString(end, S("HH:mm")).msecsSinceStartOfDay() / kMinute &&
                 hours.value(QLatin1String("allowApprovals")).toBool() == approvals;
        },
        [&] { return S("the MC to have quiet hours; it has %1").arg(show(pushOf(world).registration.toVariantMap())); });
    expect(textOf(world, S("notificationsQuietHoursState")) == S("Alerts wait from %1 to %2.").arg(start, end), S("the screen says: %1").arg(screenTexts(world)));
  };

  step(S("the user set quiet hours from (\\d\\d:\\d\\d) to (\\d\\d:\\d\\d)"), [quietHours](World& world, const Captures& c, const Table&) {
    quietHours(world, c[0], c[1], false);
  });

  step(S("the user set quiet hours that let approval requests through"), [quietHours](World& world, const Captures&, const Table&) {
    quietHours(world, S("22:00"), S("07:00"), true);
  });

  step(S("an agent finishes its turn at (\\d\\d:\\d\\d)"), [](World& world, const Captures& c, const Table&) {
    advanceTo(world, c[0]);
    awayEvent(world, S("Fix checkout"), S("finishes its turn"));
  });

  step(S("an agent needs approval during quiet hours"), [](World& world, const Captures&, const Table&) {
    advanceTo(world, S("23:00"));
    awayEvent(world, S("Fix checkout"), S("needs approval for a command"));
  });

  step(S("the phone shows no alert until (\\d\\d:\\d\\d)"), [](World& world, const Captures& c, const Table&) {
    expectNoAlert(world);
    const QTime until = QTime::fromString(c[0], S("HH:mm"));
    advanceTo(world, until.addSecs(-60).toString(S("HH:mm")));
    expectNoAlert(world);
    advanceTo(world, c[0]);
    expectAlertFor(world, S("Fix checkout"));
  });
});

}  // namespace
