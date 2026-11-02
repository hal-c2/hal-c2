// The agent's tool calls in a thread's activity log on the phone
// (features/timeline/tool-calls.feature): groups that read as a summary and
// open into their calls, how a call is named and ended, the one live row of a
// running turn, a long press that copies, and the rows the phone leaves out
// or keeps apart. The stream is ComposerSteps' fake (FakeThreads.h), written
// as the desktop's Stream.h writes it; the rows are read from the open
// thread's TimelineModel and from the phone's own screen drawing it.

#include <QBuffer>
#include <QImage>
#include <QJsonArray>
#include <QJsonObject>
#include <QLocale>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QTcpSocket>

#include <cmath>
#include <functional>

#include "FakeThreads.h"
#include "Harness.h"
#include "NativeShell.h"
#include "Phone.h"
#include "ThreadStore.h"
#include "TimelineModel.h"
#include "World.h"

namespace {

using S = QString;

const QString kTitle = QStringLiteral("Tax line");
const QString kRoot = QStringLiteral("/work/shop");
const QString kSend = QStringLiteral("mcp__hal-c2__hal_c2_thread_send");
const QDateTime kNow = QDateTime::fromString(QStringLiteral("2026-09-23T10:00:00Z"), Qt::ISODate);

// What the steps keep of the turn they write.
struct FakeTurn {
  QDateTime started;
  QStringList changedFiles;
  bool viewedImage = false;
};

S iso(const QDateTime& time) {
  return time.toUTC().toString(Qt::ISODate);
}

void change(World& world, const S& kind, const S& id, const QJsonObject& patch) {
  changeEntity(world.mc, world.thread, kind, id, patch);
  world.sync();
}

void set(World& world, const S& kind, const S& id, const QJsonObject& fields) {
  change(world, kind, id, {{S("s"), fields}});
}

// A new run of the thread, started `since` seconds ago, with the user message
// that asked for it, and the thread's row saying it runs.
S startRun(World& world, int since = 0) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
  world.run = S("run-%1").arg(fake.ordinal + 1);
  world.mc.part<FakeTurn>().started = kNow.addSecs(-since);
  set(world, S("run"), world.run,
      {{S("id"), world.run}, {S("ordinal"), ++fake.ordinal}, {S("status"), S("running")},
       {S("requestedAt"), iso(kNow.addSecs(-since))}, {S("startedAt"), iso(kNow.addSecs(-since))}});
  set(world, S("turn-item"), S("message:") + world.run,
      {{S("id"), S("message:") + world.run}, {S("type"), S("user_message")}, {S("runId"), world.run}, {S("ordinal"), ++fake.ordinal},
       {S("status"), S("completed")}, {S("text"), S("Add a tax line to the cart")}, {S("updatedAt"), iso(kNow.addSecs(-since))}});
  updateRow(world.mc, world.thread, {{S("activeRunId"), world.run}, {S("latestRunId"), world.run}});
  world.sync();
  return world.run;
}

// A turn item of the run; `fields` adds to and overrides the defaults.
S addItem(World& world, const S& type, const QJsonObject& fields = {}) {
  FakeStreams& fake = world.mc.part<FakeStreams>();
  QJsonObject item{{S("id"), S("%1:%2").arg(type).arg(fake.ordinal + 1)}, {S("type"), type}, {S("runId"), world.run},
                   {S("ordinal"), ++fake.ordinal}, {S("status"), S("completed")}, {S("updatedAt"), iso(kNow)}};
  for (auto it = fields.begin(); it != fields.end(); ++it) item.insert(it.key(), it.value());
  const S id = item.value(QLatin1String("id")).toString();
  set(world, S("turn-item"), id, item);
  return id;
}

S addCommand(World& world, int n, const S& status = S("completed")) {
  QJsonObject fields{{S("input"), S("bun test cart-%1").arg(n)}, {S("status"), status}};
  if (status == QLatin1String("completed")) fields.insert(S("exitCode"), 0);
  if (status == QLatin1String("failed")) fields.insert(S("exitCode"), 1);
  return addItem(world, S("command_execution"), fields);
}

void settleRun(World& world, const S& status, int after) {
  set(world, S("run"), world.run, {{S("status"), status}, {S("completedAt"), iso(world.mc.part<FakeTurn>().started.addSecs(after))}});
  updateRow(world.mc, world.thread, {{S("activeRunId"), QJsonValue::Null}});
  world.sync();
}

// The turn's reply, and its end: the work folds behind how long it took.
void finishTurn(World& world) {
  addItem(world, S("assistant_message"), {{S("text"), S("Done.")}});
  settleRun(world, S("completed"), 30);
}

TimelineModel& timeline(World& world) {
  TimelineModel* model = world.native().controller<ThreadStore>()->activeTimeline();
  if (!model) fail(S("no thread is open"));
  return *model;
}

QVariant role(TimelineModel& model, int row, int role) {
  return model.data(model.index(row), role);
}

S describe(TimelineModel& model) {
  QStringList rows;
  for (int row = 0; row < model.rowCount(); ++row) {
    rows.append(S("%1 %2 \"%3\" %4")
                    .arg(role(model, row, TimelineModel::KindRole).toString(), role(model, row, TimelineModel::IdRole).toString(),
                         role(model, row, TimelineModel::TitleRole).toString(), show(role(model, row, TimelineModel::EntriesRole))));
  }
  return S("rows: %1").arg(rows.isEmpty() ? S("(none)") : rows.join(S("; ")));
}

QList<int> rowsOf(TimelineModel& model, const S& kind) {
  QList<int> rows;
  for (int row = 0; row < model.rowCount(); ++row) {
    if (role(model, row, TimelineModel::KindRole).toString() == kind) rows.append(row);
  }
  return rows;
}

int lastRowOf(World& world, const S& kind) {
  TimelineModel& model = timeline(world);
  const QList<int> rows = rowsOf(model, kind);
  if (rows.isEmpty()) fail(S("no %1 row; %2").arg(kind, describe(model)));
  return rows.last();
}

QVariantList entries(World& world) {
  return role(timeline(world), lastRowOf(world, S("work")), TimelineModel::EntriesRole).toList();
}

S summary(World& world) {
  return role(timeline(world), lastRowOf(world, S("work")), TimelineModel::SummaryRole).toString();
}

// What the group's line reads: its summary, or a lone call's own label.
S groupLine(World& world) {
  const S text = summary(world);
  const QVariantList shown = entries(world);
  return !text.isEmpty() || shown.size() != 1 ? text : shown.first().toMap().value(S("label")).toString();
}

QVariantMap lastCall(World& world) {
  const QVariantList shown = entries(world);
  if (shown.isEmpty()) fail(S("the group shows no call; %1").arg(describe(timeline(world))));
  return shown.last().toMap();
}

void openFold(World& world) {
  TimelineModel& model = timeline(world);
  const int fold = lastRowOf(world, S("fold"));
  if (!role(model, fold, TimelineModel::ExpandedRole).toBool()) model.toggle(role(model, fold, TimelineModel::IdRole).toString());
}

void collect(QQuickItem* item, const S& name, QList<QQuickItem*>& out) {
  if (item->objectName() == name && item->isVisible()) out.append(item);
  for (QQuickItem* child : item->childItems()) collect(child, name, out);
}

// The visible items named `name` the phone draws.
QList<QQuickItem*> drawnAll(World& world, const S& name) {
  QList<QQuickItem*> items;
  collect(world.window().contentItem(), name, items);
  return items;
}

