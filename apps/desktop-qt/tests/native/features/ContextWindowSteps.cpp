// How full the open thread's context window is
// (features/timeline/runs-and-queue.feature): the provider thread on the
// thread's stream carries the provider's latest report (contextUsage), which
// the composer's ContextWindowMeter reads behind its setting.

#include <QColor>
#include <QDir>
#include <QImage>
#include <QJsonObject>
#include <QQuickItem>
#include <QRegularExpression>

#include "Brick.h"
#include "Harness.h"
#include "SettingsController.h"
#include "Stream.h"
#include "World.h"

using namespace stream;

namespace {

const QString kProviderThread = QStringLiteral("provider-thread-1");

// Whether the scenario said where the meter's setting stands; otherwise the
// meter is on, as the scenarios that read it take for granted.
struct MeterSetting {
  bool said = false;
};

Brick& composer(World& world) {
  if (!world.brick) {
    // The composer at the foot of a taller window, with room above it for
    // the meter's details.
    world.brick = std::make_unique<Brick>(world,
                                          "import QtQuick\nimport HalC2.Bricks\nItem {\n"
                                          "  Composer { anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom }\n}\n",
                                          QSize(720, 360));
  }
  return *world.brick;
}

void shoot(World& world, const QString& name) {
  const QString dir = qEnvironmentVariable("HAL_C2_SHOTS");
  if (dir.isEmpty()) return;
  QDir().mkpath(dir);
  composer(world).grab().save(QDir(dir).filePath(name + QStringLiteral(".png")));
}

void setMeter(World& world, bool on) {
  world.mc.part<MeterSetting>().said = true;
  world.native().controller<SettingsController>()->set(QStringLiteral("contextWindowMeterEnabled"), on);
}

double count(const QString& digits) {
  return QString(digits).remove(QLatin1Char(',')).toDouble();
}

QJsonObject usage(World& world) {
  return world.mc.part<FakeStreams>().threads.value(kThread).value(QStringLiteral("provider-thread\n") + kProviderThread).value(QLatin1String("contextUsage")).toObject();
}

// The provider's report on the thread, as its adapter writes it.
void report(World& world, const QJsonObject& contextUsage) {
  set(world, QStringLiteral("provider-thread"), kProviderThread,
      {{QStringLiteral("id"), kProviderThread}, {QStringLiteral("appThreadId"), kThread}, {QStringLiteral("contextUsage"), contextUsage},
       {QStringLiteral("updatedAt"), iso(now())}});
}

QVariantMap reading(World& world) {
  return timeline(world).contextWindow();
}

QQuickItem* meter(World& world) {
  return composer(world).find(QStringLiteral("contextWindowMeter"));
}

bool meterShown(World& world) {
  QQuickItem* shown = meter(world);
  return shown && shown->isVisible();
}

QString seen(World& world) {
  return QStringLiteral("the meter is %1; the thread's context window is %2").arg(meterShown(world) ? QStringLiteral("shown") : QStringLiteral("hidden"), show(reading(world)));
}

QString text(QQuickItem* item) {
  return item ? item->property("text").toString() : QString();
}

void openDetails(World& world) {
  Brick& view = composer(world);
  world.waitFor([&] { return meterShown(world); }, [&] { return seen(world); });
  view.click(QStringLiteral("contextWindowMeter"));
  world.waitFor(
      [&] {
        // Shown, and done fading in.
        QQuickItem* details = view.find(QStringLiteral("contextWindowDetails"));
        if (!details || !details->isVisible()) return false;
        for (QQuickItem* item = details; item; item = item->parentItem()) {
          if (item->opacity() < 1) return false;
        }
        return true;
      },
      [&] { return QStringLiteral("the context window's details to open; %1").arg(seen(world)); });
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the agent has used ([\\d,]+) tokens of (?:a ([\\d,]+) token window|an unknown window)"), [](World& world, const Captures& c, const Table&) {
    composer(world);
    if (!world.mc.part<MeterSetting>().said) world.native().controller<SettingsController>()->set(QStringLiteral("contextWindowMeterEnabled"), true);
    QJsonObject contextUsage{{QStringLiteral("usedTokens"), count(c[0])}};
    if (!c[1].isEmpty()) contextUsage.insert(QStringLiteral("maxTokens"), count(c[1]));
    report(world, contextUsage);
    world.waitFor([&] { return reading(world).value(QStringLiteral("usedTokens")).toDouble() == count(c[0]); }, [&] { return seen(world); });
  });
  step(QStringLiteral("the context window reads %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return meterShown(world) && reading(world).value(QStringLiteral("reading")) == c[0]; },
                  [&] { return QStringLiteral("the context window to read \"%1\"; %2").arg(c[0], seen(world)); });
    openDetails(world);
    expect(text(composer(world).find(QStringLiteral("contextWindowReading"))) == c[0], seen(world));
    QString name = c[0];
    shoot(world, QStringLiteral("context-window-") + name.replace(QRegularExpression(QStringLiteral("[^0-9a-z]+")), QStringLiteral("-")));
  });
  step(QStringLiteral("the context window meter setting is off"), [](World& world, const Captures&, const Table&) {
    composer(world);
    setMeter(world, false);
  });
  step(QStringLiteral("the user turns the context window meter setting on"), [](World& world, const Captures&, const Table&) { setMeter(world, true); });
  step(QStringLiteral("the thread shows no context window reading"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(!reading(world).isEmpty() && !meterShown(world), seen(world));
    shoot(world, QStringLiteral("context-window-setting-off"));
  });
  step(QStringLiteral("the context window is %1 full").arg(q), [](World& world, const Captures& c, const Table&) {
    world.waitFor([&] { return meterShown(world) && reading(world).value(QStringLiteral("percentLabel")) == c[0]; },
                  [&] { return QStringLiteral("the context window to be %1 full; %2").arg(c[0], seen(world)); });
  });
  step(QStringLiteral("the context window reading is marked as nearly full"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return meterShown(world) && reading(world).value(QStringLiteral("nearlyFull")).toBool(); }, [&] { return seen(world); });
    openDetails(world);
    QQuickItem* label = composer(world).find(QStringLiteral("contextWindowReading"));
    const QColor marked = meter(world)->property("usedColor").value<QColor>();
    // The reading takes the ring's colour only when it is marked; it is the text's otherwise.
    expect(label && label->property("color").value<QColor>() == marked, seen(world));
    shoot(world, QStringLiteral("context-window-nearly-full"));
  });

  step(QStringLiteral("the thread has processed ([\\d,]+) tokens in all at a cost of ([\\d.]+) US dollars"), [](World& world, const Captures& c, const Table&) {
    QJsonObject contextUsage = usage(world);
    contextUsage.insert(QStringLiteral("totalProcessedTokens"), count(c[0]));
    contextUsage.insert(QStringLiteral("cost"), QJsonObject{{QStringLiteral("amount"), c[1].toDouble()}, {QStringLiteral("currency"), QStringLiteral("USD")}});
    report(world, contextUsage);
    world.waitFor([&] { return !reading(world).value(QStringLiteral("cost")).toString().isEmpty(); }, [&] { return seen(world); });
  });
  step(QStringLiteral("the user opens the context window's details"), [](World& world, const Captures&, const Table&) { openDetails(world); });
  step(QStringLiteral("the details show %1 as ([^ ]+) and %1 as %1").arg(q), [](World& world, const Captures& c, const Table&) {
    Brick& view = composer(world);
    world.waitFor(
        [&] {
          return text(view.find(QStringLiteral("contextWindowFact:") + c[0])) == c[1] && text(view.find(QStringLiteral("contextWindowFact:") + c[2])) == c[3];
        },
        [&] {
          return QStringLiteral("the details to show %1 as %2 and %3 as %4; they show %5 and %6")
              .arg(c[0], c[1], c[2], c[3], text(view.find(QStringLiteral("contextWindowFact:") + c[0])), text(view.find(QStringLiteral("contextWindowFact:") + c[2])));
        });
    shoot(world, QStringLiteral("context-window-details"));
  });
  step(QStringLiteral("a thread whose provider reports no cost shows no cost"), [](World& world, const Captures&, const Table&) {
    QJsonObject contextUsage = usage(world);
    contextUsage.remove(QStringLiteral("cost"));
    report(world, contextUsage);
    Brick& view = composer(world);
    world.waitFor(
        [&] {
          QQuickItem* cost = view.find(QStringLiteral("contextWindowFact:Cost"));
          return reading(world).value(QStringLiteral("cost")).toString().isEmpty() && !(cost && cost->isVisible() && cost->parentItem()->isVisible());
        },
        [&] { return seen(world); });
  });
});

}  // namespace
