// What a tool call's details show and how a turn's changed files read
// (features/timeline/tool-calls.feature): a command's exit, a search's
// matches and results, a plan's steps, a changed file and its diff, an image
// the agent looked at, an answered question, a long group's place, and the
// changed-files card's counts, folders and right click. The stream is
// Stream.h's; the rows are read from the Timeline brick (a call's details)
// and the ThreadView brick (the changed files) drawing them.

#include <QBuffer>
#include <QImage>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QSignalSpy>
#include <QTcpSocket>
#include <QTest>

#include <cmath>
#include <memory>

#include "Brick.h"
#include "Harness.h"
#include "Stream.h"
#include "World.h"

namespace {

using namespace stream;

const QString kRoot = QStringLiteral("/work/shop");

// The open thread's timeline as the Timeline brick draws it.
Brick& timelineBrick(World& world) {
  if (!world.brick) {
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nTimeline {}\n", QSize(820, 1400));
    world.brick->root()->setProperty("model", QVariant::fromValue(static_cast<QObject*>(&timeline(world))));
  }
  return *world.brick;
}

// The open thread as the ThreadView brick draws it.
Brick& threadBrick(World& world) {
  if (!world.brick) world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nThreadView {}\n", QSize(820, 1200));
  return *world.brick;
}

void collect(QQuickItem* item, const QString& name, QList<QQuickItem*>& out) {
  if (item->objectName() == name && item->isVisible()) out.append(item);
  for (QQuickItem* child : item->childItems()) collect(child, name, out);
}

QList<QQuickItem*> drawnAll(World& world, const QString& name) {
  QList<QQuickItem*> items;
  collect(world.brick->window().contentItem(), name, items);
  return items;
}

// The visible item named `name` drawn lowest that `matches`.
QQuickItem* drawn(World& world, const QString& name, const std::function<bool(QQuickItem*)>& matches = [](QQuickItem*) { return true; }) {
  QQuickItem* found = nullptr;
  world.waitFor([&] {
    found = nullptr;
    for (QQuickItem* item : drawnAll(world, name)) {
      if (matches(item) && (!found || item->mapToScene(QPointF()).y() >= found->mapToScene(QPointF()).y())) found = item;
    }
    return found != nullptr;
  }, QStringLiteral("the timeline to draw %1").arg(name));
  return found;
}

void click(World& world, QQuickItem* item, Qt::MouseButton button = Qt::LeftButton) {
  QTest::mouseClick(&world.brick->window(), button, Qt::NoModifier, world.brick->at(item, 0.3, 0.5));
}

// The texts a visible item shows, in the order drawn.
QStringList textsOf(const QQuickItem* item) {
  QStringList texts;
  if (!item->isVisible()) return texts;
  if (const QString text = item->property("text").toString(); !text.isEmpty()) texts.append(text);
  for (const QQuickItem* child : item->childItems()) texts.append(textsOf(child));
  return texts;
}

// Every text the brick shows.
QStringList shown(World& world) {
  return textsOf(world.brick->window().contentItem());
}

QVariantMap lastCall(World& world) {
  TimelineModel& model = timeline(world);
  for (int row = model.rowCount() - 1; row >= 0; --row) {
    if (role(model, row, TimelineModel::KindRole) != QLatin1String("work")) continue;
    const QVariantList calls = role(model, row, TimelineModel::EntriesRole).toList();
    if (!calls.isEmpty()) return calls.last().toMap();
  }
  fail(QStringLiteral("no call is shown; %1").arg(describe(model)));
}

// Opens the newest call's details, as the user clicks its line; a settled
// turn's fold is opened first.
void openDetails(World& world) {
  TimelineModel& model = timeline(world);
  for (int row = model.rowCount() - 1; row >= 0; --row) {
    if (role(model, row, TimelineModel::KindRole) != QLatin1String("fold")) continue;
    if (!role(model, row, TimelineModel::ExpandedRole).toBool()) model.toggle(role(model, row, TimelineModel::IdRole).toString());
    break;
  }
  timelineBrick(world);
  const QString id = lastCall(world).value(QStringLiteral("id")).toString();
  QQuickItem* line = drawn(world, QStringLiteral("workCall"), [&](QQuickItem* item) {
    return item->parentItem() && item->parentItem()->property("modelData").value<QObject*>() &&
           item->parentItem()->property("modelData").value<QObject*>()->property("id") == id;
  });
  click(world, line);
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
  world.mc.onRpc(QStringLiteral("assets.createUrl"), [&mc = world.mc](const FakeMc::Rpc& rpc) {
    const QString path = rpc.payload.value(QLatin1String("resource")).toObject().value(QLatin1String("path")).toString();
    mc.reply(rpc, QJsonObject{{QStringLiteral("relativeUrl"), QStringLiteral("/api/assets/workspace/") + path},
                              {QStringLiteral("expiresAt"), double(now().addSecs(3600).toMSecsSinceEpoch())}});
  });
  world.mc.onRaw(QStringLiteral("/api/assets/workspace/"), [](QTcpSocket* socket, const QByteArray& head) {
    socket->read(head.size());
    const QByteArray body = picture();
    socket->write("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: image/png\r\nContent-Length: " + QByteArray::number(body.size()) + "\r\n\r\n" + body);
    socket->disconnectFromHost();
  });
}

// The files the client asked the MC to sign.
QList<QJsonObject> signedFiles(World& world) {
  QList<QJsonObject> files;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    const QJsonObject resource = rpc.payload.value(QLatin1String("resource")).toObject();
    if (rpc.method == QLatin1String("assets.createUrl") && resource.value(QLatin1String("_tag")).toString().endsWith(QLatin1String("-file"))) files.append(resource);
  }
  return files;
}

