// Settings → General, Text generation:
// the model that writes thread titles and other generated text on the selected
// environments (`textGenerationModelSelection`, a project's override at
// project scope). A choice is written to every selected environment, so each
// must offer the model.
//
// Publishes `textGeneration`: {open, value ("<instance>:<model>", "" when
// mixed), label, mixed, resettable, models: [{key, label}] (the first selected
// environment's text generation providers'), unavailable (why no model can be
// chosen, "" when one can)}.
//
// Actions: `textGeneration.choose {key}`, `textGeneration.reset`.

#include <QJsonArray>
#include <QJsonObject>
#include <QObject>

#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsScopeController.h"
#include "ShellBridge.h"
#include "ToastController.h"

namespace {

const QString kKey = QStringLiteral("textGeneration");
const QString kSetting = QStringLiteral("textGenerationModelSelection");

QString text(const QJsonObject& object, const char* key) {
  return object.value(QLatin1String(key)).toString();
}

// The providers that can write text and can be used now.
QJsonArray usable(const QJsonArray& providers) {
  QJsonArray result;
  for (const QJsonValue& value : providers) {
    const QJsonObject provider = value.toObject();
    if (provider.value(QLatin1String("supportsTextGeneration")) == QJsonValue(false)) continue;
    if (!provider.value(QLatin1String("enabled")).toBool(true) || !provider.value(QLatin1String("installed")).toBool(true)) continue;
    if (text(provider, "availability") == QLatin1String("unavailable")) continue;
    result.append(provider);
  }
  return result;
}

bool offers(const QJsonArray& providers, const QString& instanceId, const QString& model) {
  for (const QJsonValue& value : usable(providers)) {
    if (text(value.toObject(), "instanceId") != instanceId) continue;
    for (const QJsonValue& slug : value.toObject().value(QLatin1String("models")).toArray()) {
      if (text(slug.toObject(), "slug") == model) return true;
    }
  }
  return false;
}

QString keyOf(const QJsonObject& selection) {
  return selection.isEmpty() ? QString() : text(selection, "instanceId") + QLatin1Char(':') + text(selection, "model");
}

class TextGenerationController : public QObject, public NativeController {
public:
  TextGenerationController(ShellBridge* bridge, McClient*, QObject* parent) : QObject(parent), m_bridge(bridge) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    auto* navigation = NativeShell::of(this)->controller<NavigationController>();
    const auto follow = [this, navigation] {
      const NavigationController::Route& route = navigation->route();
      m_open = route.kind == QLatin1String("settings") &&
               (route.section.isEmpty() || route.section == QLatin1String("/settings") || route.section == QLatin1String("/settings/general"));
      publish();
    };
    connect(navigation, &NavigationController::changed, this, follow);
    connect(scope(), &SettingsScopeController::changed, this, &TextGenerationController::publish);
    follow();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active || !action.startsWith(QLatin1String("textGeneration."))) return false;
    if (action == QLatin1String("textGeneration.choose")) {
      choose(payload.toMap().value(QStringLiteral("key")).toString());
    } else if (action == QLatin1String("textGeneration.reset")) {
      write(QJsonValue(QJsonValue::Undefined));
    }
    return true;
  }

