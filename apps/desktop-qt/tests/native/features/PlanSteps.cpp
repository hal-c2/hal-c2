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
#include <optional>

#include "Brick.h"
#include "Harness.h"
#include "NavigationController.h"
#include "PlanController.h"
#include "Stream.h"
#include "Turn.h"
#include "World.h"

namespace {

using namespace stream;

const QString kPlan = QStringLiteral("# Tax line\n\n- Add the line\n- Test it\n");

// What the MC's `projects.writeFile` was asked to write, and why it refuses
// to when `refusal` is set.
struct FakeWrites {
  QList<QJsonObject> files;
  std::optional<QString> refusal;
};

QString downloads(World& world) {
  return QDir(world.homeDir()).filePath(QStringLiteral("downloads"));
}

// An entry of the plan card's menu.
void choose(World& world, const QString& entry) {
  world.native().controller<PlanController>()->setDownloadDirectory(downloads(world));
  world.mc.onRpc(QStringLiteral("projects.writeFile"), [&mc = world.mc](const FakeMc::Rpc& rpc) {
    FakeWrites& writes = mc.part<FakeWrites>();
    if (writes.refusal) return mc.refuse(rpc, *writes.refusal);
    writes.files.append(rpc.payload);
    mc.reply(rpc, QJsonObject{{QStringLiteral("relativePath"), rpc.payload.value(QLatin1String("relativePath"))}});
  });
  Brick& brick = turnRequestsBrick(world);
  world.waitFor([&] { return brick.find(QStringLiteral("planMore")) && brick.find(QStringLiteral("planMore"))->isVisible(); },
                QStringLiteral("the plan card to be drawn"));
  brick.click(QStringLiteral("planMore"));
  world.waitFor([&] { return brick.item(entry)->isVisible(); }, QStringLiteral("the plan's actions to open"));
  brick.click(entry);
  world.sync();
}

// Whether the plan's thread has a workspace to save into: without one the
// menu only says so, and no dialog opens.
bool hasWorkspace(World& world) {
  return !at(world.state(QStringLiteral("turn")), QStringLiteral("plan.workspaceRoot")).toString().isEmpty();
}

// The save dialog, open.
void askWhere(World& world) {
  choose(world, QStringLiteral("planSave"));
  Brick& brick = *world.brick;
  world.waitFor([&] { return brick.item(QStringLiteral("planSavePath"))->isVisible(); }, QStringLiteral("the save dialog to open"));
}

// Saves to `path`, typed over the file name the dialog starts from, or to
// that file name when there is no `path`.
void saveTo(World& world, const std::optional<QString>& path = {}) {
  if (!hasWorkspace(world)) return choose(world, QStringLiteral("planSave"));
  askWhere(world);
  Brick& brick = *world.brick;
  if (path) {
    brick.click(QStringLiteral("planSavePath"));
    QTest::keyClick(&brick.window(), Qt::Key_A, Qt::ControlModifier);
    if (path->isEmpty()) QTest::keyClick(&brick.window(), Qt::Key_Backspace);
    for (const QChar ch : *path) QTest::keyClick(&brick.window(), ch.toLatin1());
  }
  brick.click(QStringLiteral("planSaveConfirm"));
  world.sync();
}

QString fieldText(World& world, const QString& name) {
  QQuickItem* item = world.brick ? world.brick->find(name) : nullptr;
  return item ? item->property("text").toString() : QString();
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
    saveTo(world);
    if (!hasWorkspace(world)) expect(world.mc.part<FakeWrites>().files.isEmpty(), QStringLiteral("the MC was asked to write a file"));
  });

  // The copy's name, and the save dialog (ProposedPlanCard).
  step(QStringLiteral("the new thread is titled %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QList<QJsonObject> launched = launches(world);
    expect(!launched.isEmpty() && launched.last().value(QLatin1String("title")) == c[0],
           QStringLiteral("the MC was asked to start %1").arg(launched.isEmpty() ? QStringLiteral("nothing") : show(launched.last().toVariantMap())));
  });
  step(QStringLiteral("the file is named %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QStringList files = QDir(downloads(world)).entryList(QDir::Files);
    expect(files == QStringList{c[0]}, QStringLiteral("the downloads are %1").arg(files.join(u", ")));
  });
  step(QStringLiteral("the user (?:chooses to save the plan to the workspace|is asked where in the workspace to save it)"), [](World& world, const Captures&, const Table&) {
    askWhere(world);
  });
  step(QStringLiteral("the user is asked for a path relative to the workspace"), [](World& world, const Captures&, const Table&) {
    const QString hint = fieldText(world, QStringLiteral("planSaveHint"));
    expect(world.brick->item(QStringLiteral("planSavePath"))->isVisible() && hint == QLatin1String("Enter a path relative to /work/shop."),
           QStringLiteral("the dialog says \"%1\"").arg(hint));
  });
  step(QStringLiteral("the path starts as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString path = fieldText(world, QStringLiteral("planSavePath"));
    expect(path == c[0], QStringLiteral("the path reads \"%1\"").arg(path));
  });
  step(QStringLiteral("the user clears the path and saves"), [](World& world, const Captures&, const Table&) {
    Brick& brick = *world.brick;
    brick.click(QStringLiteral("planSavePath"));
    QTest::keyClick(&brick.window(), Qt::Key_A, Qt::ControlModifier);
    QTest::keyClick(&brick.window(), Qt::Key_Backspace);
    brick.click(QStringLiteral("planSaveConfirm"));
    world.sync();
  });
  step(QStringLiteral("nothing is written to the workspace"), [](World& world, const Captures&, const Table&) {
    const QList<QJsonObject> files = world.mc.part<FakeWrites>().files;
    expect(files.isEmpty(), QStringLiteral("the MC was asked to write %1").arg(files.isEmpty() ? QString() : show(files.first().toVariantMap())));
  });
  step(QStringLiteral("the workspace refuses the write"), [](World& world, const Captures&, const Table&) {
    world.mc.part<FakeWrites>().refusal = QStringLiteral("EACCES: permission denied");
    world.reason = QStringLiteral("EACCES: permission denied");
  });
  step(QStringLiteral("the user can try another path"), [](World& world, const Captures&, const Table&) {
    Brick& brick = *world.brick;
    world.waitFor([&] { return brick.item(QStringLiteral("planSaveConfirm"))->isEnabled(); }, QStringLiteral("the save to settle"));
    expect(brick.item(QStringLiteral("planSavePath"))->isVisible() && fieldText(world, QStringLiteral("planSavePath")) == QLatin1String("docs/tax-plan.md"),
           QStringLiteral("the save dialog closed"));
  });
  step(QStringLiteral("the plan is kept whole with its title and ends with a single newline"), [](World& world, const Captures&, const Table&) {
    const QString expected = QStringLiteral("# Tax line\n\n- Add the line\n- Test it\n");
    QStringList kept;
    if (!world.clipboard.isEmpty()) kept.append(world.clipboard);
    QFile file(QDir(downloads(world)).filePath(QStringLiteral("tax-line.md")));
    if (file.open(QIODevice::ReadOnly)) kept.append(QString::fromUtf8(file.readAll()));
    world.waitFor([&] { return !world.mc.part<FakeWrites>().files.isEmpty() || !kept.isEmpty(); }, QStringLiteral("the plan to be kept"));
    for (const QJsonObject& write : world.mc.part<FakeWrites>().files) kept.append(write.value(QLatin1String("contents")).toString());
    expect(kept.size() == 1 && kept.first() == expected, QStringLiteral("the plan was kept as [%1]").arg(kept.join(QStringLiteral("], ["))));
  });
});

}  // namespace
