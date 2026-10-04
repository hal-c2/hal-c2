// Settings → General's text generation model (TextGenerationController,
// features/settings/general.feature): what the selected environments'
// providers offer, and a choice one of them cannot honour.

#include <QJsonArray>
#include <QJsonObject>
#include <QQuickItem>

#include "FakeConfig.h"
#include "Harness.h"
#include "SettingsRows.h"
#include "SettingsScopeController.h"
#include "World.h"

namespace {

const QString kOther = QStringLiteral("Build box");
const QString kSetting = QStringLiteral("textGenerationModelSelection");
const QString kRow = QStringLiteral("settingsRow:text-generation-model");

QJsonObject provider(const QStringList& models, bool writesText = true) {
  QJsonArray slugs;
  for (const QString& model : models) slugs.append(QJsonObject{{QStringLiteral("slug"), model.toLower()}, {QStringLiteral("name"), model}});
  return {{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")}, {QStringLiteral("displayName"), QStringLiteral("Claude")},
          {QStringLiteral("enabled"), true}, {QStringLiteral("installed"), true}, {QStringLiteral("supportsTextGeneration"), writesText},
          {QStringLiteral("models"), slugs}};
}

QJsonObject selection(const QString& slug) {
  return {{QStringLiteral("instanceId"), QStringLiteral("claudeAgent")}, {QStringLiteral("model"), slug}};
}

QVariantMap row(World& world) {
  return world.state(QStringLiteral("textGeneration")).toMap();
}

QString describe(World& world) {
  return QStringLiteral("the text generation row is %1").arg(show(row(world)));
}

SettingsScopeController* scope(World& world) {
  return world.native().controller<SettingsScopeController>();
}

const Steps steps([] {
  step(QStringLiteral("the settings scope covers an environment that does not offer the chosen model"), [](World& world, const Captures&, const Table&) {
    // This machine offers Opus and writes with Sonnet; the other offers Sonnet alone.
    saveOn(world.mc, world.mc.environmentId, kSetting, selection(QStringLiteral("sonnet")));
    publishProviders(world.mc, {provider({QStringLiteral("Sonnet"), QStringLiteral("Opus")})});
    FakeConfig& fake = fakeConfig(world.mc);
    fake.elsewhere.insert(kOther, {{QStringLiteral("providers"), QJsonArray{provider({QStringLiteral("Sonnet")})}}});
    documentOf(world.mc, kOther).settings.insert(kSetting, selection(QStringLiteral("sonnet")));
    world.mc.join(kOther);
    world.waitFor([&] { return scope(world)->targets().size() == 2 && scope(world)->settings(kOther).has_value() && row(world).value(QStringLiteral("models")).toList().size() == 2; },
                  [&] { return describe(world); });
  });
  step(QStringLiteral("the user chooses that text generation model"), [](World& world, const Captures&, const Table&) {
    QQuickItem* control = pageItem(world, kRow, QStringLiteral("control"));
    expect(control->isVisible() && control->isEnabled() && control->property("displayText") == QStringLiteral("Claude · Sonnet"),
           QStringLiteral("the row reads \"%1\"; %2").arg(control->property("displayText").toString(), describe(world)));
    // Opus, the second of the list.
    QMetaObject::invokeMethod(control, "activated", Q_ARG(int, 1));
    world.sync();
  });
  step(QStringLiteral("the previous model stays selected"), [](World& world, const Captures&, const Table&) {
    world.sync();
    expect(fakeConfig(world.mc).settings.value(kSetting) == QJsonValue(selection(QStringLiteral("sonnet"))) &&
               documentOf(world.mc, kOther).settings.value(kSetting) == QJsonValue(selection(QStringLiteral("sonnet"))) && fakeConfig(world.mc).writes.isEmpty(),
           QStringLiteral("this machine holds %1").arg(show(fakeConfig(world.mc).settings.toVariantMap())));
    const QQuickItem* control = pageItem(world, kRow, QStringLiteral("control"));
    expect(control->property("displayText") == QStringLiteral("Claude · Sonnet") && control->property("currentIndex").toInt() == 0,
           QStringLiteral("the row reads \"%1\"").arg(control->property("displayText").toString()));
  });

  step(QStringLiteral("no enabled provider in the scope can generate text"), [](World& world, const Captures&, const Table&) {
    // One that can is offered first.
    publishProviders(world.mc, {provider({QStringLiteral("Sonnet")})});
    world.waitFor([&] { return row(world).value(QStringLiteral("unavailable")).toString().isEmpty() && !row(world).value(QStringLiteral("models")).toList().isEmpty(); },
                  [&] { return describe(world); });
    expect(pageItem(world, kRow, QStringLiteral("control"))->isVisible(), QStringLiteral("the row offers no model"));
    // Then only one that cannot write text, and one that is turned off.
    QJsonObject off = provider({QStringLiteral("GPT")});
    off.insert(QStringLiteral("instanceId"), QStringLiteral("codex"));
    off.insert(QStringLiteral("enabled"), false);
    publishProviders(world.mc, {provider({QStringLiteral("Sonnet")}, false), off});
  });
  step(QStringLiteral("the text generation model row explains why it cannot be chosen"), [](World& world, const Captures&, const Table&) {
    world.waitFor([&] { return row(world).value(QStringLiteral("unavailable")) == QLatin1String("No text generation providers available."); },
                  [&] { return describe(world); });
    const QQuickItem* note = pageItem(world, kRow, QStringLiteral("unavailable"));
    expect(note->isVisible() && note->property("text") == QLatin1String("No text generation providers available.") &&
               !pageItem(world, kRow, QStringLiteral("control"))->isVisible(),
           QStringLiteral("the row still offers a model"));
  });
});

}  // namespace