// The one drawn lowest that `matches`, waited for.
QQuickItem* drawn(World& world, const S& name, const std::function<bool(QQuickItem*)>& matches = [](QQuickItem*) { return true; }) {
  QQuickItem* found = nullptr;
  world.waitFor([&] {
    found = nullptr;
    for (QQuickItem* item : drawnAll(world, name)) {
      if (matches(item) && (!found || item->mapToScene(QPointF()).y() >= found->mapToScene(QPointF()).y())) found = item;
    }
    return found != nullptr;
  }, [&] { return S("the phone to draw %1; it shows %2").arg(name, world.texts().join(S(" | "))); });
  return found;
}

void expectDrawn(World& world, const S& text) {
  world.waitFor([&] { return world.shows(text); }, [&] { return S("the phone to show \"%1\"; it shows %2").arg(text, world.texts().join(S(" | "))); });
}

// The texts a visible item shows, in the order drawn.
QStringList textsOf(const QQuickItem* item) {
  QStringList texts;
  if (!item->isVisible()) return texts;
  if (const S text = item->property("text").toString(); !text.isEmpty()) texts.append(text);
  for (const QQuickItem* child : item->childItems()) texts.append(textsOf(child));
  return texts;
}

// The drawn line of the call `id`.
QQuickItem* callLine(World& world, const S& id) {
  return drawn(world, S("workCall"), [&](QQuickItem* item) {
    QObject* data = item->parentItem() ? item->parentItem()->property("modelData").value<QObject*>() : nullptr;
    const QVariant value = item->parentItem() ? item->parentItem()->property("modelData") : QVariant();
    return (data && data->property("id") == id) || value.toMap().value(S("id")) == id;
  });
}

void sendMessage(World& world, const S& thread, int n, bool failed = false) {
  QJsonObject fields{{S("toolName"), kSend}, {S("input"), QJsonObject{{S("threadId"), thread}, {S("message"), S("Check the tax line")}}}};
  if (failed) {
    // An MCP error comes back as the call's result, the call itself completed.
    fields.insert(S("output"), QJsonObject{{S("isError"), true},
                                          {S("content"), QJsonArray{QJsonObject{{S("type"), S("text")}, {S("text"), S("thread not found")}}}}});
  } else {
    fields.insert(S("output"), QJsonObject{{S("structuredContent"), QJsonObject{{S("threadId"), thread}, {S("messageId"), S("message-%1").arg(n)}}}});
  }
  addItem(world, S("dynamic_tool"), fields);
}

