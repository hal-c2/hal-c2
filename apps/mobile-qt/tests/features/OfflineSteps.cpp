// What the phone keeps and does while it cannot reach its environment, and as
// the system sends it to the background and back
// (features/mobile/offline-and-lifecycle.feature, and the outbox of
// features/mobile/composer.feature): the desktop's ComposerController with its
// outbox on (MobileApp), and the McClient and Resume under the phone's root.
// "Unreachable" is the MC taking no connection and dropping the one it has;
// "reachable" is it taking them again, which the phone finds on its own.

#include <QDirIterator>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQuickItem>

#include <memory>
#include <utility>

#include "ComposerController.h"
#include "ConnectionWatch.h"
#include "FakeThreads.h"
#include "Harness.h"
#include "McClient.h"
#include "MobileApp.h"
#include "NativeShell.h"
#include "Phone.h"
#include "Resume.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "World.h"

namespace {

using S = QString;

const QString kNow = S("2026-09-23T10:00:00Z");
// What the phone last saw of the Background's thread.
const QString kLastSeen = S("The checkout total includes tax now.");
// A thread the phone lists and never opened.
const QString kNeverOpened = S("Release notes");
// A thread started on another device while the phone was away.
const QString kStartedAway = S("Ship it");
// What the agent said while the app was away.
const QString kWhileAway = S("Shipping is next.");

struct Offline {
  qsizetype connections = 0;
  // Whether the Background's thread holds what the phone last saw.
  bool seeded = false;
  // How the composer stood when the scenario's message was sent: its model
  // and its interaction mode.
  QString model;
  QString interactionMode;
  // The delays the outbox waited after a send the connection dropped.
  QList<int> retries;
  // The delays the phone waits for real, before the scenario shortens them.
  QList<int> realDelays;
  bool watching = false;
  // Whether every message.dispatch drops the connection.
  bool dropping = false;
  bool dropsInstalled = false;
};

Offline& offline(World& world) {
  return world.mc.part<Offline>();
}

McClient& client(World& world) {
  return *world.native().client();
}

ComposerController& composerController(World& world) {
  return *world.native().controller<ComposerController>();
}

QVariantMap composerState(World& world) {
  return world.state(S("composer")).toMap();
}

QVariantList outbox(World& world) {
  return world.state(S("turn")).toMap().value(S("outbox")).toList();
}

QString screen(World& world) {
  return world.texts().join(S(" | "));
}

// The outbox's entry for `text` in the open thread, if it lists one.
QVariantMap waiting(World& world, const QString& text) {
  for (const QVariant& entry : outbox(world)) {
    if (entry.toMap().value(S("text")) == text) return entry.toMap();
  }
  return {};
}

// The texts of the sends the phone keeps on disk, in any thread.
QStringList savedUnsent(World& world) {
  QStringList texts;
  QDirIterator files(world.homeDir(), {S("shell-composer.json")}, QDir::Files, QDirIterator::Subdirectories);
  while (files.hasNext()) {
    QFile file(files.next());
    if (!file.open(QIODevice::ReadOnly)) continue;
    for (const QJsonValue& entry : QJsonDocument::fromJson(file.readAll()).object().value(QLatin1String("unsent")).toArray()) {
      texts.append(entry.toObject().value(QLatin1String("text")).toString());
    }
  }
  return texts;
}

// The texts the MC was sent as messages, oldest first.
QStringList sentTexts(World& world) {
  world.sync();
  QStringList texts;
  for (const QJsonObject& command : std::as_const(world.mc.commands)) {
    if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch")) texts.append(command.value(QLatin1String("text")).toString());
  }
  return texts;
}

// A provider the composer can send with, as the MC lists it.
void offerClaude(World& world) {
  QJsonArray levels;
  QJsonObject model{{S("slug"), S("claude-sonnet")}, {S("name"), S("Sonnet")}, {S("capabilities"), QJsonObject{{S("optionDescriptors"), QJsonArray()}}}};
  offerProviders(world.mc, {QJsonObject{{S("instanceId"), S("claudeAgent")},
                                        {S("driver"), S("claudeAgent")},
                                        {S("displayName"), S("Claude")},
                                        {S("enabled"), true},
                                        {S("installed"), true},
                                        {S("status"), S("ready")},
                                        {S("models"), QJsonArray{model}}}});
  world.sync();
}

// The Background's thread holds a conversation, which the phone opened and
// so keeps; and a second thread it lists and never opened.
void seed(World& world) {
  Offline& state = offline(world);
  if (state.seeded || world.thread.isEmpty()) return;
  state.seeded = true;
  setEntity(world.mc, world.thread, S("run"), S("run-1"),
            {{S("id"), S("run-1")}, {S("ordinal"), 1}, {S("status"), S("completed")}, {S("requestedAt"), kNow}, {S("startedAt"), kNow}, {S("completedAt"), kNow}});
  setEntity(world.mc, world.thread, S("turn-item"), S("reply:run-1"),
            {{S("id"), S("reply:run-1")}, {S("type"), S("assistant_message")}, {S("runId"), S("run-1")}, {S("ordinal"), 2},
             {S("status"), S("completed")}, {S("text"), kLastSeen}, {S("updatedAt"), kNow}});
  offerClaude(world);
  // The screen the scenario is on stays.
  const QString shown = shownThread(world);
  // The thread list is under the thread screen.
  if (world.find(S("threadScreen")) != nullptr) {
    world.back();
    world.item(S("homeScreen"));
  }
  haveThread(world, kNeverOpened);
  threadRow(world, kNeverOpened);
  openThread(world, S("Fix checkout"));
  world.waitFor([&] { return world.shows(kLastSeen); }, [&] { return S("the conversation; the screen says: %1").arg(screen(world)); });
  if (shown == QLatin1String("Fix checkout")) return;
  world.back();
  world.item(S("homeScreen"));
  if (!shown.isEmpty()) openThread(world, shown);
}

bool connected(World& world) {
  return world.state(S("connection")).toMap().value(S("phase")) == QLatin1String("connected");
}

// The MC takes no connection and drops the one it has; the phone keeps
// trying on its own, not so often that the scenario is busy with it.
void goDown(World& world) {
  seed(world);
  client(world).setRetryDelays({200});
  world.mc.stopAccepting();
  world.mc.drop();
  world.waitFor([&] { return client(world).phase() == McClient::Phase::Retrying; },
                [&] { return S("a retry to be scheduled; the connection is %1").arg(show(world.state(S("connection")))); });
}

void comeBack(World& world) {
  offline(world).connections = world.mc.connections.size();
  world.mc.startAccepting();
  world.waitFor([&] { return world.mc.connections.size() > offline(world).connections && connected(world) && world.native().store()->synchronized(); },
                [&] { return S("the phone to reconnect; it is %1").arg(show(world.state(S("connection")))); });
}

void beInThread(World& world, const QString& title) {
  if (shownThread(world) != title) {
    if (world.find(S("threadScreen")) != nullptr) {
      world.back();
      world.item(S("homeScreen"));
    }
    openThread(world, title);
  }
}

QQuickItem* editor(World& world) {
  QQuickItem* input = world.item(S("input"));
  world.waitFor([&] { return input->isEnabled(); }, [&] { return S("the composer to take text; it is %1").arg(show(composerState(world))); });
  return input;
}

void typeInto(World& world, const QString& title, const QString& text) {
  beInThread(world, title);
  QQuickItem* input = editor(world);
  world.tap(input);
  const QString before = input->property("text").toString();
  world.type(text);
  expect(input->property("text").toString() == before + text, S("the composer reads %1").arg(input->property("text").toString()));
}

// The user writes `text` in `title` and taps send; with no connection it
// waits in the thread's outbox.
void send(World& world, const QString& title, const QString& text) {
  typeInto(world, title, text);
  const QVariantMap state = composerState(world);
  offline(world).model = state.value(S("selectedModel")).toString();
  offline(world).interactionMode = state.value(S("interactionMode")).toString();
  const qsizetype sent = sentTexts(world).size();
  world.tap(S("primaryAction"));
  // A send the composer itself refuses (a model that has not been set up)
  // is neither sent nor waiting: its toast is the outcome.
  const auto refused = [&world] {
    for (const QVariant& toast : world.state(S("toasts")).toMap().value(S("items")).toList()) {
      const QString title = toast.toMap().value(S("title")).toString();
      if (title == QLatin1String("Message not sent") || title == QLatin1String("Antigravity model unavailable")) return true;
    }
    return false;
  };
  world.waitFor([&] { return !waiting(world, text).isEmpty() || sentTexts(world).size() > sent || refused(); },
                [&] { return S("%1 to be sent or wait; the composer is %2, the outbox %3").arg(text, show(composerState(world)), show(outbox(world))); });
}

void sendOffline(World& world, const QString& title, const QString& text) {
  if (connected(world)) goDown(world);
  send(world, title, text);
  expect(!waiting(world, text).isEmpty(), S("%1 is not waiting; the outbox is %2").arg(text, show(outbox(world))));
}

void expectWaiting(World& world, const QString& text) {
  const QVariantMap entry = waiting(world, text);
  expect(!entry.isEmpty(), S("%1 is not waiting to send; the outbox is %2").arg(text, show(outbox(world))));
  QQuickItem* row = world.item(S("outboxText-") + entry.value(S("messageId")).toString());
  expect(row->property("text") == text, S("the outbox shows %1").arg(row->property("text").toString()));
}

void expectSent(World& world, const QString& text) {
  world.waitFor([&] { return sentTexts(world).contains(text); }, [&] { return S("%1 to be sent; the MC has %2").arg(text, sentTexts(world).join(S(", "))); });
  world.waitFor([&] { return waiting(world, text).isEmpty(); }, [&] { return S("%1 to leave the outbox; it is %2").arg(text, show(outbox(world))); });
}

// Every message the MC is sent, from now until stopped, drops the connection
// before it is answered.
void dropOnSend(World& world) {
  Offline& state = offline(world);
  state.dropping = true;
  if (state.dropsInstalled) return;
  state.dropsInstalled = true;
  world.mc.effects.append([&world](const QJsonObject& command) {
    if (offline(world).dropping && command.value(QLatin1String("type")) == QLatin1String("message.dispatch")) world.mc.drop();
  });
}

void watchRetries(World& world) {
  Offline& state = offline(world);
  if (std::exchange(state.watching, true)) return;
  QObject::connect(&composerController(world), &ComposerController::outboxRetryScheduled, &composerController(world),
                   [&state](const QString&, int delay) { state.retries.append(delay); });
}

void refuseMessages(World& world) {
  world.mc.refusals.insert(S("message.dispatch"), S("The thread is archived."));
}

const Steps steps([] {
  // Coming back to the app.
  step(S("the user switched away from the app for (5 seconds|a minute)"), [](World& world, const Captures& c, const Table&) {
    Resume& resume = world.app().resume();
    auto now = std::make_shared<qint64>(0);
    resume.setClock([now] { return *now; });
    watch(world);
    offline(world).connections = world.mc.connections.size();
    world.background();
    const bool long_ = c[0] == QLatin1String("a minute");
    if (long_) {
      // The agent answered meanwhile, in the thread the phone has open no more.
      setEntity(world.mc, world.thread, S("turn-item"), S("reply:away"),
                {{S("id"), S("reply:away")}, {S("type"), S("assistant_message")}, {S("ordinal"), 9},
                 {S("status"), S("completed")}, {S("text"), kWhileAway}, {S("updatedAt"), kNow}});
    }
    *now += long_ ? 60000 : 5000;
    expect(resume.threshold() == 10000, S("the phone replaces its connection after %1 ms away").arg(resume.threshold()));
  });
  step(S("the phone checks the existing connection instead of reconnecting"), [](World& world, const Captures&, const Table&) {
    const ConnectionWatch& watched = watch(world);
    world.waitFor([&] { return !watched.checks.isEmpty(); }, S("the connection to be checked"));
    world.sync();
    expect(watched.checks.last() && world.mc.connections.size() == offline(world).connections && connected(world),
           S("%1 connections, %2 before; the check found it %3").arg(world.mc.connections.size()).arg(offline(world).connections).arg(watched.checks.last() ? S("alive") : S("dead")));
  });
  step(S("the phone reconnects to %1").arg(kQuoted), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.mc.connections.size() > offline(world).connections && connected(world); },
                  [&] { return S("a new connection; there are %1 and it is %2").arg(world.mc.connections.size()).arg(show(world.state(S("connection")))); });
  });
  step(S("%1 catches up on what happened while the app was away").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    openThread(world, c[0]);
    world.waitFor([&] { return world.shows(kWhileAway); }, [&] { return S("what the agent said meanwhile; the screen says: %1").arg(screen(world)); });
  });

  // No connection.
  step(S("%1 is unreachable").arg(kQuoted), [](World& world, const Captures&, const Table&) { goDown(world); });
  step(S("the connection to %1 is lost").arg(kQuoted), [](World& world, const Captures&, const Table&) { goDown(world); });
  step(S("%1 becomes reachable").arg(kQuoted), [](World& world, const Captures&, const Table&) { comeBack(world); });
  step(S("the phone reconnects(?: and has the current thread list)?"), [](World& world, const Captures&, const Table&) { comeBack(world); });
  step(S("the last known conversation is shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.shows(kLastSeen); }, [&] { return S("the conversation the phone kept; the screen says: %1").arg(screen(world)); });
  });
  step(S("the user is told cached data remains available until the connection returns"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return !world.state(S("connection")).toMap().value(S("settling")).toBool(); }, S("the reconnect to be past its grace"));
    world.openConnectionNotice();
    expect(world.shows(S("What was loaded stays readable until the connection returns.")), S("the notice says: %1").arg(screen(world)));
  });
  step(S("the user opens a thread the phone has never loaded"), [](World& world, const Captures&, const Table&) { beInThread(world, kNeverOpened); });
  step(S("the user is told the app will keep retrying automatically"), [](World& world, const Captures&, const Table&) {
    // Something changed meanwhile, which the phone hears of once it is back.
    world.mc.threads.insert(S("thread-away"), {{S("id"), S("thread-away")},
                                               {S("title"), kStartedAway},
                                               {S("projectId"), S("shop")},
                                               {S("createdAt"), kNow},
                                               {S("updatedAt"), kNow}});
    world.waitFor([&] { return !world.state(S("connection")).toMap().value(S("settling")).toBool(); }, S("the reconnect to be past its grace"));
    world.openConnectionNotice();
    expect(world.shows(S("HAL-C2 keeps trying."), false), S("the notice says: %1").arg(screen(world)));
  });
  step(S("the thread list is current again without the user doing anything"), [](World& world, const Captures&, const Table&) {
    if (world.find(S("threadScreen")) != nullptr) world.back();
    threadRow(world, kStartedAway);
  });

  // Writing with no connection.
  step(S("the user sends %1 and then %1 in %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    send(world, c[2], c[0]);
    send(world, c[2], c[1]);
    expectWaiting(world, c[0]);
    expectWaiting(world, c[1]);
  });
  step(S("%1 is sent before %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expectSent(world, c[1]);
    const QStringList sent = sentTexts(world);
    expect(sent.indexOf(c[0]) >= 0 && sent.indexOf(c[0]) < sent.indexOf(c[1]), S("the MC was sent %1").arg(sent.join(S(", "))));
    expect(sent.count(c[0]) == 1 && sent.count(c[1]) == 1, S("the MC was sent %1").arg(sent.join(S(", "))));
  });
  step(S("the user sent %1 while offline").arg(kQuoted), [](World& world, const Captures& c, const Table&) { sendOffline(world, S("Fix checkout"), c[0]); });
  step(S("the user sent %1 (?:in|to) %1 while offline").arg(kQuoted), [](World& world, const Captures& c, const Table&) { sendOffline(world, c[1], c[0]); });
  step(S("the user sent %1 in %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    // With a connection, sent and not yet answered.
    if (connected(world)) world.mc.hold(S("answers"));
    send(world, c[1], c[0]);
  });
  step(S("the user sends %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) { send(world, S("Fix checkout"), c[0]); });
  step(S("the message is shown as waiting to send"), [](World& world, const Captures&, const Table&) {
    expect(outbox(world).size() == 1, S("the outbox is %1").arg(show(outbox(world))));
    const QString id = outbox(world).constFirst().toMap().value(S("messageId")).toString();
    QQuickItem* status = world.item(S("outboxStatus-") + id);
    expect(status->property("text") == QLatin1String("Waiting to send"), S("the outbox says %1").arg(status->property("text").toString()));
    expect(composerState(world).value(S("text")).toString().isEmpty(), S("the composer still holds %1").arg(composerState(world).value(S("text")).toString()));
  });
  step(S("the message is sent"), [](World& world, const Captures&, const Table&) { expectSent(world, S("add a test")); });
  step(S("%1 is sent").arg(kQuoted), [](World& world, const Captures& c, const Table&) { expectSent(world, c[0]); });
  step(S("the environment (?:rejects|refuses) %1 when the connection returns").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    refuseMessages(world);
    comeBack(world);
    world.waitFor([&] { return sentTexts(world).contains(c[0]); }, [&] { return S("%1 to reach the MC; it has %2").arg(c[0], sentTexts(world).join(S(", "))); });
  });
  step(S("%1 is no longer waiting to send").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return waiting(world, c[0]).isEmpty() && !savedUnsent(world).contains(c[0]); },
                  [&] { return S("%1 to leave the outbox; it is %2 and the phone keeps %3").arg(c[0], show(outbox(world)), savedUnsent(world).join(S(", "))); });
  });
  step(S("%1 is back in the draft of its thread, where the user can edit or delete it").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    QQuickItem* input = editor(world);
    world.waitFor([&] { return input->property("text").toString() == c[0]; }, [&] { return S("the draft; the composer reads %1").arg(input->property("text").toString()); });
    expect(composerState(world).value(S("canSend")).toBool(), S("the composer is %1").arg(show(composerState(world))));
  });
  step(S("the user has typed %1 in the draft of %1 since").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    // In another mode than the message was written in.
    world.bridge().dispatch(S("composer.interactionMode.set"), QVariantMap{{S("mode"), offline(world).interactionMode == QLatin1String("plan") ? S("default") : S("plan")}});
    world.sync();
    typeInto(world, c[1], c[0]);
  });
  step(S("the draft of %1 holds %1 together with %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    beInThread(world, c[0]);
    QQuickItem* input = editor(world);
    const QString both = c[1] + S("\n\n") + c[2];
    world.waitFor([&] { return input->property("text").toString() == both; }, [&] { return S("both in the draft; the composer reads %1").arg(input->property("text").toString()); });
  });
  step(S("the model and mode the message was sent with are restored with it"), [](World& world, const Captures&, const Table&) {
    const QVariantMap state = composerState(world);
    expect(state.value(S("selectedModel")) == offline(world).model && state.value(S("interactionMode")) == offline(world).interactionMode,
           S("the message was written on %1 in %2 mode; the composer is %3").arg(offline(world).model, offline(world).interactionMode, show(state)));
  });
  step(S("the user is told why it was refused"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.shows(S("Failed to send message")) && world.shows(S("The thread is archived.")); },
                  [&] { return S("the reason; the screen says: %1").arg(screen(world)); });
  });

  // Suspended and stopped.
  step(S("the user has typed %1 in %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) { typeInto(world, c[1], c[0]); });
  step(S("the system suspends and later terminates the app"), [](World& world, const Captures&, const Table&) {
    world.background();
    world.close();
  });
  step(S("the user opens the app again"), [](World& world, const Captures&, const Table&) { world.open(); });
  step(S("%1 is still waiting to send in %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.find(S("threadScreen")) != nullptr || world.find(S("homeScreen")) != nullptr; }, [&] { return S("a screen; it says %1").arg(screen(world)); });
    beInThread(world, c[1]);
    world.waitFor([&] { return !waiting(world, c[0]).isEmpty(); },
                  [&] { return S("%1 in the outbox; the turn is %2, the screen says %3, the phone keeps %4").arg(c[0], show(world.state(S("turn"))), screen(world), savedUnsent(world).join(S(", "))); });
    expectWaiting(world, c[0]);
    expect(sentTexts(world).isEmpty(), S("the MC was sent %1").arg(sentTexts(world).join(S(", "))));
  });

  // A connection that drops under a send.
  step(S("the connection to %1 drops before it answers").arg(kQuoted), [](World& world, const Captures&, const Table&) {
    watchRetries(world);
    offline(world).realDelays = composerController(world).outboxRetryDelays();
    composerController(world).setOutboxRetryDelays({20, 40, 80, 160});
    // And again each time the phone tries.
    dropOnSend(world);
    world.mc.dropHeld();
    world.mc.drop();
  });
  step(S("%1 (?:stays|keeps) waiting to send").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !waiting(world, c[0]).isEmpty(); }, [&] { return S("%1 in the outbox; it is %2").arg(c[0], show(outbox(world))); });
    expect(world.find(S("outboxText-") + waiting(world, c[0]).value(S("messageId")).toString()) != nullptr, S("the outbox does not show %1").arg(c[0]));
  });
  step(S("the phone tries again with a delay that grows up to 16 seconds"), [](World& world, const Captures&, const Table&) {
    const QList<int> expected{20, 40, 80, 160, 160};
    world.waitFor([&] { return offline(world).retries.size() >= expected.size(); },
                  [&] { return S("%1 retries; there were %2").arg(expected.size()).arg(offline(world).retries.size()); });
    offline(world).dropping = false;
    expect(offline(world).retries.mid(0, expected.size()) == expected, S("the delays were %1").arg(show(QVariant::fromValue(offline(world).retries))));
    // And what the phone waits for real.
    const QList<int> real = offline(world).realDelays;
    expect(real == QList<int>({1000, 2000, 4000, 8000, 16000}), S("the default delays are %1").arg(show(QVariant::fromValue(real))));
    // Once the connection holds, it goes.
    world.waitFor([&] { return waiting(world, S("add a test")).isEmpty(); }, [&] { return S("the message to go; the outbox is %1").arg(show(outbox(world))); });
    expect(sentTexts(world).last() == QLatin1String("add a test"), S("the MC was sent %1").arg(sentTexts(world).join(S(", "))));
  });

  // A thread gone meanwhile, and one the phone does not know the fate of yet.
  step(S("%1 was deleted from another device").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    const QString id = haveThread(world, c[0]);
    world.mc.threads.remove(id);
    if (world.find(S("threadScreen")) != nullptr) world.back();
  });
  // One thread's message the MC never answers: it went out, the connection
  // dropped under it (below), and it waits; the MC holds it again when it is back.
  step(S("%1 in %1 cannot be sent yet").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    seed(world);
    world.mc.hold(S("answers:") + haveThread(world, c[1]));
    send(world, c[1], c[0]);
  });
  // Another thread the phone lists, whose message waits for the connection.
  step(S("%1 is waiting in %1 on the same environment").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    haveThread(world, c[1]);
    beInThread(world, c[1]);
    sendOffline(world, c[1], c[0]);
  });
  step(S("the environment is connected"), [](World& world, const Captures&, const Table&) { comeBack(world); });

  step(S("%1 is not sent").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.sync();
    expect(!sentTexts(world).contains(c[0]), S("the MC was sent %1").arg(sentTexts(world).join(S(", "))));
  });
  step(S("%1 has reconnected but its thread list has not arrived").arg(kQuoted), [](World& world, const Captures&, const Table&) {
    world.mc.holdSnapshot = true;
    offline(world).connections = world.mc.connections.size();
    world.mc.startAccepting();
    world.waitFor([&] { return client(world).isReady(); }, S("the socket to open"));
    world.sync();
  });

  // Pulling a waiting message back.
  step(S("the user edits the waiting message"), [](World& world, const Captures&, const Table&) {
    expect(outbox(world).size() == 1, S("the outbox is %1").arg(show(outbox(world))));
    world.tap(S("outboxEdit-") + outbox(world).constFirst().toMap().value(S("messageId")).toString());
    world.sync();
  });
  step(S("%1 is in the composer of %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    beInThread(world, c[1]);
    QQuickItem* input = editor(world);
    world.waitFor([&] { return input->property("text").toString() == c[0]; }, [&] { return S("the composer reads %1").arg(input->property("text").toString()); });
    expect(composerState(world).value(S("selectedModel")) == offline(world).model, S("the composer is %1").arg(show(composerState(world))));
  });
  step(S("the phone is sending %1 to %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    sendOffline(world, S("Fix checkout"), c[0]);
    world.mc.hold(S("answers"));
    comeBack(world);
    world.waitFor([&] { return sentTexts(world).contains(c[0]); }, [&] { return S("%1 to reach the MC; it has %2").arg(c[0], sentTexts(world).join(S(", "))); });
    world.waitFor([&] { return waiting(world, c[0]).value(S("sending")).toBool(); }, [&] { return S("%1 to be sending; the outbox is %2").arg(c[0], show(outbox(world))); });
  });
  step(S("the user tries to edit it"), [](World& world, const Captures&, const Table&) {
    const QString id = outbox(world).constFirst().toMap().value(S("messageId")).toString();
    QQuickItem* edit = world.item(S("outboxEdit-") + id);
    expect(!edit->isEnabled(), S("the outbox offers to edit a message on its way"));
    world.bridge().dispatch(S("composer.outbox.edit"), QVariantMap{{S("messageId"), id}});
    world.sync();
  });
  step(S("nothing changes"), [](World& world, const Captures&, const Table&) {
    expect(outbox(world).size() == 1 && outbox(world).constFirst().toMap().value(S("sending")).toBool(), S("the outbox is %1").arg(show(outbox(world))));
    expect(composerState(world).value(S("text")).toString().isEmpty(), S("the composer is %1").arg(show(composerState(world))));
  });
  step(S("%1 is delivered once").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.mc.answerHeld();
    world.waitFor([&] { return outbox(world).isEmpty(); }, [&] { return S("the outbox to empty; it is %1").arg(show(outbox(world))); });
    expect(sentTexts(world).count(c[0]) == 1, S("the MC was sent %1").arg(sentTexts(world).join(S(", "))));
  });

  // The composer's send control.
  step(S("the agent is idle but the message must wait for a connection"), [](World& world, const Captures&, const Table&) { goDown(world); });
});

}  // namespace
