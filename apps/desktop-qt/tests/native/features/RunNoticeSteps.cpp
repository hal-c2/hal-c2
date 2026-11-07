// What the open thread says about its runs over and under its conversation
// (features/timeline/runs-and-queue.feature): background work its finished
// turn left running, which stops from the notice under the conversation
// (ThreadNoticeController), and the thread's error over its top, which
// dismisses (ThreadErrorController). Both are drawn in the ThreadView brick;
// the fake MC's thread row says what the MC would.

#include <QDir>
#include <QImage>
#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>
#include <QRegularExpression>

#include "Brick.h"
#include "Harness.h"
#include "LocalCache.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "RunNotices.h"
#include "Stream.h"
#include "ThreadList.h"
#include "World.h"

using namespace stream;

namespace {

// Whether the scenario showed the thread's error, so "the user dismisses the
// error" is this one's and not the Device tab's.
struct ThreadErrorShown {
  bool shown = false;
};

Brick& threadView(World& world) {
  if (!world.brick) {
    world.brick = std::make_unique<Brick>(world, "import QtQuick\nimport HalC2.Bricks\nThreadView {}\n", QSize(820, 560));
  }
  return *world.brick;
}

// With HAL_C2_SHOTS set, the brick as drawn now goes to <dir>/<name>.png,
// for a pull request's pictures.
void shoot(World& world, const QString& name) {
  const QString dir = qEnvironmentVariable("HAL_C2_SHOTS");
  if (dir.isEmpty()) return;
  QDir().mkpath(dir);
  threadView(world).grab().save(QDir(dir).filePath(name + QStringLiteral(".png")));
}

QVariantMap notice(World& world) {
  return world.state(QStringLiteral("threadNotice")).toMap();
}

QVariantMap threadError(World& world) {
  return world.state(QStringLiteral("threadError")).toMap();
}

QString seen(World& world) {
  return QStringLiteral("threadNotice is %1; threadError is %2")
      .arg(show(world.state(QStringLiteral("threadNotice"))), show(world.state(QStringLiteral("threadError"))));
}

QString text(QQuickItem* item) {
  return item ? item->property("text").toString() : QString();
}

// The quoted names in `words` ("the tasks "a" and "b"").
QStringList quoted(const QString& words) {
  QStringList names;
  static const QRegularExpression name(QStringLiteral("\"([^\"]*)\""));
  for (auto it = name.globalMatch(words); it.hasNext();) names.append(it.next().captured(1));
  return names;
}

void leaveRunning(World& world, const QStringList& tasks) {
  updateThreadRow(world, kThread, [&](QJsonObject& row) {
    QJsonArray pending;
    for (qsizetype i = 0; i < tasks.size(); ++i) {
      pending.append(QJsonObject{{QStringLiteral("taskId"), QStringLiteral("task-%1").arg(i + 1)}, {QStringLiteral("description"), tasks[i]}});
    }
    row.insert(QStringLiteral("latestRunId"), QStringLiteral("run-1"));
    row.insert(QStringLiteral("activeRunId"), QJsonValue::Null);
    row.insert(QStringLiteral("status"), QStringLiteral("completed"));
    row.insert(QStringLiteral("pendingBackgroundTasks"), pending);
  });
}

// The notice under the conversation, drawn, once it reads `title`.
QQuickItem* noticeSays(World& world, const QString& title) {
  Brick& view = threadView(world);
  world.waitFor(
      [&] {
        QQuickItem* shown = view.find(QStringLiteral("threadNotice"));
        return shown && shown->isVisible() && text(view.find(QStringLiteral("threadNoticeTitle"))) == title;
      },
      [&] { return QStringLiteral("the thread to say \"%1\"; %2").arg(title, seen(world)); });
  return view.item(QStringLiteral("threadNotice"));
}

qsizetype interrupts(World& world) {
  return std::count_if(world.mc.commands.cbegin(), world.mc.commands.cend(), [](const QJsonObject& command) {
    return command.value(QLatin1String("type")) == QLatin1String("run.interrupt");
  });
}

// Presses the notice's Stop, and waits until the MC has the interrupt.
void stopFromNotice(World& world) {
  Brick& view = threadView(world);
  world.waitFor([&] { return text(view.find(QStringLiteral("threadNoticeAction"))) == QLatin1String("Stop"); },
                [&] { return QStringLiteral("the notice to offer Stop; %1").arg(seen(world)); });
  const qsizetype before = interrupts(world);
  view.click(QStringLiteral("threadNoticeAction"));
  world.waitFor([&] { return interrupts(world) > before; }, [&] { return QStringLiteral("the MC to be asked to stop; %1").arg(seen(world)); });
  const QJsonObject command = world.mc.commands.last();
  expect(command.value(QLatin1String("threadId")) == kThread && !command.contains(QLatin1String("runId")), show(command.toVariantMap()));
}

// The error over the conversation, drawn, once it reads `message`.
void errorShows(World& world, const QString& message) {
  Brick& view = threadView(world);
  world.waitFor(
      [&] {
        QQuickItem* banner = view.find(QStringLiteral("threadError"));
        return banner && banner->isVisible() && text(view.find(QStringLiteral("threadErrorMessage"))) == message &&
               threadError(world).value(QStringLiteral("message")) == message;
      },
      [&] { return QStringLiteral("the thread to show the error \"%1\"; %2").arg(message, seen(world)); });
}

void showError(World& world, const QString& message) {
  updateThreadRow(world, kThread, [&](QJsonObject& row) { row.insert(QStringLiteral("lastError"), message); });
  world.mc.part<ThreadErrorShown>().shown = true;
  errorShows(world, message);
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the turn has finished and left (the tasks? .+?) running(?: in the background)?"),
       [](World& world, const Captures& c, const Table&) {
         const QStringList tasks = quoted(c[0]);
         expect(!tasks.isEmpty(), c[0]);
         threadView(world);
         leaveRunning(world, tasks);
         world.waitFor([&] { return notice(world).value(QStringLiteral("kind")) == QLatin1String("background"); },
                       [&] { return QStringLiteral("the thread to say what it waits on; %1").arg(seen(world)); });
       });
  step(QStringLiteral("it names each task by its description"), [](World& world, const Captures&, const Table&) {
    QStringList tasks;
    for (const QJsonValue& task : world.mc.threads.value(kThread).value(QLatin1String("pendingBackgroundTasks")).toArray()) {
      tasks.append(task[QLatin1String("description")].toString());
    }
    Brick& view = threadView(world);
    world.waitFor([&] { return text(view.find(QStringLiteral("threadNoticeDescription"))) == tasks.join(QStringLiteral(", ")); },
                  [&] { return QStringLiteral("the notice to name %1; %2").arg(tasks.join(QStringLiteral(", ")), seen(world)); });
    shoot(world, QStringLiteral("background-%1").arg(tasks.size()));
  });
  step(QStringLiteral("the user can stop them from that notice"), [](World& world, const Captures&, const Table&) { stopFromNotice(world); });
  step(QStringLiteral("the user stops the background work and the environment accepts"), [](World& world, const Captures&, const Table&) {
    stopFromNotice(world);
    // While the MC answers the notice says so, and once it has, Stop is back.
    world.waitFor([&] { return notice(world).value(QStringLiteral("busy")) == false; }, [&] { return seen(world); });
  });
  step(QStringLiteral("the user stops the background work"), [](World& world, const Captures&, const Table&) { stopFromNotice(world); });
  step(QStringLiteral("%1 is still running").arg(q), [](World& world, const Captures& c, const Table&) {
    // The MC's row still has it: an interrupt does not wait for the work to end.
    expect(world.mc.threads.value(kThread).value(QLatin1String("pendingBackgroundTasks")).toArray().size() == 1, c[0]);
    world.sync();
    expect(notice(world).value(QStringLiteral("description")) == c[0], seen(world));
  });
  step(QStringLiteral("the user can ask to stop it again"), [](World& world, const Captures&, const Table&) {
    const qsizetype before = interrupts(world);
    stopFromNotice(world);
    expect(interrupts(world) == before + 1, seen(world));
  });
  step(QStringLiteral("the environment rejects the stop"), [](World& world, const Captures&, const Table&) {
    world.mc.refusals.insert(QStringLiteral("run.interrupt"), QStringLiteral("The provider session has already exited."));
  });
  step(QStringLiteral("the thread shows the reason as its error"), [](World& world, const Captures&, const Table&) {
    world.mc.part<ThreadErrorShown>().shown = true;
    errorShows(world, QStringLiteral("The provider session has already exited."));
    shoot(world, QStringLiteral("background-stop-refused"));
  });
  step(QStringLiteral("the notice about %1 stays").arg(q), [](World& world, const Captures& c, const Table&) {
    noticeSays(world, QStringLiteral("Waiting on background task"));
    world.waitFor([&] { return notice(world).value(QStringLiteral("busy")) == false; }, [&] { return seen(world); });
    expect(text(threadView(world).find(QStringLiteral("threadNoticeDescription"))) == c[0], seen(world));
  });

