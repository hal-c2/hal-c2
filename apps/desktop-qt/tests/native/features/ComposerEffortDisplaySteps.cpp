// The effort after the model's name, as a word or as bars, as Settings ›
// Appearance › Effort display says (features/composer/model-and-mode.feature).

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include "ComposerBrick.h"
#include "FakeConfig.h"
#include "Harness.h"
#include "SettingsController.h"
#include "Stream.h"
#include "World.h"

using namespace stream;

namespace {

using S = QString;

QVariantMap composer(World& world) {
  return world.state(S("composer")).toMap();
}

QJsonObject level(const QString& id, const QString& label, bool isDefault = false) {
  return {{S("id"), id}, {S("label"), label}, {S("isDefault"), isDefault}};
}

// Claude's levels, Max named at the top and Ultrathink carried by the prompt.
QJsonObject opus() {
  const QJsonObject effort{{S("id"), S("effort")},
                           {S("label"), S("Effort")},
                           {S("type"), S("select")},
                           {S("options"), QJsonArray{level(S("low"), S("Low")), level(S("medium"), S("Medium"), true), level(S("high"), S("High")),
                                                     level(S("xhigh"), S("Extra High")), level(S("max"), S("Max")),
                                                     level(S("ultrathink"), S("Ultrathink"))}},
                           {S("promptInjectedValues"), QJsonArray{S("ultrathink")}},
                           {S("currentValue"), S("medium")}};
  return {{S("slug"), S("claude-opus-5-5")},
          {S("name"), S("Claude Opus 5.5")},
          {S("capabilities"), QJsonObject{{S("optionDescriptors"), QJsonArray{effort}}}}};
}

QString levelId(const QString& label) {
  for (const QJsonValue& option : opus().value(S("capabilities")).toObject().value(S("optionDescriptors")).toArray().first().toObject().value(S("options")).toArray()) {
    if (option.toObject().value(S("label")).toString() == label) return option.toObject().value(S("id")).toString();
  }
  fail(S("Opus has no %1 effort").arg(label));
}

QQuickItem* part(World& world, const QString& objectName) {
  QQuickItem* item = composerPart(world, objectName);
  expect(item != nullptr, S("the composer shows no %1").arg(objectName));
  return item;
}

int barsNamed(const QString& count) {
  const QStringList words{S("no"), S("one"), S("two"), S("three"), S("four"), S("five")};
  return int(words.indexOf(count));
}

const Steps steps([] {
  const QString q = kQuoted;

  step(S("the thread runs on %1 with (.+) effort").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString effort = levelId(c[1]);
    QJsonArray list = fakeConfig(world.mc).config.value(QLatin1String("providers")).toArray();
    for (qsizetype i = 0; i < list.size(); ++i) {
      QJsonObject entry = list.at(i).toObject();
      if (entry.value(QLatin1String("instanceId")) != QLatin1String("claudeAgent")) continue;
      entry.insert(S("models"), QJsonArray{opus()});
      list.replace(i, entry);
    }
    publishProviders(world.mc, list);
    world.sync();
    QJsonObject& row = world.mc.threads[kThread];
    row.insert(S("modelSelection"), QJsonObject{{S("instanceId"), S("claudeAgent")},
                                                {S("model"), S("claude-opus-5-5")},
                                                {S("options"), QJsonArray{QJsonObject{{S("id"), S("effort")}, {S("value"), effort}}}}});
    world.mc.sendRow(kThread, row);
    world.sync();
    world.waitFor([&] {
      const QVariantList options = composer(world).value(S("options")).toList();
      return composer(world).value(S("selectedModel")) == QLatin1String("claude-opus-5-5") && !options.isEmpty() &&
             options.first().toMap().value(S("value")) == effort;
    }, [&] { return S("the composer on Opus at %1; it shows %2").arg(effort, show(composer(world))); });
  });

  step(S("the effort display is set to %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString display = c[0] == QLatin1String("Bars") ? S("bars") : c[0] == QLatin1String("Word") ? S("label") : QString();
    expect(!display.isEmpty(), S("Effort display offers Word and Bars, not %1").arg(c[0]));
    world.native().controller<SettingsController>()->set(S("effortDisplay"), display);
    world.waitFor([&] { return composer(world).value(S("effortDisplay")) == display; },
                  [&] { return S("the composer to show the effort as %1; it shows %2").arg(display, show(composer(world))); });
  });

  step(S("the model reads %1 followed by (.+)").arg(q), [](World& world, const Captures& c, const Table&) {
    QQuickItem* model = part(world, S("modelPicker"));
    world.waitFor([&] { return model->property("triggerTitle").toString() == c[0]; },
                  [&] { return S("the model to read %1; it reads %2").arg(c[0], model->property("triggerTitle").toString()); });
    // The effort is the model control's, named after the model on its trigger.
    QQuickItem* title = part(world, S("modelPickerTitle"));
    QQuickItem* effort = part(world, S("modelPickerEffort"));
    QQuickItem* bars = part(world, S("modelPickerEffortBars"));
    if (c[1].startsWith(u'"')) {
      const QString word = c[1].mid(1, c[1].size() - 2);
      world.waitFor([&] { return !bars->isVisible() && effort->isVisible() && effort->property("text") == word; },
                    [&] { return S("the effort to read %1; it reads %2 with bars %3").arg(word, effort->property("text").toString(), bars->isVisible() ? S("shown") : S("hidden")); });
      expect(effort->mapToScene(QPointF()).x() > title->mapToScene(QPointF()).x(), S("the effort is not after the model"));
      return;
    }
    const int filled = barsNamed(c[1].section(u' ', 0, 0));
    expect(filled >= 0, S("no number of bars in %1").arg(c[1]));
    world.waitFor([&] { return bars->isVisible() && bars->property("filled").toInt() == filled; },
                  [&] { return S("%1 bars filled; %2 of %3 are, shown: %4").arg(filled).arg(bars->property("filled").toInt()).arg(bars->property("count").toInt()).arg(bars->isVisible()); });
    expect(bars->mapToScene(QPointF()).x() > title->mapToScene(QPointF()).x(), S("the bars are not after the model"));
    // One bar a level, Max named apart: low, medium, high and extra high.
    expect(bars->property("count").toInt() == 4, S("the bars count %1 levels").arg(bars->property("count").toInt()));
  });
});

}  // namespace