// A settled turn that changed `files` ({path, additions, deletions}), as its
// reply lists them.
void finishTurnWith(World& world, const QJsonArray& files) {
  startRun(world, 60);
  for (const QJsonValue& file : files) addItem(world, QStringLiteral("file_change"), {{QStringLiteral("fileName"), file.toObject().value(QLatin1String("path"))}});
  addItem(world, QStringLiteral("assistant_message"), {{QStringLiteral("text"), QStringLiteral("Done.")}});
  addItem(world, QStringLiteral("checkpoint"), {{QStringLiteral("checkpointId"), QStringLiteral("cp-1")}, {QStringLiteral("scopeId"), QStringLiteral("scope-1")}, {QStringLiteral("files"), files}});
  settleRun(world, QStringLiteral("completed"), 60);
  threadBrick(world);
}

QJsonObject changed(const QString& path, int additions, int deletions = 0) {
  return {{QStringLiteral("path"), path}, {QStringLiteral("kind"), QStringLiteral("modified")}, {QStringLiteral("additions"), additions}, {QStringLiteral("deletions"), deletions}};
}

// The changed-files rows named `name` ("changedFolder" or "changedFile"), each
// as the texts it shows ("src +5").
QStringList changedRows(World& world, const QString& name) {
  threadBrick(world);
  QStringList rows;
  for (QQuickItem* item : drawnAll(world, name)) rows.append(textsOf(item).join(QLatin1Char(' ')));
  rows.removeDuplicates();
  rows.sort();
  return rows;
}

QQuickItem* changedRow(World& world, const QString& name, const QString& label) {
  return drawn(world, name, [&](QQuickItem* item) { return item->property("modelData").toMap().value(QStringLiteral("name")) == label; });
}

// The open group's window of calls.
QQuickItem* callsView(World& world) {
  return drawn(world, QStringLiteral("workCalls"), [](QQuickItem* item) { return item->property("interactive").toBool(); });
}

