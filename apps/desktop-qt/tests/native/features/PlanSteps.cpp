// What the user does with a proposed plan besides implementing it in place
// (PlanController; features/timeline/plans-and-subagents.feature): a new
// thread that carries it out, and copies of it on the clipboard, in the
// Downloads folder and in the workspace. Driven from the plan card's menu on
// the TurnRequests brick; the plan is TurnSteps' ("# Tax line" on thread-1).

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QTest>

#include <memory>

#include "Brick.h"
#include "Harness.h"
#include "NavigationController.h"
#include "PlanController.h"
#include "Stream.h"
#include "World.h"

namespace {

using namespace stream;

const QString kPlan = QStringLiteral("# Tax line\n\n- Add the line\n- Test it\n");

// What the MC's `projects.writeFile` was asked to write.
struct FakeWrites {
  QList<QJsonObject> files;
};

QString downloads(World& world) {
  return QDir(world.homeDir()).filePath(QStringLiteral("downloads"));
}

// An entry of the plan card's menu.
void choose(World& world, const QString& entry) {
  world.native().controller<PlanController>()->setDownloadDirectory(downloads(world));
  world.mc.onRpc(QStringLiteral("projects.writeFile"), [&mc = world.mc](const FakeMc::Rpc& rpc) {
    mc.part<FakeWrites>().files.append(rpc.payload);
    mc.reply(rpc, QJsonObject{{QStringLiteral("relativePath"), rpc.payload.value(QLatin1String("relativePath"))}});
  });
  if (!world.brick) world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nTurnRequests {}\n", QSize(820, 500));
  Brick& brick = *world.brick;
  world.waitFor([&] { return brick.shows(QStringLiteral("Tax line")); }, QStringLiteral("the plan card to be drawn"));
  brick.click(QStringLiteral("planMore"));
  world.waitFor([&] { return brick.item(entry)->isVisible(); }, QStringLiteral("the plan's actions to open"));
  brick.click(entry);
  world.sync();
}

void saveTo(World& world, const QString& path) {
  choose(world, QStringLiteral("planSave"));
  Brick& brick = *world.brick;
  world.waitFor([&] { return brick.item(QStringLiteral("planSavePath"))->isVisible(); }, QStringLiteral("the save dialog to open"));
  brick.click(QStringLiteral("planSavePath"));
  for (const QChar ch : path) QTest::keyClick(&brick.window(), ch.toLatin1());
  brick.click(QStringLiteral("planSaveConfirm"));
  world.sync();
}

QList<QJsonObject> launches(World& world) {
  QList<QJsonObject> found;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == QLatin1String("orchestration.launchThread")) found.append(rpc.payload);
  }
  return found;
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the user implements the plan in a new thread"), [](World& world, const Captures&, const Table&) {
    choose(world, QStringLiteral("planNewThread"));
  });
  step(QStringLiteral("a new thread starts implementing the plan"), [](World& world, const Captures&, const Table&) {
    const QList<QJsonObject> launched = launches(world);
    expect(launched.size() == 1, QStringLiteral("the MC was asked to start %1 threads").arg(launched.size()));
    const QJsonObject launch = launched.first();
    const QString threadId = launch.value(QLatin1String("threadId")).toString();
    expect(!threadId.isEmpty() && threadId != kThread && launch.value(QLatin1String("projectId")) == kProject &&
               launch.value(QLatin1String("title")) == QLatin1String("Implement Tax line") && launch.value(QLatin1String("interactionMode")) == QLatin1String("default") &&
               launch.value(QLatin1String("workspaceStrategy")).toObject().value(QLatin1String("type")) == QLatin1String("root"),
           QStringLiteral("the MC was asked to start %1").arg(show(launch.toVariantMap())));
    // The thread first, then its first message.
    QJsonObject message;
    world.waitFor([&] {
      for (const QJsonObject& command : std::as_const(world.mc.commands)) {
        if (command.value(QLatin1String("type")) == QLatin1String("message.dispatch")) message = command;
      }
      return !message.isEmpty();
    }, [&] { return QStringLiteral("the thread's first message; the MC has %1").arg(world.describeCommands()); });
    const QJsonObject ref = message.value(QLatin1String("sourcePlanRef")).toObject();
    expect(message.value(QLatin1String("threadId")) == threadId &&
               message.value(QLatin1String("text")).toString() == QLatin1String("PLEASE IMPLEMENT THIS PLAN:\n# Tax line\n\n- Add the line\n- Test it") &&
               ref.value(QLatin1String("threadId")) == kThread && ref.value(QLatin1String("planId")) == QLatin1String("plan-1"),
           QStringLiteral("the MC was sent %1").arg(show(message.toVariantMap())));
    // The window moves to the new thread.
    const QString key = world.mc.environmentId + QLatin1Char(':') + threadId;
    world.waitFor([&] { return world.native().controller<NavigationController>()->threadKey() == key; },
                  [&] { return QStringLiteral("the new thread to open; the window shows %1").arg(world.native().controller<NavigationController>()->threadKey()); });
  });
  step(QStringLiteral("the planning thread keeps the plan"), [](World& world, const Captures&, const Table&) {
    // Its plan card is still in its timeline, and nothing was sent to it.
    TimelineModel* planning = store(world)->timeline(world.mc.environmentId + QLatin1Char(':') + kThread);
    expect(planning != nullptr, QStringLiteral("the planning thread is gone"));
    bool card = false;
    for (int row = 0; row < planning->rowCount(); ++row) {
      card = card || (role(*planning, row, TimelineModel::KindRole) == QLatin1String("plan") && role(*planning, row, TimelineModel::TitleRole) == QLatin1String("Tax line"));
    }
    expect(card, QStringLiteral("the planning thread shows %1").arg(describe(*planning)));
    for (const QJsonObject& command : std::as_const(world.mc.commands)) {
      expect(command.value(QLatin1String("threadId")) != kThread, QStringLiteral("the planning thread was sent %1").arg(show(command.toVariantMap())));
    }
  });
  step(QStringLiteral("the environment cannot start a new thread"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(QStringLiteral("orchestration.launchThread"), QStringLiteral("Provider unavailable"));
  });

  step(QStringLiteral("the user copies the plan"), [](World& world, const Captures&, const Table&) { choose(world, QStringLiteral("planCopy")); });
  step(QStringLiteral("the plan's markdown is on the clipboard"), [](World& world, const Captures&, const Table&) {
    expect(world.clipboard == kPlan, QStringLiteral("the clipboard holds \"%1\"").arg(world.clipboard));
  });
  step(QStringLiteral("the user downloads the plan"), [](World& world, const Captures&, const Table&) { choose(world, QStringLiteral("planDownload")); });
  step(QStringLiteral("a markdown file of the plan is saved"), [](World& world, const Captures&, const Table&) {
    QFile file(QDir(downloads(world)).filePath(QStringLiteral("tax-line.md")));
    expect(file.open(QIODevice::ReadOnly), QStringLiteral("%1 was not written: %2").arg(file.fileName(), QDir(downloads(world)).entryList(QDir::Files).join(u", ")));
    const QString written = QString::fromUtf8(file.readAll());
    expect(written == kPlan, QStringLiteral("the file holds \"%1\"").arg(written));
    // A second download does not write over the first.
    choose(world, QStringLiteral("planDownload"));
    expect(QFile::exists(QDir(downloads(world)).filePath(QStringLiteral("tax-line (2).md"))),
           QStringLiteral("the downloads are %1").arg(QDir(downloads(world)).entryList(QDir::Files).join(u", ")));
  });
  step(QStringLiteral("the user saves the plan to %1").arg(q), [](World& world, const Captures& c, const Table&) { saveTo(world, c[0]); });
  step(QStringLiteral("%1 holds the plan in the workspace").arg(q), [](World& world, const Captures& c, const Table&) {
    const QList<QJsonObject> files = world.mc.part<FakeWrites>().files;
    expect(files.size() == 1 && files.first().value(QLatin1String("cwd")) == QLatin1String("/work/shop") &&
               files.first().value(QLatin1String("relativePath")) == c[0] && files.first().value(QLatin1String("contents")) == kPlan,
           QStringLiteral("the MC was asked to write %1").arg(files.isEmpty() ? QStringLiteral("nothing") : show(files.first().toVariantMap())));
  });
  step(QStringLiteral("the thread's workspace is unavailable"), [](World& world, const Captures&, const Table&) {
    QJsonObject project = world.mc.projects.value(kProject);
    project.remove(QStringLiteral("workspaceRoot"));
    world.mc.projects.insert(kProject, project);
    world.mc.sendRow(kProject, QJsonObject{{QStringLiteral("id"), kProject}, {QStringLiteral("title"), kProject}, {QStringLiteral("scripts"), QJsonArray()},
                                          {QStringLiteral("workspaceRoot"), QJsonValue()}},
                     QStringLiteral("project"));
    world.sync();
  });
  step(QStringLiteral("the user saves the plan to the workspace"), [](World& world, const Captures&, const Table&) {
    saveTo(world, QStringLiteral("docs/tax-plan.md"));
    expect(world.mc.part<FakeWrites>().files.isEmpty(), QStringLiteral("the MC was asked to write a file"));
  });
});

}  // namespace