  // Work an earlier turn left running, whose run the timeline has not
  // loaded: the stop names no run, and the notice reads the thread's row.
  step(QStringLiteral("an earlier turn left the task %1 running").arg(q), [](World& world, const Captures& c, const Table&) {
    threadView(world);
    leaveRunning(world, {c[0]});
    noticeSays(world, QStringLiteral("Waiting on background task"));
  });
  step(QStringLiteral("that turn is older than the part of the thread the client has loaded"), [](World& world, const Captures&, const Table&) {
    const QString key = world.mc.environmentId + QLatin1Char(':') + kThread;
    world.native().controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("home")));
    store(world)->close(key);
    world.native().cache()->forgetThread(key);
    world.sync();
    // More turns than a client opens a thread with (TimelineModel::windowItems).
    seedTurns(world, 12, 23);
    updateThreadRow(world, kThread, [&](QJsonObject& row) { row.insert(QStringLiteral("latestRunId"), world.mc.part<FakeStreams>().run); });
    look(world, key);
    TimelineModel& model = timeline(world);
    expect(model.hasEarlier() && role(model, 0, TimelineModel::TextRole).toString() != QLatin1String("Question 1"),
           QStringLiteral("the thread opened whole: %1 rows from \"%2\"").arg(model.rowCount()).arg(role(model, 0, TimelineModel::TextRole).toString()));
    noticeSays(world, QStringLiteral("Waiting on background task"));
  });
  // Once the turn settled, the notice's Stop is the thread's.
  step(QStringLiteral("the user stops the thread"), [](World& world, const Captures&, const Table&) { stopFromNotice(world); });
  step(QStringLiteral("%1 is stopped").arg(q), [](World& world, const Captures& c, const Table&) {
    // The MC stops what the provider session has running and its row lists it no more.
    updateThreadRow(world, kThread, [](QJsonObject& row) { row.insert(QStringLiteral("pendingBackgroundTasks"), QJsonArray()); });
    world.waitFor([&] { return world.state(QStringLiteral("threadNotice")).isNull(); }, [&] { return QStringLiteral("%1 to stop; %2").arg(c[0], seen(world)); });
  });

  step(QStringLiteral("a turn is running and has started background tasks"), [](World& world, const Captures&, const Table&) {
    threadView(world);
    updateThreadRow(world, kThread, [](QJsonObject& row) {
      row.insert(QStringLiteral("latestRunId"), QStringLiteral("run-1"));
      row.insert(QStringLiteral("activeRunId"), QStringLiteral("run-1"));
      row.insert(QStringLiteral("status"), QStringLiteral("running"));
      row.insert(QStringLiteral("pendingBackgroundTasks"),
                 QJsonArray{QJsonObject{{QStringLiteral("taskId"), QStringLiteral("task-1")}, {QStringLiteral("description"), QStringLiteral("watch tests")}}});
    });
  });
  step(QStringLiteral("the thread shows no notice about background work"), [](World& world, const Captures&, const Table&) {
    world.sync();
    QQuickItem* shown = threadView(world).find(QStringLiteral("threadNotice"));
    expect(world.state(QStringLiteral("threadNotice")).isNull() && !(shown && shown->isVisible()), seen(world));
  });
  step(QStringLiteral("stopping the turn is the way to stop them"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return at(world.state(QStringLiteral("turn")), QStringLiteral("running")).toBool(); },
                  [&] { return QStringLiteral("the composer to offer stopping the turn; turn is %1").arg(show(world.state(QStringLiteral("turn")))); });
  });

  step(QStringLiteral("the thread shows the error %1").arg(q), [](World& world, const Captures& c, const Table&) {
    threadView(world);
    showError(world, c[0]);
    shoot(world, QStringLiteral("thread-error"));
  });
  step(QStringLiteral("the error is hidden for this thread"), [](World& world, const Captures&, const Table&) {
    Brick& view = threadView(world);
    world.waitFor(
        [&] {
          QQuickItem* banner = view.find(QStringLiteral("threadError"));
          return world.state(QStringLiteral("threadError")).isNull() && !(banner && banner->isVisible());
        },
        [&] { return seen(world); });
    // The MC's row still says it.
    expect(!world.mc.threads.value(kThread).value(QLatin1String("lastError")).toString().isEmpty(), seen(world));
    shoot(world, QStringLiteral("thread-error-dismissed"));
  });
  step(QStringLiteral("a different error on the same thread is still shown"), [](World& world, const Captures&, const Table&) {
    showError(world, QStringLiteral("Provider crashed"));
  });
  // A later run: the MC's row names it as the thread's latest; one that
  // completes clears the thread's error (HalC2.Projection.ThreadError).
  step(QStringLiteral("a later run of the thread (fails with %1|completes)").arg(q), [](World& world, const Captures& c, const Table&) {
    updateThreadRow(world, kThread, [&](QJsonObject& row) {
      const bool failed = !c[1].isEmpty();
      row.insert(QStringLiteral("latestRunId"), QStringLiteral("run-later"));
      row.insert(QStringLiteral("status"), failed ? QStringLiteral("failed") : QStringLiteral("completed"));
      row.insert(QStringLiteral("lastError"), failed ? QJsonValue(c[1]) : QJsonValue());
    });
  });
  step(QStringLiteral("the thread shows %1 as its error").arg(q), [](World& world, const Captures& c, const Table&) { errorShows(world, c[0]); });
  step(QStringLiteral("the thread shows no error"), [](World& world, const Captures&, const Table&) {
    Brick& view = threadView(world);
    world.waitFor(
        [&] {
          QQuickItem* banner = view.find(QStringLiteral("threadError"));
          return world.state(QStringLiteral("threadError")).isNull() && !(banner && banner->isVisible());
        },
        [&] { return seen(world); });
  });
});

}  // namespace

// Whether the open thread's notice says what its background work is, once it
// reads `title` (ConnectionNoticeSteps' "the thread says" is the computer's
// notice otherwise).
bool backgroundNoticeSays(World& world, const QString& title) {
  if (notice(world).value(QStringLiteral("kind")) != QLatin1String("background")) return false;
  noticeSays(world, title);
  return true;
}

// The thread's error's dismiss, when the scenario showed one (DeviceSteps'
// "the user dismisses the error" is the Device tab's otherwise).
bool dismissThreadError(World& world) {
  if (!world.mc.part<ThreadErrorShown>().shown) return false;
  threadView(world).click(QStringLiteral("threadErrorDismiss"));
  return true;
}