private:
  SettingsScopeController* scope() const { return NativeShell::of(this)->controller<SettingsScopeController>(); }

  // The project's own choice, else the environment's; undefined when neither is set.
  static QJsonValue stored(const QJsonObject& settings, const QString& projectId) {
    if (!projectId.isEmpty()) {
      const QJsonValue own = SettingsScopeController::overrideOf(settings, projectId, kSetting);
      if (!own.isUndefined()) return own;
    }
    return settings.contains(kSetting) ? settings.value(kSetting) : QJsonValue(QJsonValue::Undefined);
  }

  void choose(const QString& key) {
    const qsizetype colon = key.indexOf(QLatin1Char(':'));
    if (colon <= 0) return;
    const QString instanceId = key.left(colon);
    const QString model = key.mid(colon + 1);
    // It goes to every selected environment, so each must offer it.
    for (const QString& environmentId : scope()->targets()) {
      if (offers(scope()->providers(environmentId), instanceId, model)) continue;
      NativeShell::of(this)->controller<ToastController>()->error(
          QStringLiteral("Text generation model not saved"),
          QStringLiteral("This model is unavailable on %1. Select that environment to choose its model separately.").arg(scope()->label(environmentId)));
      // The row goes back to what is saved.
      publish();
      return;
    }
    write(QJsonObject{{QStringLiteral("instanceId"), instanceId}, {QStringLiteral("model"), model}});
  }

  void write(const QJsonValue& value) {
    scope()->write(
        [value](QJsonObject settings, const QString& projectId) {
          if (!projectId.isEmpty()) return SettingsScopeController::withOverride(settings, projectId, kSetting, value);
          if (value.isUndefined()) settings.remove(kSetting);
          else settings.insert(kSetting, value);
          return settings;
        },
        QStringLiteral("Text generation model not saved"));
  }

  void publish() {
    if (!m_active) return;
    if (!m_open) {
      m_bridge->publish(kKey, QVariantMap{{QStringLiteral("open"), false}});
      return;
    }
    const QStringList targets = scope()->targets();
    const auto reading = scope()->read([](const QJsonObject& settings, const QString& projectId) {
      const QJsonValue value = stored(settings, projectId);
      return value.isObject() ? value : QJsonValue(QJsonValue::Null);
    });
    const auto customised = scope()->read([](const QJsonObject& settings, const QString& projectId) {
      if (!projectId.isEmpty()) return QJsonValue(!SettingsScopeController::overrideOf(settings, projectId, kSetting).isUndefined());
      return QJsonValue(settings.contains(kSetting));
    });
    const QString key = reading.mixed ? QString() : keyOf(reading.value.toObject());
    QVariantList models;
    QString label;
    const QJsonArray providers = targets.isEmpty() ? QJsonArray() : usable(scope()->providers(targets.first()));
    for (const QJsonValue& value : providers) {
      const QJsonObject provider = value.toObject();
      const QString name = text(provider, "displayName").isEmpty() ? text(provider, "instanceId") : text(provider, "displayName");
      for (const QJsonValue& slug : provider.value(QLatin1String("models")).toArray()) {
        const QJsonObject model = slug.toObject();
        if (model.value(QLatin1String("isLegacy")).toBool()) continue;
        const QString modelKey = text(provider, "instanceId") + QLatin1Char(':') + text(model, "slug");
        const QString shown = name + QStringLiteral(" · ") + (text(model, "name").isEmpty() ? text(model, "slug") : text(model, "name"));
        if (modelKey == key) label = shown;
        models.append(QVariantMap{{QStringLiteral("key"), modelKey}, {QStringLiteral("label"), shown}});
      }
    }
    QString unavailable;
    if (targets.isEmpty()) {
      unavailable = QStringLiteral("Connect an environment to choose its text generation model.");
    } else if (models.isEmpty()) {
      unavailable = QStringLiteral("No text generation providers available.");
    }
    if (reading.mixed) {
      label = QStringLiteral("Mixed");
    } else if (label.isEmpty()) {
      // Unset, an environment uses its default; a saved model no provider offers still names itself.
      label = key.isEmpty() ? QStringLiteral("Default") : key + QStringLiteral(" (Unavailable)");
    }
    m_bridge->publish(kKey, QVariantMap{{QStringLiteral("open"), true},
                                        {QStringLiteral("value"), key},
                                        {QStringLiteral("label"), label},
                                        {QStringLiteral("mixed"), reading.mixed},
                                        {QStringLiteral("resettable"), customised.mixed || customised.value.toBool()},
                                        {QStringLiteral("models"), models},
                                        {QStringLiteral("unavailable"), unavailable}});
  }

  ShellBridge* m_bridge;
  bool m_active = false;
  bool m_open = false;
};

const NativeControllerRegistrar<TextGenerationController> registrar(QStringLiteral("textGeneration"), {kKey});

}  // namespace