double contentY(World& world) {
  return callsView(world)->property("contentY").toDouble();
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

// Opens the newest group's every call, as the user clicks its toggle.
void openGroup(World& world, int calls) {
  click(world, drawn(world, QStringLiteral("workGroupToggle")));
  world.waitFor([&] { return callCount(world) == calls; }, [&] { return QStringLiteral("the group to open; %1").arg(describe(timeline(world))); });
}

void addCommands(World& world, int from, int to) {
  for (int n = from; n <= to; ++n) addCommand(world, n);
}

const Steps steps([] {
  const QString q = kQuoted;

  // A call's details.
  step(QStringLiteral("the agent ran a command that exited with code (\\d+)"), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    const int code = c[0].toInt();
    addItem(world, QStringLiteral("command_execution"), {{QStringLiteral("input"), QStringLiteral("bun lint")}, {QStringLiteral("output"), QStringLiteral("checked 12 files")},
                                                         {QStringLiteral("status"), code == 0 ? QStringLiteral("completed") : QStringLiteral("failed")}, {QStringLiteral("exitCode"), code}});
  });
  step(QStringLiteral("the agent's command is still running"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("command_execution"), {{QStringLiteral("input"), QStringLiteral("bun lint")}, {QStringLiteral("output"), QStringLiteral("checking")}, {QStringLiteral("status"), QStringLiteral("running")}});
  });
  step(QStringLiteral("the user opens the (command|search|plan|file change|call)'s details"), [](World& world, const Captures&, const Table&) { openDetails(world); });
  step(QStringLiteral("the details show its input"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.brick->shows(QStringLiteral("$ bun lint")); }, [&] { return QStringLiteral("the command; the timeline shows %1").arg(shown(world).join(QLatin1String(" | "))); });
  });
  step(QStringLiteral("they say %1 as (a success|a failure)").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* status = drawn(world, QStringLiteral("exitStatus"));
    const QString colour = c[1] == QLatin1String("a success") ? QStringLiteral("successColor") : QStringLiteral("errorColor");
    expect(status->property("text") == c[0], QStringLiteral("the details say %1").arg(status->property("text").toString()));
    expect(status->property("color").value<QColor>() == world.brick->root()->property(colour.toUtf8()).value<QColor>(),
           QStringLiteral("the exit reads in %1, not %2").arg(status->property("color").value<QColor>().name(), colour));
  });
  step(QStringLiteral("no exit code is shown"), [](World& world, const Captures&, const Table&) {
    expect(!lastCall(world).contains(QStringLiteral("exitCode")) && drawnAll(world, QStringLiteral("exitStatus")).isEmpty(),
           QStringLiteral("the call is %1").arg(show(lastCall(world))));
  });
  step(QStringLiteral("the agent searched the files and found %1 in %1 at line (\\d+) column (\\d+)").arg(q, q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("file_search"), {{QStringLiteral("pattern"), c[0]},
                                                   {QStringLiteral("results"), QJsonArray{QJsonObject{{QStringLiteral("fileName"), kRoot + QLatin1Char('/') + c[1]},
                                                                                                      {QStringLiteral("line"), c[2].toInt()},
                                                                                                      {QStringLiteral("column"), c[3].toInt()},
                                                                                                      {QStringLiteral("preview"), QStringLiteral("  return cart.total * rate;")}}}}});
  });
  step(QStringLiteral("the match is listed as %1 with its preview line").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] {
      for (QQuickItem* match : drawnAll(world, QStringLiteral("searchMatch"))) {
        if (textsOf(match) == QStringList{c[0], QStringLiteral("return cart.total * rate;")}) return true;
      }
      return false;
    }, [&] { return QStringLiteral("the match; the timeline shows %1").arg(shown(world).join(QLatin1String(" | "))); });
  });
  step(QStringLiteral("the agent searched the web and a result has the address %1").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("web_search"), {{QStringLiteral("patterns"), QJsonArray{QStringLiteral("vat rates")}},
                                                  {QStringLiteral("results"), QJsonArray{QJsonObject{{QStringLiteral("title"), QStringLiteral("VAT rates")}, {QStringLiteral("url"), c[0]}}}}});
  });
  step(QStringLiteral("the result is (a link titled with the page's title|its title as plain text with no link)"), [](World& world, const Captures& c, const Table&) {
    QQuickItem* result = drawn(world, QStringLiteral("webResult"));
    expect(result->property("text") == QLatin1String("VAT rates"), QStringLiteral("the result reads %1").arg(result->property("text").toString()));
    QSignalSpy opened(world.brick->root(), SIGNAL(linkActivated(QString)));
    click(world, result);
    world.sync();
    if (c[0].startsWith(QLatin1String("a link"))) {
      expect(opened.size() == 1 && opened.first().first() == QLatin1String("https://example.com/tax"), QStringLiteral("the result opened %1 links").arg(opened.size()));
    } else {
      expect(opened.isEmpty() && !result->property("font").value<QFont>().underline(), QStringLiteral("the result is a link"));
    }
  });
  step(QStringLiteral("the agent searched the web and a result has no title"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("web_search"), {{QStringLiteral("patterns"), QJsonArray{QStringLiteral("vat rates")}},
                                                  {QStringLiteral("results"), QJsonArray{QJsonObject{{QStringLiteral("url"), QStringLiteral("https://example.com/tax")}}, QJsonObject{}}}});
  });
  step(QStringLiteral("the result shows its address"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return drawnAll(world, QStringLiteral("webResult")).size() == 2; }, QStringLiteral("the two results"));
    expect(textsOf(drawnAll(world, QStringLiteral("webResult")).first()) == QStringList{QStringLiteral("https://example.com/tax")},
           QStringLiteral("the results read %1").arg(shown(world).join(QLatin1String(" | "))));
  });
  step(QStringLiteral("a result with neither is called %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(textsOf(drawnAll(world, QStringLiteral("webResult")).last()) == QStringList{c[0]}, QStringLiteral("the results read %1").arg(shown(world).join(QLatin1String(" | "))));
  });
  step(QStringLiteral("the agent's plan has one finished step %1 and one open step %1").arg(q, q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("todo_list"), {{QStringLiteral("steps"), QJsonArray{QJsonObject{{QStringLiteral("text"), c[0]}, {QStringLiteral("status"), QStringLiteral("completed")}},
                                                                                     QJsonObject{{QStringLiteral("text"), c[1]}, {QStringLiteral("status"), QStringLiteral("pending")}}}}});
  });
  step(QStringLiteral("the finished step is marked done and the open step is marked not done"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.brick->shows(QStringLiteral("✓ Add the tax line\n○ Write tests")); },
                  [&] { return QStringLiteral("the plan; the timeline shows %1").arg(shown(world).join(QLatin1String(" | "))); });
  });
  step(QStringLiteral("the agent changed %1 adding (\\d+) lines and removing (\\d+)").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("file_change"), {{QStringLiteral("fileName"), c[0]}, {QStringLiteral("additions"), c[1].toInt()}, {QStringLiteral("deletions"), c[2].toInt()}});
  });
  step(QStringLiteral("the details show %1 with %1 and %1").arg(q, q, q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* diff = drawn(world, QStringLiteral("openCallDiff"));
    const QStringList texts = textsOf(diff->parentItem());
    expect(texts == QStringList{c[0], c[1], c[2], QStringLiteral("Open diff")}, QStringLiteral("the details show %1").arg(texts.join(QLatin1String(" | "))));
  });
  step(QStringLiteral("the details offer %1 for that file").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* diff = drawn(world, QStringLiteral("openCallDiff"));
    expect(diff->property("text") == c[0], QStringLiteral("the details offer %1").arg(diff->property("text").toString()));
    QSignalSpy opened(world.brick->root(), SIGNAL(fileActivated(QString,QString,QString)));
    click(world, diff);
    expect(opened.size() == 1 && opened.first().at(0) == QLatin1String("src/cart.ts") && opened.first().at(1) == QLatin1String("diff"),
           QStringLiteral("Open diff asked for %1").arg(opened.isEmpty() ? QStringLiteral("nothing") : opened.first().at(0).toString()));
  });
  step(QStringLiteral("the agent renamed %1 to %1").arg(q, q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("file_change"), {{QStringLiteral("fileName"), kRoot + QLatin1Char('/') + c[1]},
                                                   {QStringLiteral("changes"), QJsonArray{QJsonObject{{QStringLiteral("operation"), QStringLiteral("rename")},
                                                                                                      {QStringLiteral("path"), kRoot + QLatin1Char('/') + c[1]},
                                                                                                      {QStringLiteral("oldPath"), kRoot + QLatin1Char('/') + c[0]}}}}});
  });
  step(QStringLiteral("the details list the rename as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return world.brick->shows(QStringLiteral("rename ") + c[0]); },
                  [&] { return QStringLiteral("the rename; the timeline shows %1").arg(shown(world).join(QLatin1String(" | "))); });
  });
  step(QStringLiteral("the provider reported the command %1 with no output but its own text as the detail").arg(q), [](World& world, const Captures& c, const Table&) {
    startRun(world, 30);
    addItem(world, QStringLiteral("command_execution"), {{QStringLiteral("input"), c[0]}, {QStringLiteral("output"), c[0]}, {QStringLiteral("exitCode"), 0}});
  });
  step(QStringLiteral("the details show the command once"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return world.brick->shows(QStringLiteral("$ npm test")); }, QStringLiteral("the command in the details"));
    // The call's own line (a live one named by its program), and its command in the details.
    const QStringList texts = shown(world);
    const bool labelled = lastCall(world).value(QStringLiteral("label")) == QLatin1String("npm test");
    expect(texts.count(QStringLiteral("npm test")) == (labelled ? 1 : 0) && texts.count(QStringLiteral("$ npm test")) == 1,
           QStringLiteral("the timeline shows %1").arg(texts.join(QLatin1String(" | "))));
  });
  step(QStringLiteral("no output is shown"), [](World& world, const Captures&, const Table&) {
    expect(lastCall(world).value(QStringLiteral("detail")).toString().isEmpty(), QStringLiteral("the call is %1").arg(show(lastCall(world))));
  });

  // An image the agent looked at.
  const auto viewed = [](World& world, const QString& path) {
    serveWorkspaceFiles(world);
    startRun(world, 30);
    addItem(world, QStringLiteral("dynamic_tool"), {{QStringLiteral("toolName"), QStringLiteral("Read")}, {QStringLiteral("input"), QJsonObject{{QStringLiteral("file_path"), path}}},
                                                    {QStringLiteral("viewedImagePath"), path}});
  };
  step(QStringLiteral("the agent viewed %1 in the thread's workspace").arg(q), [viewed](World& world, const Captures& c, const Table&) { viewed(world, kRoot + QLatin1Char('/') + c[0]); });
  step(QStringLiteral("the agent viewed %1 outside the workspace").arg(q), [viewed](World& world, const Captures& c, const Table&) { viewed(world, c[0]); });
  step(QStringLiteral("the path is shown and no image is loaded"), [](World& world, const Captures&, const Table&) {
    const QString path = lastCall(world).value(QStringLiteral("viewedPath")).toString();
    QQuickItem* named = drawn(world, QStringLiteral("viewedImagePath"));
    world.sync();
    expect(!path.isEmpty() && named->property("text") == path, QStringLiteral("the details show %1").arg(named->property("text").toString()));
    expect(signedFiles(world).isEmpty() && drawnAll(world, QStringLiteral("viewedImage")).isEmpty(), QStringLiteral("an image was loaded"));
  });

  // An answered question.
  const auto answered = [](World& world, const QJsonObject& answer) {
    startRun(world, 30);
    QJsonObject full{{QStringLiteral("requestId"), QStringLiteral("request-1")}, {QStringLiteral("answers"), QJsonObject{}}, {QStringLiteral("attachmentsByQuestionId"), QJsonObject{}}};
    for (auto it = answer.begin(); it != answer.end(); ++it) full.insert(it.key(), it.value());
    addItem(world, QStringLiteral("user_input_request"), {{QStringLiteral("requestId"), QStringLiteral("request-1")},
                                                          {QStringLiteral("questions"), QJsonArray{QJsonObject{{QStringLiteral("id"), QStringLiteral("q1")}, {QStringLiteral("question"), QStringLiteral("Which database?")}}}},
                                                          {QStringLiteral("questionAnswer"), full}});
  };
  step(QStringLiteral("the agent asked a question that the user answered with %1 and %1").arg(q, q), [answered](World& world, const Captures& c, const Table&) {
    answered(world, {{QStringLiteral("answers"), QJsonObject{{QStringLiteral("q1"), c[0]}, {QStringLiteral("q2"), QJsonArray{c[1]}}}}});
  });
  step(QStringLiteral("the agent asked a question that the user answered with only the files %1 and %1").arg(q, q), [answered](World& world, const Captures& c, const Table&) {
    answered(world, {{QStringLiteral("attachmentsByQuestionId"),
                      QJsonObject{{QStringLiteral("q1"), QJsonArray{QJsonObject{{QStringLiteral("name"), c[0]}}, QJsonObject{{QStringLiteral("name"), c[1]}}}}}}});
  });
  step(QStringLiteral("the agent asked a question that the user answered with nothing but the question %1").arg(q), [answered](World& world, const Captures& c, const Table&) {
    answered(world, {{QStringLiteral("questionTextById"), QJsonObject{{QStringLiteral("q1"), c[0]}}}});
  });
  step(QStringLiteral("the call's row previews %1").arg(q), [](World& world, const Captures& c, const Table&) {
    timelineBrick(world);
    QQuickItem* preview = drawn(world, QStringLiteral("workCallPreview"));
    expect(preview->property("text") == c[0], QStringLiteral("the row previews %1").arg(preview->property("text").toString()));
  });

  // A long group's place.
  step(QStringLiteral("a long group of tool calls that the user scrolled partway down"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addCommands(world, 1, 30);
    timelineBrick(world);
    openGroup(world, 30);
    QQuickItem* view = callsView(world);
    world.waitFor([&] { return endOf(view) > 200; }, QStringLiteral("the group to scroll"));
    view->setProperty("contentY", 150.5);
    world.sync();
  });
  step(QStringLiteral("the user closes the group and opens it again"), [](World& world, const Captures&, const Table&) {
    click(world, drawn(world, QStringLiteral("workGroupToggle")));
    world.waitFor([&] { return callCount(world) < 30; }, QStringLiteral("the group to close"));
    world.waitFor([&] { return drawnAll(world, QStringLiteral("workCalls")).size() == 1 && !drawnAll(world, QStringLiteral("workCalls")).first()->property("interactive").toBool(); },
                  QStringLiteral("the group to stop scrolling"));
    openGroup(world, 30);
  });
  step(QStringLiteral("the group shows the call the user was reading at the same place"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return std::abs(contentY(world) - 150.5) < 0.5; }, [&] { return QStringLiteral("the group to open at 150.5, not %1").arg(contentY(world)); });
  });

  // Following new calls.
  step(QStringLiteral("the user has a long group of tool calls open and is looking at its last call"), [](World& world, const Captures&, const Table&) {
    startRun(world, 30);
    addCommands(world, 1, 30);
    timelineBrick(world);
    openGroup(world, 30);
    QQuickItem* view = callsView(world);
    world.waitFor([&] { return endOf(view) > 200; }, QStringLiteral("the group to scroll"));
    view->setProperty("contentY", endOf(view));
    world.sync();
  });
  step(QStringLiteral("the agent adds another call to the group"), [](World& world, const Captures&, const Table&) {
    addCommand(world, 31);
    world.waitFor([&] { return callCount(world) == 31; }, QStringLiteral("the new call"));
  });
  step(QStringLiteral("the group scrolls to show the new call"), [](World& world, const Captures&, const Table&) {
    QQuickItem* view = callsView(world);
    world.waitFor([&] { return drawnAll(world, QStringLiteral("workCall")).size() >= 31 && std::abs(view->property("contentY").toDouble() - endOf(view)) < 1; },
                  [&] { return QStringLiteral("the group at %1 of %2").arg(view->property("contentY").toDouble()).arg(endOf(view)); });
  });
  step(QStringLiteral("the user has scrolled up in the group and the agent adds another call"), [](World& world, const Captures&, const Table&) {
    callsView(world)->setProperty("contentY", 100.0);
    world.sync();
    addCommand(world, 32);
    world.waitFor([&] { return callCount(world) == 32 && drawnAll(world, QStringLiteral("workCall")).size() >= 32; }, QStringLiteral("the new call"));
  });
  step(QStringLiteral("the group stays where it is"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(contentY(world) == 100.0, QStringLiteral("the group moved to %1").arg(contentY(world)));
  });
  step(QStringLiteral("a call changing its status or output never moves the group"), [](World& world, const Captures&, const Table&) {
    // From the end too: only a call added follows it.
    QQuickItem* view = callsView(world);
    view->setProperty("contentY", endOf(view));
    world.sync();
    const double before = contentY(world);
    const QString id = lastCall(world).value(QStringLiteral("id")).toString();
    set(world, QStringLiteral("turn-item"), id, {{QStringLiteral("status"), QStringLiteral("failed")}, {QStringLiteral("output"), QStringLiteral("1 test failed")}});
    world.waitFor([&] { return lastCall(world).value(QStringLiteral("status")) == QLatin1String("failed"); }, QStringLiteral("the call to change"));
    world.sync();
    expect(contentY(world) == before, QStringLiteral("the group moved from %1 to %2").arg(before).arg(contentY(world)));
  });

  // A turn's changed files.
  step(QStringLiteral("a turn changed %1 with (\\d+) lines added and (\\d+) removed").arg(q), [](World& world, const Captures& c, const Table&) {
    finishTurnWith(world, {changed(c[0], c[1].toInt(), c[2].toInt())});
  });
  step(QStringLiteral("a turn changed %1 and %1 with (\\d+) lines added in all").arg(q, q), [](World& world, const Captures& c, const Table&) {
    const int all = c[2].toInt();
    finishTurnWith(world, {changed(c[0], all - all / 2), changed(c[1], all / 2)});
  });
  step(QStringLiteral("a turn changed %1 and %1 with no line counts").arg(q, q), [](World& world, const Captures& c, const Table&) {
    finishTurnWith(world, {changed(c[0], 0), changed(c[1], 0)});
  });
  step(QStringLiteral("a turn changed %1 with (\\d+) lines added and %1 with (\\d+) lines added").arg(q, q), [](World& world, const Captures& c, const Table&) {
    finishTurnWith(world, {changed(c[0], c[1].toInt()), changed(c[2], c[3].toInt())});
  });
  step(QStringLiteral("a turn changed %1").arg(q), [](World& world, const Captures& c, const Table&) { finishTurnWith(world, {changed(c[0], 2)}); });
  step(QStringLiteral("the changed files' heading reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return !drawnAll(world, QStringLiteral("changedFilesHeading")).isEmpty(); }, QStringLiteral("the changed files"));
    const QString heading = textsOf(drawn(world, QStringLiteral("changedFilesHeading"))).join(QLatin1Char(' '));
    expect(heading == c[0], QStringLiteral("the heading reads \"%1\"").arg(heading));
  });
  step(QStringLiteral("the folder %1 is listed with %1").arg(q, q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return changedRows(world, QStringLiteral("changedFolder")) == QStringList{c[0] + QLatin1Char(' ') + c[1]}; },
                  [&] { return QStringLiteral("the folder; the card lists %1").arg(changedRows(world, QStringLiteral("changedFolder")).join(QLatin1String(", "))); });
  });
  step(QStringLiteral("each file is listed with its own line counts"), [](World& world, const Captures&, const Table&) {
    click(world, changedRow(world, QStringLiteral("changedFolder"), QStringLiteral("src")));
    const QStringList wanted{QStringLiteral("cart.ts +3"), QStringLiteral("checkout.ts +2")};
    world.waitFor([&] { return changedRows(world, QStringLiteral("changedFile")) == wanted; },
                  [&] { return QStringLiteral("the files; the card lists %1").arg(changedRows(world, QStringLiteral("changedFile")).join(QLatin1String(", "))); });
  });
  step(QStringLiteral("the user opens the folder %1 of the changed files").arg(q), [](World& world, const Captures& c, const Table&) {
    threadBrick(world);
    click(world, changedRow(world, QStringLiteral("changedFolder"), c[0]));
  });
  step(QStringLiteral("\"([^\"]*\\.[^\"]*)\" is listed under %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* file = changedRow(world, QStringLiteral("changedFile"), c[0]);
    const QVariantMap row = file->property("modelData").toMap();
    expect(row.value(QStringLiteral("depth")) == 1 && row.value(QStringLiteral("path")).toString().startsWith(c[1] + QLatin1Char('/')),
           QStringLiteral("%1 is listed as %2").arg(c[0], show(row)));
  });
  step(QStringLiteral("the folder %1 is still shown with its files hidden").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* folder = changedRow(world, QStringLiteral("changedFolder"), c[0]);
    const QStringList files = changedRows(world, QStringLiteral("changedFile"));
    expect(!folder->property("modelData").toMap().value(QStringLiteral("expanded")).toBool() && files.size() == 1,
           QStringLiteral("the card lists %1").arg(files.join(QLatin1String(", "))));
  });
  step(QStringLiteral("a turn's changed files have all their folders expanded"), [](World& world, const Captures&, const Table&) {
    finishTurnWith(world, {changed(QStringLiteral("src/cart.ts"), 2), changed(QStringLiteral("test/cart.test.ts"), 1)});
    click(world, drawn(world, QStringLiteral("changedFoldersToggle")));
    world.waitFor([&] { return drawnAll(world, QStringLiteral("changedFile")).size() == 2; }, QStringLiteral("the folders to open"));
  });
  step(QStringLiteral("the user opens another thread and comes back"), [](World& world, const Captures&, const Table&) {
    const QString other = QStringLiteral("thread-2");
    world.mc.threads.insert(other, {{QStringLiteral("id"), other}, {QStringLiteral("title"), QStringLiteral("Checkout")}, {QStringLiteral("projectId"), kProject},
                                    {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")}, {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
    world.mc.sendRow(other, world.mc.threads.value(other));
    world.sync();
    look(world, world.mc.environmentId + QLatin1Char(':') + other, false);
    world.waitFor([&] { return drawnAll(world, QStringLiteral("changedFolder")).isEmpty(); }, QStringLiteral("the other thread to show"));
    look(world, world.mc.environmentId + QLatin1Char(':') + kThread, false);
  });
  step(QStringLiteral("the turn's changed files still have all their folders expanded"), [](World& world, const Captures&, const Table&) {
    const QStringList wanted{QStringLiteral("cart.test.ts +1"), QStringLiteral("cart.ts +2")};
    world.waitFor([&] { return changedRows(world, QStringLiteral("changedFile")) == wanted; },
                  [&] { return QStringLiteral("the files; the card lists %1").arg(changedRows(world, QStringLiteral("changedFile")).join(QLatin1String(", "))); });
  });
  step(QStringLiteral("the changed files are listed without a control to expand or collapse folders"), [](World& world, const Captures&, const Table&) {
    const QStringList wanted{QStringLiteral("README.md +2"), QStringLiteral("package.json +2")};
    world.waitFor([&] { return changedRows(world, QStringLiteral("changedFile")) == wanted; },
                  [&] { return QStringLiteral("the files; the card lists %1").arg(changedRows(world, QStringLiteral("changedFile")).join(QLatin1String(", "))); });
    // The turn before it changed a folder; only this turn's card counts.
    const double top = drawn(world, QStringLiteral("changedFilesHeading"))->mapToScene(QPointF()).y() - 40;
    for (const QString& name : {QStringLiteral("changedFoldersToggle"), QStringLiteral("changedFolder")}) {
      for (QQuickItem* item : drawnAll(world, name)) expect(item->mapToScene(QPointF()).y() < top, QStringLiteral("the card offers to open folders"));
    }
  });
  const auto rightClick = [](World& world, const QString& path) {
    if (path.contains(QLatin1Char('/')) && drawnAll(world, QStringLiteral("changedFile")).isEmpty()) {
      click(world, drawn(world, QStringLiteral("changedFoldersToggle")));
    }
    click(world, drawn(world, QStringLiteral("changedFile"), [&](QQuickItem* item) { return item->property("modelData").toMap().value(QStringLiteral("path")) == path; }),
          Qt::RightButton);
    world.sync();
  };
  step(QStringLiteral("the user right-clicks %1 in the changed files").arg(q), [rightClick](World& world, const Captures& c, const Table&) { rightClick(world, c[0]); });
  step(QStringLiteral("the menu offers what the environment can do with that file"), [](World& world, const Captures&, const Table&) {
    QObject* menu = world.brick->root()->findChild<QObject*>(QStringLiteral("fileEntryMenu"));
    world.waitFor([&] { return menu && menu->property("visible").toBool(); }, QStringLiteral("the file's menu"));
    expect(menu->property("path") == QLatin1String("src/cart.ts"), QStringLiteral("the menu is for %1").arg(menu->property("path").toString()));
    QStringList offered;
    for (int index = 0; index < menu->property("count").toInt(); ++index) {
      QQuickItem* item = nullptr;
      QMetaObject::invokeMethod(menu, "itemAt", Q_RETURN_ARG(QQuickItem*, item), Q_ARG(int, index));
      if (item && item->isVisible()) offered.append(item->objectName());
    }
    expect(offered.contains(QStringLiteral("fileEntryOpen")) && offered.contains(QStringLiteral("fileEntryCopyMention")) && offered.contains(QStringLiteral("fileEntryAddToChat")),
           QStringLiteral("the menu offers %1").arg(offered.join(QLatin1String(", "))));
    QMetaObject::invokeMethod(menu, "close");
    world.waitFor([&] { return !menu->property("visible").toBool(); }, QStringLiteral("the menu to close"));
  });
  step(QStringLiteral("a file that cannot be located on the environment's machine offers nothing"), [rightClick](World& world, const Captures&, const Table&) {
    // The project's folder is not on the environment's machine.
    QJsonObject project = world.mc.projects.value(kProject);
    project.remove(QStringLiteral("workspaceRoot"));
    world.mc.projects.insert(kProject, project);
    world.mc.sendRow(kProject, project, QStringLiteral("project"));
    world.sync();
    world.waitFor([&] { return !world.brick->root()->findChild<QObject*>(QStringLiteral("threadTimeline"))->property("locatable").toBool(); },
                  QStringLiteral("the workspace to be gone"));
    rightClick(world, QStringLiteral("src/cart.ts"));
    expect(!world.brick->root()->findChild<QObject*>(QStringLiteral("fileEntryMenu"))->property("visible").toBool(), QStringLiteral("the menu opened"));
  });
});

}  // namespace

// "the image is shown" for an image a tool call viewed; FilesMediaSteps owns
// the step and asks here first. False when the brick is not a timeline.
bool expectViewedImage(World& world) {
  if (!world.brick || !world.brick->root()->property("groupAnchors").isValid()) return false;
  world.waitFor([&] {
    const QList<QQuickItem*> images = drawnAll(world, QStringLiteral("viewedImage"));
    return !images.isEmpty() && images.first()->property("status").toInt() == 1 && images.first()->height() > 0;
  }, [&] { return QStringLiteral("the image to load; the client signed %1").arg(signedFiles(world).size()); });
  const QList<QJsonObject> files = signedFiles(world);
  expect(files.size() == 1 && files.first().value(QLatin1String("_tag")) == QLatin1String("workspace-file") &&
             files.first().value(QLatin1String("path")) == QLatin1String("assets/logo.png") && files.first().value(QLatin1String("threadId")) == stream::kThread,
         QStringLiteral("the client signed %1 files").arg(files.size()));
  return true;
}