// A "quoted" step argument whose \" and \\ are escapes, as an example table writes a command.
const QString kEscaped = QStringLiteral(R"re("((?:[^"\\]|\\.)*)")re");
S unescaped(const S& quoted) {
  static const QRegularExpression escape(QStringLiteral(R"(\\(.))"));
  return S(quoted).replace(escape, S("\\1"));
}

// A call to one of HAL-C2's own tools, as Codex names it, that returned `result`.
QJsonObject halC2Call(const S& tool, const QJsonObject& input, const QJsonObject& result = {}) {
  return {{S("toolName"), S("mcp__hal-c2__") + tool}, {S("input"), input}, {S("output"), QJsonObject{{S("structuredContent"), result}}}};
}

// A call through a browser, the computer or an integration, as the MC names it (codex/tool_presentation.ex).
QJsonObject sourcedCall(const S& key, const S& name, const S& kind) {
  return {{S("toolName"), S("mcp__%1__navigate").arg(key)}, {S("toolSource"), QJsonObject{{S("key"), key}, {S("name"), name}, {S("kind"), kind}}}};
}

// The calls an activity group holds, by how a scenario describes them.
void addCalls(World& world, const S& calls) {
  const auto tool = [&](const QJsonObject& fields) { addItem(world, S("dynamic_tool"), fields); };
  const auto edit = [&](const S& file) { addItem(world, S("file_change"), {{S("fileName"), file}}); };
  const auto web = [&] { addItem(world, S("web_search"), {{S("patterns"), QJsonArray{S("vat rates")}}}); };
  const auto thought = [&] { addItem(world, S("reasoning"), {{S("text"), S()}}); };
  const auto integration = [&](const S& name) { tool(sourcedCall(name.toLower(), name, S("integration"))); };
  const QHash<S, std::function<void()>> known{
      {S("two thoughts and one command"), [&] {
         thought();
         thought();
         addCommand(world, 1);
       }},
      {S("one thought"), thought},
      {S("three thoughts"), [&] {
         for (int n = 0; n < 3; ++n) thought();
       }},
      {S("two calls through the \"Chrome\" integration and one command"), [&] {
         integration(S("Chrome"));
         integration(S("Chrome"));
         addCommand(world, 1);
       }},
      {S("calls through the \"Chrome\" and \"Slack\" integrations"), [&] {
         integration(S("Chrome"));
         integration(S("Slack"));
       }},
      {S("calls through the \"Chrome\", \"Slack\" and \"Linear\" integrations"), [&] {
         integration(S("Chrome"));
         integration(S("Slack"));
         integration(S("Linear"));
       }},
      {S("calls through the built-in browser and computer controls"), [&] {
         tool(sourcedCall(S("browser"), S("Browser"), S("browser")));
         tool(sourcedCall(S("computer"), S("Computer Use"), S("computer")));
       }},
      {S("commands, file changes and four web searches"), [&] {
         addCommand(world, 1);
         addCommand(world, 2);
         edit(S("src/cart.ts"));
         for (int n = 0; n < 4; ++n) web();
       }},
      {S("two attempts to send a message that both failed"), [&] {
         // Neither said which thread it was for.
         for (int n = 0; n < 2; ++n) {
           tool({{S("toolName"), kSend}, {S("status"), S("failed")}, {S("input"), QJsonObject{{S("message"), S("Check the tax line")}}}});
         }
       }},
      {S("a command that exited with a failure"), [&] {
         addCommand(world, 1);
         addItem(world, S("command_execution"), {{S("input"), S("bun lint")}, {S("exitCode"), 2}});
       }},
  };
  const auto found = known.constFind(calls);
  if (found == known.cend()) fail(S("no calls described as \"%1\"").arg(calls));
  (*found)();
}

// An image's bytes, as the MC serves a workspace file.
QByteArray picture() {
  QImage image(40, 20, QImage::Format_RGB32);
  image.fill(Qt::darkCyan);
  QByteArray bytes;
  QBuffer buffer(&bytes);
  buffer.open(QIODevice::WriteOnly);
  image.save(&buffer, "PNG");
  return bytes;
}

// `assets.createUrl` for a thread's workspace file, and the file behind it.
void serveWorkspaceFiles(World& world) {
  world.mc.onRpc(S("assets.createUrl"), [&mc = world.mc](const FakeMc::Rpc& rpc) {
    const S path = rpc.payload.value(QLatin1String("resource")).toObject().value(QLatin1String("path")).toString();
    mc.reply(rpc, QJsonObject{{S("relativeUrl"), S("/api/assets/workspace/") + path}, {S("expiresAt"), double(QDateTime::currentDateTimeUtc().addSecs(3600).toMSecsSinceEpoch())}});
  });
  world.mc.onRaw(S("/api/assets/workspace/"), [](QTcpSocket* socket, const QByteArray& head) {
    socket->read(head.size());
    const QByteArray body = picture();
    socket->write("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: image/png\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\n\r\n" + body);
    socket->disconnectFromHost();
  });
}

// The workspace files the phone asked the MC to sign.
QList<QJsonObject> signedFiles(World& world) {
  QList<QJsonObject> files;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    const QJsonObject resource = rpc.payload.value(QLatin1String("resource")).toObject();
    if (rpc.method == QLatin1String("assets.createUrl") && resource.value(QLatin1String("_tag")).toString().endsWith(QLatin1String("-file"))) files.append(resource);
  }
  return files;
}

// The open group's window of calls.
QQuickItem* callsView(World& world) {
  return drawn(world, S("workCalls"), [](QQuickItem* item) { return item->property("interactive").toBool(); });
}

double endOf(QQuickItem* view) {
  return view->property("contentHeight").toDouble() - view->height();
}

int callCount(World& world) {
  TimelineModel& model = timeline(world);
  for (int row = model.rowCount() - 1; row >= 0; --row) {
    if (role(model, row, TimelineModel::KindRole) == QLatin1String("work")) return role(model, row, TimelineModel::EntriesRole).toList().size();
  }
  return 0;
}

// Opens the newest group's every call, as the user taps its toggle.
void openGroup(World& world, int calls) {
  world.tap(drawn(world, S("workGroupToggle")));
  world.waitFor([&] { return callCount(world) == calls; }, [&] { return S("the group to open; %1").arg(describe(timeline(world))); });
}

// A failure that failed the turn: the provider's error item.
S addFailure(World& world, const QJsonObject& failure) {
  return addItem(world, S("error"), {{S("status"), S("failed")}, {S("failure"), failure}});
}

// The work rows' ids, in order, and the rows between the first two of them.
QList<int> workRows(World& world) {
  return rowsOf(timeline(world), S("work"));
}

// The phone's error row drawn for the turn's failure.
QQuickItem* failureRow(World& world) {
  return drawn(world, S("errorLine"));
}

}  // namespace

// The image the agent viewed, loaded from the thread's workspace, when a
// scenario's call viewed one; FilesSteps' "the image is shown" asks first.
bool expectViewedImage(World& world) {
  if (!world.mc.part<FakeTurn>().viewedImage) return false;
  world.waitFor([&] {
    const QList<QQuickItem*> images = drawnAll(world, S("viewedImage"));
    return !images.isEmpty() && images.first()->property("status").toInt() == 1 && images.first()->height() > 0;
  }, [&] { return S("the image to load; the phone signed %1 and draws %2 (%3)").arg(signedFiles(world).size()).arg(drawnAll(world, S("viewedImage")).size()).arg(drawnAll(world, S("viewedImage")).isEmpty() ? S() : S("%1 status %2 height %3").arg(drawnAll(world, S("viewedImage")).first()->property("source").toString()).arg(drawnAll(world, S("viewedImage")).first()->property("status").toInt()).arg(drawnAll(world, S("viewedImage")).first()->height())); });
  const QList<QJsonObject> files = signedFiles(world);
  expect(files.size() == 1 && files.first().value(QLatin1String("_tag")) == QLatin1String("workspace-file") &&
             files.first().value(QLatin1String("path")) == QLatin1String("assets/logo.png") && files.first().value(QLatin1String("threadId")) == world.thread,
         S("the phone signed %1 files").arg(files.size()));
  return true;
}

namespace {

const Steps steps([] {
  const QString q = kQuoted;

  step(S("the user is looking at a thread in %1").arg(q), [](World& world, const Captures&, const Table&) {
    world.thread = haveThread(world, kTitle);
    openThread(world, kTitle);
    world.waitFor([&] { return world.native().controller<ThreadStore>()->activeTimeline() && timeline(world).status() == QLatin1String("live"); },
                  S("the thread to follow its MC"));
  });

  // Progress on a call already shown, while the agent writes.
  step(S("the agent is writing a message"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addItem(world, S("command_execution"), {{S("id"), S("command:dev")}, {S("input"), S("npm run dev")}, {S("status"), S("running")}});
    addItem(world, S("assistant_message"), {{S("id"), S("reply")}, {S("streaming"), true}, {S("status"), S("running")}, {S("text"), S("| Item | Tax |\n|---|---|\n")}});
  });
  step(S("a command it started in the background reports progress in the middle of the message"), [](World& world, const Captures&, const Table&) {
    change(world, S("turn-item"), S("command:dev"), {{S("a"), QJsonObject{{S("output"), S("ready on :3000\n")}}}});
    change(world, S("turn-item"), S("reply"), {{S("a"), QJsonObject{{S("text"), S("| Cart | 2.50 |")}}}});
  });
  step(S("the message stays one message"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const QList<int> messages = rowsOf(model, S("message"));
    int replies = 0;
    for (const int row : messages) replies += role(model, row, TimelineModel::TextRole).toString().contains(QLatin1String("| Item | Tax |")) ? 1 : 0;
    expect(replies == 1 && messages.last() == model.rowCount() - 1, S("the reply is split; %1").arg(describe(model)));
  });
  step(S("the text the agent writes after the progress is part of it"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const S text = role(model, rowsOf(model, S("message")).last(), TimelineModel::TextRole).toString();
    expect(text.contains(QLatin1String("| Item | Tax |")) && text.contains(QLatin1String("| Cart | 2.50 |")), S("the reply reads \"%1\"").arg(text));
  });

  // The running turn's calls: the latest, and the previous behind a count.
  step(S("the agent has run five tool calls in a row in the running turn"), [](World& world, const Captures&, const Table&) {
    startRun(world);
    for (int n = 1; n <= 5; ++n) addCommand(world, n);
  });
  step(S("the latest tool call is shown"), [](World& world, const Captures&, const Table&) {
    const S command = lastCall(world).value(S("command")).toString();
    expect(command == QLatin1String("bun test cart-5"), S("the call shown is \"%1\"").arg(command));
    expect(drawnAll(world, S("workCall")).size() == 1, S("the phone draws %1 calls").arg(drawnAll(world, S("workCall")).size()));
  });
  step(S("the other four are behind %1").arg(q), [](World& world, const Captures& c, const Table&) {
    TimelineModel& model = timeline(world);
    const int work = lastRowOf(world, S("work"));
    const int hidden = role(model, work, TimelineModel::HiddenCountRole).toInt();
    const int shown = role(model, work, TimelineModel::EntriesRole).toList().size();
    expect(S("+%1 previous tool calls").arg(hidden) == c[0] && shown == 1, S("%1 calls are shown, %2 behind; %3").arg(shown).arg(hidden).arg(describe(model)));
    expectDrawn(world, c[0]);
  });
  const auto toggleGroup = [](World& world, const Captures&, const Table&) { world.tap(drawn(world, S("workGroupToggle"))); };
  step(S("the user shows the previous tool calls"), toggleGroup);
  step(S("the user hides them again"), toggleGroup);
  step(S("all five tool calls are shown"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return entries(world).size() == 5 && drawnAll(world, S("workCall")).size() == 5; },
                  [&] { return S("all five calls; %1").arg(describe(timeline(world))); });
  });

  // Summaries.
  step(S("the agent ran two commands and sent messages to three threads"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addCommand(world, 1);
    addCommand(world, 2);
    for (int n = 1; n <= 3; ++n) sendMessage(world, S("thread-%1").arg(n + 1), n);
    finishTurn(world);
  });
  step(S("the agent ran commands, changed files, searched the web and read files"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addItem(world, S("dynamic_tool"), {{S("toolName"), S("Read")}, {S("input"), QJsonObject{{S("path"), S("src/cart.ts")}}}});
    addItem(world, S("web_search"), {{S("patterns"), QJsonArray{S("vat rates")}}});
    addCommand(world, 1);
    addCommand(world, 2);
    addItem(world, S("file_change"), {{S("fileName"), S("src/cart.ts")}});
    finishTurn(world);
  });
  step(S("the agent sent three messages and one of them failed"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    sendMessage(world, S("thread-2"), 1);
    sendMessage(world, S("thread-2"), 2, true);
    sendMessage(world, S("thread-2"), 3);
    finishTurn(world);
  });
  step(S("the activity group holds (.+)"), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addCalls(world, c[0]);
    finishTurn(world);
  });
  step(S("the user reads the activity group"), [](World& world, const Captures&, const Table&) {
    openFold(world);
    // Collapsed, the group is its summary alone; a lone call is its own line.
    const QVariantList shown = entries(world);
    expect(shown.isEmpty() || role(timeline(world), lastRowOf(world, S("work")), TimelineModel::HiddenCountRole).toInt() == 0,
           S("the collapsed group shows %1").arg(show(shown)));
  });
  step(S("it reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(groupLine(world) == c[0], S("the group reads \"%1\"").arg(groupLine(world)));
    expectDrawn(world, c[0]);
  });
  step(S("the summary names commands and file changes"), [](World& world, const Captures&, const Table&) {
    const S text = summary(world);
    expect(text.startsWith(QLatin1String("Ran 2 commands, changed 1 file")), S("the group reads \"%1\"").arg(text));
  });
  step(S("it counts the rest instead of naming them"), [](World& world, const Captures&, const Table&) {
    const S text = summary(world);
    expect(text == QLatin1String("Ran 2 commands, changed 1 file, and performed 2 other actions"), S("the group reads \"%1\"").arg(text));
    expectDrawn(world, text);
  });
  step(S("it ends with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The count ends a sentence that starts with what was named.
    const S text = summary(world);
    expect(text.endsWith(c[0], Qt::CaseInsensitive), S("the group reads \"%1\"").arg(text));
    expectDrawn(world, text);
  });
  step(S("the summary counts two messages sent"), [](World& world, const Captures&, const Table&) {
    const S text = summary(world);
    expect(text == QLatin1String("Sent 2 messages to 1 thread"), S("the group reads \"%1\"").arg(text));
    expect(role(timeline(world), lastRowOf(world, S("work")), TimelineModel::SummaryFailedRole).toBool(), S("the group does not say a call failed"));
  });
  step(S("the group is marked as having a failure"), [](World& world, const Captures&, const Table&) {
    expect(role(timeline(world), lastRowOf(world, S("work")), TimelineModel::SummaryFailedRole).toBool(),
           S("the group \"%1\" is not marked failed").arg(summary(world)));
  });

  // A call's failure the provider did not report.
  step(S("the provider reported a HAL-C2 tool call as completed"), [](World& world, const Captures&, const Table&) { startRun(world, 30); });
  step(S("the tool's answer says it is an error"), [](World& world, const Captures&, const Table&) {
    sendMessage(world, S("thread-2"), 1, true);
    finishTurn(world);
  });
  step(S("the provider reported a command as completed"), [](World& world, const Captures&, const Table&) { startRun(world, 30); });
  step(S("the command's output says %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The wire carries only what the MC made of the output (orchestration/command_output.ex).
    QJsonObject fields{{S("input"), S("npm test")}, {S("status"), S("completed")}};
    if (c[0] != QLatin1String("exited with exit code 0")) fields.insert(S("outputIndicatesFailure"), true);
    addItem(world, S("command_execution"), fields);
    finishTurn(world);
  });
  step(S("the (?:call|command) is shown as (failed|succeeded)"), [](World& world, const Captures& c, const Table&) {
    const QVariantMap call = lastCall(world);
    const bool failed = c[0] == QLatin1String("failed");
    expect(call.value(S("status")) == QLatin1String("completed") && call.value(S("statusLabel")) == (failed ? S("Failed") : S()),
           S("the call is %1").arg(show(call)));
    world.waitFor([&] { return world.shows(call.value(S("label")).toString()) && world.shows(S("Failed")) == failed; },
                  [&] { return S("the phone to draw the call as %1; it shows %2").arg(c[0], world.texts().join(S(" | "))); });
  });

  // An ACP agent's read, search and fetch, as the MC projects them (acp/thread_runtime.ex tool_kind).
  step(S("an ACP agent's tool call is of kind %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world);
    if (c[0] == QLatin1String("read")) {
      addItem(world, S("file_search"), {{S("pattern"), S("src/app.ts")}, {S("results"), QJsonArray{QJsonObject{{S("fileName"), S("src/app.ts")}}}}});
    } else if (c[0] == QLatin1String("search")) {
      addItem(world, S("file_search"), {{S("pattern"), S("TODO")}});
    } else if (c[0] == QLatin1String("fetch")) {
      addItem(world, S("web_search"), {{S("patterns"), QJsonArray{S("https://example.com/docs")}}});
    } else {
      fail(S("unknown ACP tool kind: %1").arg(c[0]));
    }
  });
  step(S("the MC projects the call"), [](World& world, const Captures&, const Table&) {
    expect(entries(world).size() == 1, S("the timeline shows %1").arg(describe(timeline(world))));
  });
  step(S("the timeline shows it as (a file read|a file search|a web search)"), [](World& world, const Captures& c, const Table&) {
    const QHash<S, QStringList> shown{
        {S("a file read"), {S("Read file"), S("eye"), S("src/app.ts")}},
        {S("a file search"), {S("Searched files"), S("search"), S("TODO")}},
        {S("a web search"), {S("Searched the web"), S("globe"), S("https://example.com/docs")}},
    };
    const QStringList want = shown.value(c[0]);
    const QVariantMap call = lastCall(world);
    expect(call.value(S("label")) == want.at(0) && call.value(S("icon")) == want.at(1) && call.value(S("detail")) == want.at(2), S("the call is shown as %1").arg(show(call)));
    expectDrawn(world, want.at(0));
  });

  // How a call is named.
  const auto callTool = [](World& world, const S& name) {
    startRun(world, 30);
    addItem(world, S("dynamic_tool"), {{S("toolName"), name}, {S("input"), QJsonObject{{S("threadId"), S("thread-2")}}}});
    finishTurn(world);
    openFold(world);
  };
  step(S("the agent called HAL-C2's %1 tool").arg(q), [callTool](World& world, const Captures& c, const Table&) { callTool(world, S("mcp__hal-c2__") + c[0]); });
  step(S("the agent called HAL-C2's thread-reading tool and the provider named it %1").arg(q),
       [callTool](World& world, const Captures& c, const Table&) { callTool(world, c[0]); });
  step(S("the agent called a tool named %1").arg(q), [callTool](World& world, const Captures& c, const Table&) { callTool(world, c[0]); });
  step(S("the call reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const S label = lastCall(world).value(S("label")).toString();
    expect(label == c[0], S("the call reads \"%1\"").arg(label));
    expectDrawn(world, c[0]);
  });
  step(S("the call is shown as an ordinary tool call"), [](World& world, const Captures&, const Table&) {
    const S label = lastCall(world).value(S("label")).toString();
    expect(label == QLatin1String("mcp__other-server__hal_c2_thread_read"), S("the call reads \"%1\"").arg(label));
    expectDrawn(world, label);
  });
  step(S("it does not carry HAL-C2's name for the tool"), [](World& world, const Captures&, const Table&) {
    expect(!world.shows(S("Read a HAL-C2 thread")), S("the call carries HAL-C2's name"));
  });

  // Opening a group.
  step(S("a collapsed group of tool calls"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addItem(world, S("command_execution"), {{S("input"), S("bun test cart")}, {S("exitCode"), 0}});
    addItem(world, S("command_execution"), {{S("input"), S("bun lint")}, {S("status"), S("failed")}, {S("exitCode"), 2}});
    sendMessage(world, S("thread-2"), 1);
    finishTurn(world);
    openFold(world);
    expect(entries(world).isEmpty() && !summary(world).isEmpty(), S("the group is not collapsed; %1").arg(describe(timeline(world))));
  });
  step(S("the user opens the group"), toggleGroup);
  step(S("the user closes the group"), toggleGroup);
  step(S("each call shows its command or input, its status and its exit code"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return entries(world).size() == 3; }, [&] { return S("the group to open; %1").arg(describe(timeline(world))); });
    const QVariantList calls = entries(world);
    const QVariantMap passed = calls.at(0).toMap();
    const QVariantMap failed = calls.at(1).toMap();
    const QVariantMap sent = calls.at(2).toMap();
    expect(passed.value(S("command")) == QLatin1String("bun test cart") && passed.value(S("status")) == QLatin1String("completed") && passed.value(S("exitCode")) == 0,
           S("the first call is %1").arg(show(passed)));
    expect(failed.value(S("command")) == QLatin1String("bun lint") && failed.value(S("statusLabel")) == QLatin1String("Failed") && failed.value(S("exitCode")) == 2,
           S("the second call is %1").arg(show(failed)));
    expect(sent.value(S("detail")).toString().contains(QLatin1String("\"threadId\": \"thread-2\"")) && sent.value(S("status")) == QLatin1String("completed") &&
               !sent.contains(S("exitCode")),
           S("the third call is %1").arg(show(sent)));
    // As drawn: the failed call says so, and a tapped call shows its command and exit code.
    expectDrawn(world, S("Failed"));
    world.tap(callLine(world, failed.value(S("id")).toString()));
    world.waitFor([&] { return world.shows(S("$ bun lint")) && world.shows(S("Process exited with code 2")); },
                  [&] { return S("the call's command and exit code; the phone shows %1").arg(world.texts().join(S(" | "))); });
  });
  step(S("the calls collapse back into the summary"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return entries(world).isEmpty(); }, [&] { return S("the group to close; %1").arg(describe(timeline(world))); });
    const S text = summary(world);
    expect(text == QLatin1String("Ran 2 commands and sent 1 message to 1 thread"), S("the group reads \"%1\"").arg(text));
    world.waitFor([&] { return world.shows(text) && !world.shows(S("$ bun lint")); }, S("the phone to draw only the summary"));
  });

  // What a call is labelled by.
  step(S("the agent ran %1 through a shell and changed a file in the workspace").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addItem(world, S("command_execution"), {{S("input"), S("bash -lc '%1'").arg(c[0])}, {S("exitCode"), 0}});
    addItem(world, S("file_change"), {{S("fileName"), kRoot + S("/src/cart.ts")}});
    finishTurn(world);
    openFold(world);
  });
  step(S("the user opens the activity group"), [](World& world, const Captures&, const Table&) {
    world.tap(drawn(world, S("workGroupToggle")));
    world.waitFor([&] { return entries(world).size() == 2; }, [&] { return S("the group to open; %1").arg(describe(timeline(world))); });
  });
  step(S("the command is labelled %1 and the file change %2").arg(q, q), [](World& world, const Captures& c, const Table&) {
    const QVariantList calls = entries(world);
    expect(calls.at(0).toMap().value(S("label")) == c[0] && calls.at(1).toMap().value(S("label")) == c[1], S("the calls read %1").arg(show(calls)));
    expectDrawn(world, c[0]);
    expectDrawn(world, c[1]);
  });

  // How a call ended, and its icon.
  step(S("the agent's tool call is still running"), [](World& world, const Captures&, const Table&) {
    startRun(world);
    addCommand(world, 1, S("running"));
  });
  step(S("the agent's tool call failed"), [](World& world, const Captures&, const Table&) {
    startRun(world);
    addCommand(world, 1, S("failed"));
  });
  step(S("the agent's tool call was interrupted"), [](World& world, const Captures&, const Table&) {
    startRun(world);
    addCommand(world, 1, S("interrupted"));
  });
  step(S("the agent's tool call was declined by the user"), [](World& world, const Captures&, const Table&) {
    startRun(world);
    set(world, S("runtime-request"), S("request-1"), {{S("id"), S("request-1")}, {S("status"), S("resolved")}, {S("decision"), S("decline")}});
    addItem(world, S("approval_request"), {{S("requestId"), S("request-1")}, {S("prompt"), S("Run rm -rf dist?")}});
  });
  step(S("the call is marked %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const S label = lastCall(world).value(S("statusLabel")).toString();
    expect(label == c[0], S("the call is marked \"%1\"").arg(label));
    expectDrawn(world, c[0]);
  });
  step(S("the agent's most recent tool call (.+)"), [](World& world, const Captures& c, const Table&) {
    const QHash<S, S> types{
        {S("ran a command"), S("command_execution")},     {S("changed a file"), S("file_change")},       {S("searched the files"), S("file_search")},
        {S("searched the web"), S("web_search")},         {S("called an MCP tool"), S("dynamic_tool")}, {S("asked for approval"), S("approval_request")},
    };
    if (!types.contains(c[0])) fail(S("unknown tool call: %1").arg(c[0]));
    startRun(world);
    addItem(world, types.value(c[0]));
  });
  step(S("the call is shown with the %1 icon").arg(q), [](World& world, const Captures& c, const Table&) {
    const QVariantMap call = lastCall(world);
    expect(call.value(S("icon")) == c[0], S("the call is shown with the \"%1\" icon").arg(call.value(S("icon")).toString()));
    QQuickItem* line = callLine(world, call.value(S("id")).toString());
    expect(line->property("iconName") == c[0], S("the phone draws the \"%1\" icon").arg(line->property("iconName").toString()));
  });

  // Files a turn changed.
  step(S("the agent changed %1 and %1 in one turn").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world);
    for (const S& path : {c[0], c[1]}) addItem(world, S("file_change"), {{S("fileName"), path}});
    addItem(world, S("assistant_message"), {{S("text"), S("Both files are updated.")}});
    world.mc.part<FakeTurn>().changedFiles = {c[0], c[1]};
  });
  step(S("the turn completes"), [](World& world, const Captures&, const Table&) {
    QJsonArray files;
    int n = 0;
    for (const S& path : world.mc.part<FakeTurn>().changedFiles) {
      ++n;
      files.append(QJsonObject{{S("path"), path}, {S("kind"), S("modified")}, {S("additions"), 10 * n}, {S("deletions"), n}});
    }
    addItem(world, S("checkpoint"), {{S("files"), files}});
    settleRun(world, S("completed"), 60);
  });
  step(S("the reply lists both files with their added and removed lines"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const QVariantList files = role(model, lastRowOf(world, S("message")), TimelineModel::FilesRole).toList();
    const QStringList changed = world.mc.part<FakeTurn>().changedFiles;
    expect(files.size() == changed.size(), S("the reply lists %1").arg(show(files)));
    for (qsizetype i = 0; i < files.size(); ++i) {
      const QVariantMap file = files.at(i).toMap();
      expect(file.value(S("path")) == changed.at(i) && file.value(S("additions")).toInt() > 0 && file.value(S("deletions")).toInt() > 0,
             S("the reply lists %1").arg(show(files)));
    }
    expectDrawn(world, S("2 changed files"));
  });

  // The running turn's latest command, named by its program.
  step(S("the agent's latest command is %1").arg(kEscaped), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addItem(world, S("command_execution"), {{S("id"), S("command:latest")}, {S("input"), unescaped(c[0])}, {S("status"), S("running")}});
  });
  const auto end = [](World& world, const S& how) {
    const QHash<S, QJsonObject> endings{
        {S("is running"), {{S("status"), S("running")}}},
        {S("succeeds"), {{S("status"), S("completed")}, {S("exitCode"), 0}}},
        {S("fails"), {{S("status"), S("failed")}, {S("exitCode"), 1}}},
        {S("is declined by the user"), {{S("status"), S("declined")}}},
        {S("is stopped"), {{S("status"), S("interrupted")}}},
    };
    set(world, S("turn-item"), S("command:latest"), endings.value(how));
  };
  step(S("it finishes"), [end](World& world, const Captures&, const Table&) { end(world, S("succeeds")); });
  step(S("the command (is running|succeeds|fails|is declined by the user|is stopped)"), [end](World& world, const Captures& c, const Table&) { end(world, c[0]); });
  step(S("the live row reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    // The call's own row; a call that did not succeed has the live Thinking row after it.
    const S label = lastCall(world).value(S("label")).toString();
    expect(label == c[0], S("the live row reads \"%1\"").arg(label));
    expectDrawn(world, c[0]);
  });

  // A command as the provider wrapped it.
  step(S("the agent ran %1").arg(kEscaped), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addItem(world, S("command_execution"), {{S("input"), unescaped(c[0])}, {S("exitCode"), 0}});
    finishTurn(world);
  });
  step(S("the command reads %1").arg(kEscaped), [](World& world, const Captures& c, const Table&) {
    const S label = lastCall(world).value(S("label")).toString();
    expect(label == unescaped(c[0]), S("the command reads \"%1\"").arg(label));
    expectDrawn(world, label);
  });
  step(S("the user opens the (?:command|call)'s details"), [](World& world, const Captures&, const Table&) {
    if (!rowsOf(timeline(world), S("fold")).isEmpty()) openFold(world);
    world.tap(callLine(world, lastCall(world).value(S("id")).toString()));
  });
  step(S("the details show %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(lastCall(world).value(S("command")) == c[0], S("the call is %1").arg(show(lastCall(world))));
    expectDrawn(world, S("$ ") + c[0]);
  });
  step(S("the provider reported the command %1 with no output but its own text as the detail").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addItem(world, S("command_execution"), {{S("input"), c[0]}, {S("output"), c[0]}, {S("exitCode"), 0}});
  });
  step(S("the details show the command once"), [](World& world, const Captures&, const Table&) {
    expectDrawn(world, S("$ npm test"));
    // The command in the details, and not again as what it printed.
    const QStringList texts = world.texts();
    expect(texts.filter(S("npm test")).size() == 1, S("the phone shows %1").arg(texts.join(S(" | "))));
  });
  step(S("no output is shown"), [](World& world, const Captures&, const Table&) {
    expect(lastCall(world).value(S("detail")).toString().isEmpty(), S("the call is %1").arg(show(lastCall(world))));
  });

  // An image the agent looked at.
  const auto viewed = [](World& world, const S& path) {
    serveWorkspaceFiles(world);
    world.mc.part<FakeTurn>().viewedImage = true;
    startRun(world, 30);
    addItem(world, S("dynamic_tool"), {{S("toolName"), S("Read")}, {S("input"), QJsonObject{{S("file_path"), path}}}, {S("viewedImagePath"), path}});
  };
  step(S("the agent viewed %1 in the thread's workspace").arg(q), [viewed](World& world, const Captures& c, const Table&) { viewed(world, kRoot + QLatin1Char('/') + c[0]); });
  step(S("the agent viewed %1 outside the workspace").arg(q), [viewed](World& world, const Captures& c, const Table&) { viewed(world, c[0]); });
  step(S("the path is shown and no image is loaded"), [](World& world, const Captures&, const Table&) {
    const S path = lastCall(world).value(S("viewedPath")).toString();
    QQuickItem* named = drawn(world, S("viewedImagePath"));
    world.sync();
    expect(!path.isEmpty() && named->property("text") == path, S("the details show %1").arg(named->property("text").toString()));
    expect(signedFiles(world).isEmpty() && drawnAll(world, S("viewedImage")).isEmpty(), S("an image was loaded"));
  });

  // An answered question.
  const auto answered = [](World& world, const QJsonObject& answer) {
    startRun(world, 30);
    QJsonObject full{{S("requestId"), S("request-1")}, {S("answers"), QJsonObject{}}, {S("attachmentsByQuestionId"), QJsonObject{}}};
    for (auto it = answer.begin(); it != answer.end(); ++it) full.insert(it.key(), it.value());
    addItem(world, S("user_input_request"), {{S("requestId"), S("request-1")},
                                             {S("questions"), QJsonArray{QJsonObject{{S("id"), S("q1")}, {S("question"), S("Which database?")}}}},
                                             {S("questionAnswer"), full}});
  };
  step(S("the agent asked a question that the user answered with %1 and %2").arg(q, q), [answered](World& world, const Captures& c, const Table&) {
    answered(world, {{S("answers"), QJsonObject{{S("q1"), c[0]}, {S("q2"), QJsonArray{c[1]}}}}});
  });
  step(S("the agent asked a question that the user answered with only the files %1 and %2").arg(q, q), [answered](World& world, const Captures& c, const Table&) {
    answered(world, {{S("attachmentsByQuestionId"), QJsonObject{{S("q1"), QJsonArray{QJsonObject{{S("name"), c[0]}}, QJsonObject{{S("name"), c[1]}}}}}}});
  });
  step(S("the agent asked a question that the user answered with nothing but the question %1").arg(q), [answered](World& world, const Captures& c, const Table&) {
    answered(world, {{S("questionTextById"), QJsonObject{{S("q1"), c[0]}}}});
  });
  step(S("the call's row previews %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* preview = drawn(world, S("workCallPreview"));
    expect(preview->property("text") == c[0], S("the row previews %1").arg(preview->property("text").toString()));
  });

  // A long group's place.
  step(S("a long group of tool calls that the user scrolled partway down"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    for (int n = 1; n <= 30; ++n) addCommand(world, n);
    openGroup(world, 30);
    QQuickItem* view = callsView(world);
    world.waitFor([&] { return endOf(view) > 200; }, S("the group to scroll"));
    view->setProperty("contentY", 150.5);
    world.sync();
  });
  step(S("the user closes the group and opens it again"), [](World& world, const Captures&, const Table&) {
    world.tap(drawn(world, S("workGroupToggle")));
    world.waitFor([&] { return callCount(world) < 30; }, S("the group to close"));
    world.waitFor([&] {
      const QList<QQuickItem*> views = drawnAll(world, S("workCalls"));
      return views.size() == 1 && !views.first()->property("interactive").toBool();
    }, S("the group to stop scrolling"));
    openGroup(world, 30);
  });
  step(S("the group shows the call the user was reading at the same place"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return std::abs(callsView(world)->property("contentY").toDouble() - 150.5) < 0.5; },
                  [&] { return S("the group to open at 150.5, not %1").arg(callsView(world)->property("contentY").toDouble()); });
  });

  // The phone's activity log (TimelineModel::brief).

  step(S("the activity log shows a tool call and a failed turn"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addItem(world, S("command_execution"), {{S("input"), S("bun test cart")}, {S("output"), S("12 passed")}, {S("exitCode"), 0}});
    addFailure(world, {{S("message"), S("The provider stopped responding.")}});
    settleRun(world, S("failed"), 30);
    openFold(world);
  });
  const auto copies = [](World& world, QQuickItem* line, const S& text) {
    world.clipboard.clear();
    world.hold(line, [&] { return !world.clipboard.isEmpty(); }, S("the row to copy"));
    expect(world.clipboard == text, S("the long press copied \"%1\"").arg(world.clipboard));
    world.waitFor([&] { return line->findChild<QQuickItem*>(S("workLineCopied")) && line->findChild<QQuickItem*>(S("workLineCopied"))->isVisible(); },
                  S("the row to say it copied"));
  };
  step(S("the user long presses the tool call"), [copies](World& world, const Captures&, const Table&) {
    const QVariantMap call = lastCall(world);
    copies(world, callLine(world, call.value(S("id")).toString()), S("bun test cart\n12 passed"));
  });
  step(S("the user long presses the failure"), [copies](World& world, const Captures&, const Table&) {
    // Its heading, then its message.
    const S title = role(timeline(world), lastRowOf(world, S("error")), TimelineModel::TitleRole).toString();
    copies(world, failureRow(world), title + S("\nThe provider stopped responding."));
  });
  const auto copiedForAMoment = [](World& world, const Captures&, const Table&) {
    // "Copied" goes again on its own.
    world.waitFor([&] { return drawnAll(world, S("workLineCopied")).isEmpty(); }, S("\"Copied\" to go"));
  };
  step(S("its text is copied and the row says %1 for a moment").arg(q), copiedForAMoment);
  step(S("the failure message is copied and the row says %1 for a moment").arg(q), copiedForAMoment);

  // A turn's failure.
  step(S("the turn ended with an error"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addFailure(world, {{S("message"), S("The provider stopped responding.")}});
    settleRun(world, S("failed"), 30);
  });
  step(S("the turn ended at a provider usage limit that resets at (\\d+):(\\d+)"), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    const QDateTime reset(kNow.toLocalTime().date(), QTime(c[0].toInt(), c[1].toInt()));
    addFailure(world, {{S("class"), S("usage_limit")}, {S("message"), S("You've hit your usage limit.")}, {S("resetAt"), iso(reset)}});
    settleRun(world, S("failed"), 30);
  });
  step(S("the turn ended at a provider usage limit with no reset time"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addFailure(world, {{S("class"), S("usage_limit")}, {S("message"), S("You've hit your usage limit.")}});
    settleRun(world, S("failed"), 30);
  });
  step(S("the activity log shows the error's title, its message and when it happened"), [](World& world, const Captures&, const Table&) {
    QQuickItem* row = failureRow(world);
    world.waitFor([&] {
      const QStringList texts = textsOf(row->parentItem());
      return texts.contains(S("The provider stopped responding.")) && texts.size() >= 3;
    }, [&] { return S("the failure's title, message and time; it shows %1").arg(textsOf(row->parentItem()).join(S(" | "))); });
    const S stamp = role(timeline(world), lastRowOf(world, S("error")), TimelineModel::TimeRole).toString();
    expect(!stamp.isEmpty() && textsOf(row).contains(stamp), S("the failure says when it happened: %1").arg(textsOf(row).join(S(" | "))));
  });
  step(S("the activity log shows \"Usage limit reached. Retry after\" that time, without the message"), [](World& world, const Captures&, const Table&) {
    const S title = role(timeline(world), lastRowOf(world, S("error")), TimelineModel::TitleRole).toString();
    expect(title.startsWith(QLatin1String("Usage limit reached. Retry after ")) && title.contains(QRegularExpression(S("(17:00|5:00\\WPM)"))), S("the row reads \"%1\"").arg(title));
    expectDrawn(world, title);
    expect(!world.shows(S("You've hit your usage limit."), false), S("the row shows the provider's message"));
  });
  step(S("the activity log shows \"Usage limit reached.\" alone"), [](World& world, const Captures&, const Table&) {
    expectDrawn(world, S("Usage limit reached."));
    expect(!world.shows(S("You've hit your usage limit."), false), S("the row shows the provider's message"));
  });

  // The one live row of a running turn.
  step(S("the agent is working"), [](World& world, const Captures&, const Table&) { startRun(world, 30); });
  step(S("it has not made a tool call yet"), [](World& world, const Captures&, const Table&) {});
  step(S("its latest tool call failed"), [](World& world, const Captures&, const Table&) { addCommand(world, 1, S("failed")); });
  step(S("its latest tool call was stopped"), [](World& world, const Captures&, const Table&) { addCommand(world, 1, S("interrupted")); });
  step(S("its latest tool call is still running"), [](World& world, const Captures&, const Table&) { addCommand(world, 1, S("running")); });
  step(S("its latest tool call succeeded and none followed"), [](World& world, const Captures&, const Table&) { addCommand(world, 1); });
  step(S("the last row of the activity log reads (.+)"), [](World& world, const Captures& c, const Table&) {
    TimelineModel& model = timeline(world);
    const int last = model.rowCount() - 1;
    const S kind = role(model, last, TimelineModel::KindRole).toString();
    const S want = c[0].mid(1, c[0].size() - 2);
    if (want == QLatin1String("Thinking")) {
      expect(kind == QLatin1String("thinking") && rowsOf(model, S("thinking")).size() == 1, S("the last row is not Thinking; %1").arg(describe(model)));
      QQuickItem* row = drawn(world, S("thinkingRow"));
      expect(row->property("label") == QLatin1String("Thinking"), S("the live row reads \"%1\"").arg(row->property("label").toString()));
      return;
    }
    // What the call is doing ("Running bun") or did ("Ran bun").
    const S verb = want == QLatin1String("what that call is doing") ? S("Running ") : S("Ran ");
    expect(kind == QLatin1String("work") && rowsOf(model, S("thinking")).isEmpty(), S("the last row is not the call; %1").arg(describe(model)));
    const S label = lastCall(world).value(S("label")).toString();
    expect(label.startsWith(verb), S("the live row reads \"%1\"").arg(label));
    expectDrawn(world, label);
    expect(drawnAll(world, S("thinkingRow")).isEmpty(), S("the phone draws a Thinking row too"));
  });

  // Rows that stand alone between groups.
  step(S("the agent made tool calls, then (.+), then made more tool calls"), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addCommand(world, 1);
    addCommand(world, 2);
    const QHash<S, std::function<void()>> events{
        {S("a context compaction"), [&] { addItem(world, S("compaction")); }},
        {S("a context handoff"), [&] { addItem(world, S("handoff")); }},
        {S("a notification"), [&] { addItem(world, S("notification"), {{S("summary"), S("Tests are green")}}); }},
        {S("a provider error that failed the turn"), [&] { addFailure(world, {{S("message"), S("The provider stopped responding.")}}); }},
    };
    if (!events.contains(c[0])) fail(S("no event described as \"%1\"").arg(c[0]));
    events.value(c[0])();
    addCommand(world, 3);
    addCommand(world, 4);
  });
  step(S("the tool calls before and after are two groups"), [](World& world, const Captures&, const Table&) {
    TimelineModel& model = timeline(world);
    const QList<int> groups = workRows(world);
    expect(groups.size() == 2 && groups.at(1) - groups.at(0) == 2, S("the calls are not two groups around one row; %1").arg(describe(model)));
  });
  step(S("(.+) is shown on its own between them"), [](World& world, const Captures& c, const Table&) {
    TimelineModel& model = timeline(world);
    const QList<int> groups = workRows(world);
    const int between = groups.first() + 1;
    const QHash<S, std::pair<S, S>> rows{
        {S("a context compaction"), {S("marker"), S("Context compacted")}},
        {S("a context handoff"), {S("marker"), S("Context handoff")}},
        {S("a notification"), {S("marker"), S("Tests are green")}},
        {S("a provider error that failed the turn"), {S("error"), S()}},
    };
    const auto [kind, title] = rows.value(c[0]);
    expect(role(model, between, TimelineModel::KindRole) == kind && (title.isEmpty() || role(model, between, TimelineModel::TitleRole) == title),
           S("between the groups is %1").arg(describe(model)));
    if (!title.isEmpty()) expectDrawn(world, title);
    else expectDrawn(world, S("The provider stopped responding."));
  });

  // Calls the phone does or does not list.
  step(S("a tool call in a turn that has settled never reported that it ended"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addCommand(world, 1);
    addItem(world, S("command_execution"), {{S("id"), S("command:lost")}, {S("input"), S("bun run watch")}, {S("status"), S("running")}});
    finishTurn(world);
    openFold(world);
  });
  step(S("the call is not listed among the turn's tool calls"), [](World& world, const Captures&, const Table&) {
    const QVariantList calls = entries(world);
    for (const QVariant& call : calls) expect(call.toMap().value(S("id")) != QLatin1String("command:lost"), S("the calls are %1").arg(show(calls)));
    expectDrawn(world, S("bun test cart-1"));
    expect(!world.shows(S("bun run watch"), false), S("the phone draws the call that never ended"));
  });
  step(S("a settled turn has a tool call that was interrupted and one that the user declined"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addCommand(world, 1, S("interrupted"));
    set(world, S("runtime-request"), S("request-1"), {{S("id"), S("request-1")}, {S("status"), S("resolved")}, {S("decision"), S("decline")}});
    addItem(world, S("approval_request"), {{S("requestId"), S("request-1")}, {S("prompt"), S("Run rm -rf dist?")}});
    finishTurn(world);
    openFold(world);
  });
  step(S("both are listed with %1 and %2").arg(q, q), [](World& world, const Captures& c, const Table&) {
    TimelineModel& model = timeline(world);
    const int work = lastRowOf(world, S("work"));
    if (role(model, work, TimelineModel::EntriesRole).toList().size() < 2) world.tap(drawn(world, S("workGroupToggle")));
    world.waitFor([&] { return entries(world).size() == 2; }, [&] { return S("both calls; %1").arg(describe(model)); });
    QStringList labels;
    for (const QVariant& call : entries(world)) labels.append(call.toMap().value(S("statusLabel")).toString());
    expect(labels == QStringList{c[0], c[1]}, S("the calls are marked %1").arg(labels.join(S(", "))));
    expectDrawn(world, c[0]);
    expectDrawn(world, c[1]);
  });

  // A delegation and its subagent's card.
  const auto delegate = [](World& world, const QJsonObject& more) {
    startRun(world, 30);
    QJsonObject call = halC2Call(S("delegate_task"), {{S("prompt"), S("write the tax tests")}}, {{S("taskId"), S("task-1")}});
    call.insert(S("id"), S("delegate:1"));
    for (auto it = more.begin(); it != more.end(); ++it) call.insert(it.key(), it.value());
    addItem(world, S("dynamic_tool"), call);
  };
  const auto card = [](World& world, const S& task) {
    addItem(world, S("subagent"), {{S("origin"), S("app_owned")}, {S("subagentId"), task}, {S("title"), S("write the tax tests")}, {S("status"), S("running")},
                                   {S("childThreadId"), S("thread-child")}});
  };
  step(S("the agent delegated %1 and the subagent's card is in the timeline").arg(q), [delegate, card](World& world, const Captures&, const Table&) {
    delegate(world, {});
    card(world, S("task-1"));
  });
  step(S("the agent delegated %1 and the delegation failed").arg(q), [delegate, card](World& world, const Captures&, const Table&) {
    delegate(world, {{S("status"), S("failed")}});
    card(world, S("task-1"));
  });
  step(S("the agent delegated %1 and the delegation is still being started").arg(q), [delegate, card](World& world, const Captures&, const Table&) {
    // No task yet: the call has not answered.
    delegate(world, {{S("status"), S("running")}, {S("output"), QJsonValue::Null}});
    card(world, S("task-1"));
  });
  step(S("the agent delegated %1 and no subagent card matches the delegation").arg(q), [delegate, card](World& world, const Captures&, const Table&) {
    delegate(world, {});
    card(world, S("task-2"));
  });
  const auto delegationListed = [](World& world) {
    TimelineModel& model = timeline(world);
    for (const int row : rowsOf(model, S("work"))) {
      for (const QVariant& call : role(model, row, TimelineModel::EntriesRole).toList()) {
        if (call.toMap().value(S("id")) == QLatin1String("delegate:1")) return true;
      }
    }
    return false;
  };
  step(S("the delegating call is not also listed among the tool calls"), [delegationListed](World& world, const Captures&, const Table&) {
    expect(!delegationListed(world), S("the delegation is listed; %1").arg(describe(timeline(world))));
    expect(!rowsOf(timeline(world), S("subagent")).isEmpty(), S("the card is gone; %1").arg(describe(timeline(world))));
    expect(!world.shows(S("Delegate a child task"), false), S("the phone draws the delegation"));
  });
  step(S("the delegating call is listed among the tool calls"), [delegationListed](World& world, const Captures&, const Table&) {
    expect(delegationListed(world), S("the delegation is not listed; %1").arg(describe(timeline(world))));
    expectDrawn(world, S("Delegate a child task"));
  });

  // The workspace's preparation.
  step(S("the MC prepared the thread's workspace before the first turn"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addItem(world, S("command_execution"), {{S("input"), S("Preparing workspace")}, {S("exitCode"), 0}});
    addCommand(world, 1);
    finishTurn(world);
    openFold(world);
  });
  step(S("the activity log does not show a command for preparing the workspace"), [](World& world, const Captures&, const Table&) {
    expect(groupLine(world) == QLatin1String("bun test cart-1") || summary(world) == QLatin1String("Ran 1 command"),
           S("the group is %1").arg(describe(timeline(world))));
    expect(!world.shows(S("Preparing workspace"), false), S("the phone draws the workspace's preparation"));
  });

  // A usage limit is no failure.
  step(S("the turn stopped at the provider's usage limit"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addFailure(world, {{S("class"), S("usage_limit")}, {S("message"), S("You've hit your usage limit.")}});
    settleRun(world, S("failed"), 30);
  });
  step(S("the row %1 is shown without a failure mark").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* row = failureRow(world);
    expect(row->property("label").toString().startsWith(c[0]), S("the row reads \"%1\"").arg(row->property("label").toString()));
    const QColor colour = row->property("labelColor").value<QColor>();
    QQuickItem* brick = drawn(world, S("threadTimeline"));
    expect(colour == brick->property("warningColor").value<QColor>() && colour != brick->property("errorColor").value<QColor>(),
           S("the row reads in %1").arg(colour.name()));
  });
  step(S("a provider error that is not a usage limit is shown with a failure mark"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addFailure(world, {{S("message"), S("The provider stopped responding.")}});
    settleRun(world, S("failed"), 30);
    world.waitFor([&] { return drawnAll(world, S("errorLine")).size() == 2; }, S("the second failure"));
    QQuickItem* row = failureRow(world);
    QQuickItem* brick = drawn(world, S("threadTimeline"));
    expect(row->property("labelColor").value<QColor>() == brick->property("errorColor").value<QColor>(),
           S("the failure reads in %1").arg(row->property("labelColor").value<QColor>().name()));
  });

  // A failure is all there is to see.
  step(S("the turn failed with a provider error"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addFailure(world, {{S("message"), S("The provider stopped responding.")}});
    settleRun(world, S("failed"), 30);
  });
  step(S("the failure row stays open with its message"), [](World& world, const Captures&, const Table&) {
    QQuickItem* row = failureRow(world);
    expectDrawn(world, S("The provider stopped responding."));
    expect(!row->property("interactive").toBool(), S("the failure row opens"));
  });
  step(S("the row has nothing more to expand"), [](World& world, const Captures&, const Table&) {
    // A tap leaves the row as it was: no details open under it.
    QQuickItem* row = failureRow(world);
    const int before = textsOf(row->parentItem()).size();
    world.tap(row);
    world.sync();
    expect(textsOf(row->parentItem()).size() == before && !world.shows(S("$ "), false), S("the failure opened into %1").arg(textsOf(row->parentItem()).join(S(" | "))));
  });
});

}  // namespace
