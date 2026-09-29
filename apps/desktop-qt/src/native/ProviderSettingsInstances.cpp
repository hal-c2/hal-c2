// The Providers section's instances (ProviderSettingsController): adding one
// with the wizard, and editing, resetting and deleting one where the node
// reads it, its `providerInstances` entry (ProviderInstances.h). As the web's
// AddProviderInstanceDialog, ProviderInstanceCard and ProviderSettingsPanel.
//
// Actions (each on the shown environment):
//   `providerSettings.wizardOpen`, `.wizardClose`, `.wizardDriver {driver}`,
//   `.wizardLabel {label}`, `.wizardAccent {color}`, `.wizardInstanceId
//   {instanceId}`, `.wizardField {key, value}`, `.wizardStep {step}` (moving
//   on past Identity needs a valid id; going back always works),
//   `.wizardSubmit`;
//   `.rename {instanceId, name}`, `.accent {instanceId, color}`, `.field
//   {instanceId, key, value}`, `.secret {instanceId, name, value}` (a driver's
//   own variable, such as Cursor's API key; empty removes it), `.addVariable
//   {instanceId}`, `.variable {instanceId, index, name | value | sensitive}`,
//   `.removeVariable {instanceId, index}`, `.delete {instanceId}` (an added
//   instance), `.reset {instanceId}` (a built-in's own slot);
//   `.addModel {instanceId, slug}`, `.editModel {instanceId, slug}` (opens
//   its draft; empty closes it), `.modelDraft {instanceId, name | options |
//   copyFrom (a built-in model's slug)}`, `.saveModel {instanceId, slug}` (the
//   draft) and `.removeModel {instanceId, slug}`: custom models
//   (ProviderCustomModels.h).
//
// Each listed provider also carries: editable (its settings arrived), custom
// (added, so deletable), resettable, label (its own name, "" for none),
// placeholder, accentColor, fields [{key, label, description, placeholder,
// control: text | password | select, options [{value, label}], value}],
// secrets [{name, label, description, placeholder, stored}], variables
// [{name, value, sensitive, redacted, invalid, placeholder}], pending (added
// but not yet reported by the environment), takesModels, customModels [{slug,
// name, options}], modelPresets and copyFrom [{slug, name, options}] (options
// to start from), modelDraft (null | {slug, name, options}, the model being
// edited) and modelError.
//
// `wizard`: {step, steps, drivers [{id, label, badge}], driver, driverLabel,
// label, accentColor, instanceId, instanceIdError ("" until moving on was
// tried), fields, saving, registry (ProviderSettingsRegistry.cpp)}.

#include <QJsonArray>
#include <QJsonObject>

#include "EnvironmentSettings.h"
#include "NativeShell.h"
#include "NodeClient.h"
#include "ProviderCustomModels.h"
#include "ProviderDrivers.h"
#include "ProviderInstances.h"
#include "ProviderSettingsController.h"
#include "ToastController.h"

namespace {

const QString kRegistry = QStringLiteral("acpRegistry");
const QStringList kSteps{QStringLiteral("Provider"), QStringLiteral("Identity"), QStringLiteral("Config")};
// An agent chosen from the registry is set up by it; it signs in from its card.
const QStringList kRegistrySteps{QStringLiteral("Provider"), QStringLiteral("Identity")};

QString configText(const QJsonValue& value) {
  if (value.isString()) return value.toString();
  if (value.isDouble() || value.isBool()) return value.toVariant().toString();
  return {};
}

// A driver's settings with `config`'s values.
QVariantList fields(const ProviderDrivers::Driver& driver, const QJsonObject& config) {
  QVariantList result;
  for (const ProviderDrivers::Field& field : driver.fields) {
    QVariantList options;
    for (const auto& [value, label] : field.options) {
      options.append(QVariantMap{{QStringLiteral("value"), value}, {QStringLiteral("label"), label}});
    }
    QString value = configText(config.value(field.key));
    if (value.isEmpty() && !field.options.isEmpty()) value = field.options.first().first;
    result.append(QVariantMap{{QStringLiteral("key"), field.key},
                              {QStringLiteral("label"), field.label},
                              {QStringLiteral("description"), field.description},
                              {QStringLiteral("placeholder"), field.placeholder},
                              {QStringLiteral("control"), field.control},
                              {QStringLiteral("options"), options},
                              {QStringLiteral("value"), value}});
  }
  return result;
}

const ProviderDrivers::Field* field(const QString& driver, const QString& key) {
  const ProviderDrivers::Driver* found = ProviderDrivers::find(driver);
  if (!found) return nullptr;
  for (const ProviderDrivers::Field& candidate : found->fields) {
    if (candidate.key == key) return &candidate;
  }
  return nullptr;
}

// The variables a driver asks for by name, which the generic rows leave out.
QSet<QString> dedicated(const QString& driver) {
  QSet<QString> names;
  if (const ProviderDrivers::Driver* found = ProviderDrivers::find(driver)) {
    for (const ProviderDrivers::Variable& variable : found->variables) names.insert(variable.name);
  }
  return names;
}

// A row just added and left alone, which is not saved.
bool blank(const QJsonObject& row) {
  return row.value(QLatin1String("name")).toString().trimmed().isEmpty() && row.value(QLatin1String("value")).toString().isEmpty() &&
         row.value(QLatin1String("sensitive")).toBool() && !row.contains(QLatin1String("valueRedacted"));
}

bool invalid(const QJsonObject& row) {
  return !blank(row) && !ProviderInstances::validVariableName(row.value(QLatin1String("name")).toString().trimmed());
}

QJsonObject withEnvironment(QJsonObject instance, const QJsonArray& environment) {
  if (environment.isEmpty()) instance.remove(QStringLiteral("environment"));
  else instance.insert(QStringLiteral("environment"), environment);
  return instance;
}

QJsonObject withText(QJsonObject instance, const QString& key, const QString& value) {
  if (value.isEmpty()) instance.remove(key);
  else instance.insert(key, value);
  return instance;
}

void toast(QObject* context, const QString& type, const QString& title, const QString& description) {
  if (auto* toasts = NativeShell::of(context)->controller<ToastController>()) toasts->show(type, title, description);
}

}  // namespace

std::optional<QJsonObject> ProviderSettingsController::shownSettings() const {
  if (m_followed.isEmpty()) return std::nullopt;
  return m_scope->settings(m_followed);
}

// An instance's driver: as the environment lists it, else as it is
// configured, else a built-in's own slot.
QString ProviderSettingsController::driverOf(const QString& instanceId) const {
  if (instanceId.isEmpty()) return {};
  const QString listed = provider(instanceId).value(QLatin1String("driver")).toString();
  if (!listed.isEmpty()) return listed;
  if (const std::optional<QJsonObject> settings = shownSettings()) {
    const QString configured = settings->value(QLatin1String("providerInstances")).toObject().value(instanceId).toObject()
                                   .value(QLatin1String("driver")).toString();
    if (!configured.isEmpty()) return configured;
  }
  const ProviderDrivers::Driver* builtIn = ProviderDrivers::find(instanceId);
  return builtIn && builtIn->builtIn ? instanceId : QString();
}

void ProviderSettingsController::editInstance(const QString& instanceId, const std::function<QJsonObject(QJsonObject)>& change,
                                              const std::function<void(bool)>& done) {
  const QString driver = driverOf(instanceId);
  if (driver.isEmpty()) return;
  save([instanceId, driver, change](QJsonObject settings, const QString&) {
    return ProviderInstances::with(settings, instanceId, change(ProviderInstances::of(settings, instanceId, driver)));
  }, done, QStringLiteral("Could not update provider instance"));
}

// The rows as edited; they are saved once each is complete, the web's
// ProviderEnvironmentSection publishRows.
void ProviderSettingsController::setVariables(const QString& instanceId, const QJsonArray& rows) {
  m_variables.insert(instanceId, rows);
  publish();
  QJsonArray environment;
  for (const QJsonValue& value : rows) {
    const QJsonObject row = value.toObject();
    if (invalid(row)) return;
    if (blank(row)) continue;
    QJsonObject variable{{QStringLiteral("name"), row.value(QLatin1String("name")).toString().trimmed()},
                         {QStringLiteral("value"), row.value(QLatin1String("value")).toString()},
                         {QStringLiteral("sensitive"), row.value(QLatin1String("sensitive")).toBool()}};
    if (row.value(QLatin1String("valueRedacted")).toBool()) variable.insert(QStringLiteral("valueRedacted"), true);
    environment.append(variable);
  }
  const QSet<QString> own = dedicated(driverOf(instanceId));
  editInstance(instanceId, [environment, own](QJsonObject instance) {
    QJsonArray next;
    for (const QJsonValue& variable : instance.value(QLatin1String("environment")).toArray()) {
      if (own.contains(variable.toObject().value(QLatin1String("name")).toString())) next.append(variable);
    }
    for (const QJsonValue& variable : environment) next.append(variable);
    return withEnvironment(instance, next);
  }, [this, instanceId, rows](bool saved) {
    // Saved rows show as the environment keeps them (a secret redacted);
    // a blank one stays until it is filled in or removed.
    const bool settled = std::none_of(rows.begin(), rows.end(), [](const QJsonValue& row) { return blank(row.toObject()); });
    if (saved && settled && m_variables.value(instanceId) == rows) m_variables.remove(instanceId);
    publish();
  });
}

bool ProviderSettingsController::handleInstance(const QString& action, const QVariantMap& input) {
  const QString instanceId = input.value(QStringLiteral("instanceId")).toString();
  const auto taken = [this] {
    return ProviderInstances::taken(shownSettings().value_or(QJsonObject{}), m_providers.value_or(QJsonArray{}));
  };
  if (action.startsWith(QLatin1String("providerSettings.wizard"))) {
    if (action == QLatin1String("providerSettings.wizardOpen")) {
      if (m_followed.isEmpty()) return true;
      m_wizard = Wizard{};
      // An empty query lists the registry's compatible agents.
      searchRegistry(QString());
    } else if (!m_wizard || m_wizard->saving) {
      return true;
    } else if (action == QLatin1String("providerSettings.wizardClose")) {
      m_wizard.reset();
    } else if (action == QLatin1String("providerSettings.wizardDriver")) {
      const QString driver = input.value(QStringLiteral("driver")).toString();
      if (ProviderDrivers::find(driver) && driver != kRegistry) {
        m_wizard->driver = driver;
        m_wizard->manual = false;
        m_wizard->attempted = false;
      }
    } else if (action == QLatin1String("providerSettings.wizardLabel")) {
      m_wizard->identity[m_wizard->driver].insert(QStringLiteral("label"), input.value(QStringLiteral("label")).toString());
    } else if (action == QLatin1String("providerSettings.wizardAccent")) {
      m_wizard->identity[m_wizard->driver].insert(QStringLiteral("accentColor"), input.value(QStringLiteral("color")).toString());
    } else if (action == QLatin1String("providerSettings.wizardInstanceId")) {
      m_wizard->identity[m_wizard->driver].insert(QStringLiteral("instanceId"), input.value(QStringLiteral("instanceId")).toString().trimmed());
    } else if (action == QLatin1String("providerSettings.wizardField")) {
      const QString key = input.value(QStringLiteral("key")).toString();
      const ProviderDrivers::Field* found = field(m_wizard->driver, key);
      if (!found) return true;
      QJsonObject config = ProviderInstances::withConfig(
          QJsonObject{{QStringLiteral("config"), m_wizard->config.value(m_wizard->driver)}}, key, input.value(QStringLiteral("value")).toString())
          .value(QLatin1String("config")).toObject();
      m_wizard->config.insert(m_wizard->driver, config);
    } else if (action == QLatin1String("providerSettings.wizardStep") || action == QLatin1String("providerSettings.wizardSubmit")) {
      const QString driver = m_wizard->driver;
      const QJsonObject identity = m_wizard->identity.value(driver);
      const QString driverLabel = ProviderDrivers::find(driver)->label;
      const QString label = identity.contains(QLatin1String("label")) ? identity.value(QLatin1String("label")).toString() : driverLabel;
      const QSet<QString> ids = taken();
      const QString id = identity.contains(QLatin1String("instanceId")) ? identity.value(QLatin1String("instanceId")).toString()
                                                                        : ProviderDrivers::deriveId(driver, label, ids);
      const bool valid = ProviderDrivers::validateId(id, ids).isEmpty();
      // resolveAcpRegistryWizardNavigation: moving on from Provider needs an agent.
      const bool chosen = registrySelectionError().isEmpty();
      if (!chosen && (action == QLatin1String("providerSettings.wizardSubmit") || input.value(QStringLiteral("step")).toInt() > 0)) {
        m_wizard->attempted = true;
        m_wizard->step = 0;
        publish();
        return true;
      }
      if (action == QLatin1String("providerSettings.wizardStep")) {
        // resolveWizardNavigation: moving on past Identity needs a valid id.
        const QStringList& steps = driver == kRegistry && !m_wizard->manual ? kRegistrySteps : kSteps;
        const int target = std::clamp(input.value(QStringLiteral("step")).toInt(), 0, int(steps.size()) - 1);
        if (m_wizard->step <= 1 && target > 1 && !valid) {
          m_wizard->attempted = true;
          m_wizard->step = 1;
        } else {
          m_wizard->step = target;
        }
      } else {
        m_wizard->attempted = true;
        if (!valid) {
          m_wizard->step = 1;
          publish();
          return true;
        }
        QJsonObject instance{{QStringLiteral("driver"), driver}, {QStringLiteral("enabled"), true}};
        if (!label.trimmed().isEmpty()) instance.insert(QStringLiteral("displayName"), label.trimmed());
        const QString accent = ProviderInstances::accent(identity.value(QLatin1String("accentColor")).toString());
        if (!accent.isEmpty()) instance.insert(QStringLiteral("accentColor"), accent);
        if (!m_wizard->config.value(driver).isEmpty()) instance.insert(QStringLiteral("config"), m_wizard->config.value(driver));
        m_wizard->saving = true;
        save([id, instance](QJsonObject settings, const QString&) { return ProviderInstances::with(settings, id, instance); },
             [this, id, driverLabel](bool saved) {
               if (!m_wizard) return;
               if (saved) {
                 m_wizard.reset();
                 toast(this, QStringLiteral("success"), QStringLiteral("Provider instance added"),
                       QStringLiteral("%1 instance '%2' was added.").arg(driverLabel, id));
               } else {
                 m_wizard->saving = false;
               }
               publish();
             },
             QStringLiteral("Could not add provider instance"));
      }
    } else {
      return false;
    }
    publish();
    return true;
  }

  const QString driver = driverOf(instanceId);
  if (action == QLatin1String("providerSettings.rename")) {
    const QString name = input.value(QStringLiteral("name")).toString().trimmed();
    editInstance(instanceId, [name](QJsonObject instance) { return withText(instance, QStringLiteral("displayName"), name); });
  } else if (action == QLatin1String("providerSettings.accent")) {
    const QString color = ProviderInstances::accent(input.value(QStringLiteral("color")).toString());
    editInstance(instanceId, [color](QJsonObject instance) { return withText(instance, QStringLiteral("accentColor"), color); });
  } else if (action == QLatin1String("providerSettings.field")) {
    const ProviderDrivers::Field* found = field(driver, input.value(QStringLiteral("key")).toString());
    if (!found) return true;
    const QString key = found->key;
    const QString value = input.value(QStringLiteral("value")).toString();
    const bool keepEmpty = found->keepEmpty;
    editInstance(instanceId, [key, value, keepEmpty](QJsonObject instance) {
      instance = ProviderInstances::withConfig(instance, key, value);
      if (keepEmpty && value.trimmed().isEmpty()) {
        QJsonObject config = instance.value(QLatin1String("config")).toObject();
        config.insert(key, QString());
        instance.insert(QStringLiteral("config"), config);
      }
      return instance;
    });
  } else if (action == QLatin1String("providerSettings.secret")) {
    // nextProviderEnvironmentWithFieldValue: the trimmed value, or none.
    const QString name = input.value(QStringLiteral("name")).toString();
    const ProviderDrivers::Driver* found = ProviderDrivers::find(driver);
    const ProviderDrivers::Variable* variable = nullptr;
    if (found) {
      for (const ProviderDrivers::Variable& candidate : found->variables) {
        if (candidate.name == name) variable = &candidate;
      }
    }
    if (!variable) return true;
    const QString value = input.value(QStringLiteral("value")).toString().trimmed();
    const bool sensitive = variable->sensitive;
    editInstance(instanceId, [name, value, sensitive](QJsonObject instance) {
      QJsonArray next;
      for (const QJsonValue& existing : instance.value(QLatin1String("environment")).toArray()) {
        if (existing.toObject().value(QLatin1String("name")) != name) next.append(existing);
      }
      if (!value.isEmpty()) {
        next.append(QJsonObject{{QStringLiteral("name"), name}, {QStringLiteral("value"), value}, {QStringLiteral("sensitive"), sensitive}});
      }
      return withEnvironment(instance, next);
    });
  } else if (action == QLatin1String("providerSettings.addVariable") || action == QLatin1String("providerSettings.variable") ||
             action == QLatin1String("providerSettings.removeVariable")) {
    if (driver.isEmpty()) return true;
    QJsonArray rows = m_variables.value(instanceId);
    if (!m_variables.contains(instanceId)) {
      const QSet<QString> own = dedicated(driver);
      const QJsonObject instance = ProviderInstances::of(shownSettings().value_or(QJsonObject{}), instanceId, driver);
      for (const QJsonValue& variable : instance.value(QLatin1String("environment")).toArray()) {
        if (!own.contains(variable.toObject().value(QLatin1String("name")).toString())) rows.append(variable);
      }
    }
    const int index = input.value(QStringLiteral("index"), -1).toInt();
    if (action == QLatin1String("providerSettings.addVariable")) {
      rows.append(QJsonObject{{QStringLiteral("name"), QString()}, {QStringLiteral("value"), QString()}, {QStringLiteral("sensitive"), true}});
      m_variables.insert(instanceId, rows);
      publish();
      return true;
    }
    if (index < 0 || index >= rows.size()) return true;
    if (action == QLatin1String("providerSettings.removeVariable")) {
      rows.removeAt(index);
    } else {
      QJsonObject row = rows.at(index).toObject();
      if (input.contains(QStringLiteral("name"))) row.insert(QStringLiteral("name"), input.value(QStringLiteral("name")).toString().trimmed());
      if (input.contains(QStringLiteral("value"))) {
        row.insert(QStringLiteral("value"), input.value(QStringLiteral("value")).toString());
        row.insert(QStringLiteral("valueRedacted"), false);
      }
      if (input.contains(QStringLiteral("sensitive"))) {
        const bool sensitive = input.value(QStringLiteral("sensitive")).toBool();
        row.insert(QStringLiteral("sensitive"), sensitive);
        // A secret made plain text needs its value again.
        if (!sensitive && row.contains(QLatin1String("valueRedacted"))) row.insert(QStringLiteral("valueRedacted"), false);
      }
      rows.replace(index, row);
    }
    setVariables(instanceId, rows);
  } else if (action == QLatin1String("providerSettings.delete")) {
    const ProviderDrivers::Driver* found = ProviderDrivers::find(driver);
    if (driver.isEmpty() || (found && found->builtIn && instanceId == driver)) return true;
    const std::optional<QJsonObject> settings = shownSettings();
    const QString agentId = settings ? ProviderInstances::of(*settings, instanceId, driver).value(QLatin1String("config")).toObject()
                                           .value(QLatin1String("agentId")).toString().trimmed()
                                     : QString();
    const QString environmentId = m_followed;
    m_variables.remove(instanceId);
    save([instanceId](QJsonObject settings, const QString&) { return ProviderInstances::with(settings, instanceId, {}); },
         [this, driver, agentId, environmentId](bool saved) {
           if (!saved || driver != kRegistry || agentId.isEmpty()) return;
           // The environment decides from its own settings whether another
           // instance still runs the agent.
           m_client->call(environmentId, QStringLiteral("server.uninstallAcpRegistryManagedBinary"),
                          QJsonObject{{QStringLiteral("agentId"), agentId}},
                          [this](const QJsonValue&, const std::optional<QString>& error) {
                            if (!error) return;
                            toast(this, QStringLiteral("warning"), QStringLiteral("Provider deleted, but managed files remain"),
                                  error->isEmpty() ? QStringLiteral("Managed binary cleanup failed.") : *error);
                          });
         },
         QStringLiteral("Could not delete provider instance"));
  } else if (action == QLatin1String("providerSettings.addModel") || action == QLatin1String("providerSettings.saveModel") ||
             action == QLatin1String("providerSettings.removeModel")) {
    if (driver.isEmpty()) return true;
    const QString slug = input.value(QStringLiteral("slug")).toString().trimmed();
    const QJsonValue saved = ProviderInstances::of(shownSettings().value_or(QJsonObject{}), instanceId, driver)
                                 .value(QLatin1String("config")).toObject().value(QLatin1String("customModels"));
    QString refused;
    QJsonValue stored;
    if (action == QLatin1String("providerSettings.addModel")) {
      refused = ProviderCustomModels::refusal(slug, provider(instanceId).value(QLatin1String("models")).toArray(), saved);
      stored = slug;
    } else if (action == QLatin1String("providerSettings.saveModel")) {
      const QVariantMap draft = m_modelDraft.value(instanceId);
      if (draft.value(QStringLiteral("slug")).toString() != slug) return true;
      const QVariantList options = draft.value(QStringLiteral("options")).toList();
      refused = ProviderCustomModels::problem(options);
      stored = ProviderCustomModels::setting(slug, draft.value(QStringLiteral("name")).toString(), options);
    }
    if (!refused.isEmpty()) {
      m_modelError.insert(instanceId, refused);
      publish();
      return true;
    }
    m_modelError.remove(instanceId);
    if (action != QLatin1String("providerSettings.addModel")) m_modelDraft.remove(instanceId);
    publish();
    editInstance(instanceId, [action, slug, stored](QJsonObject instance) {
      const QJsonArray current = instance.value(QLatin1String("config")).toObject().value(QLatin1String("customModels")).toArray();
      QJsonArray next;
      for (const QJsonValue& value : current) {
        const QString at = value.isString() ? value.toString().trimmed() : value.toObject().value(QLatin1String("slug")).toString().trimmed();
        if (at != slug) next.append(value);
        else if (action == QLatin1String("providerSettings.saveModel")) next.append(stored);
      }
      if (action == QLatin1String("providerSettings.addModel")) next.append(stored);
      // An emptied list stays stored: it overrides the driver's own `providers` entry.
      QJsonObject config = instance.value(QLatin1String("config")).toObject();
      config.insert(QStringLiteral("customModels"), next);
      instance.insert(QStringLiteral("config"), config);
      return instance;
    });
  } else if (action == QLatin1String("providerSettings.editModel")) {
    const QString slug = input.value(QStringLiteral("slug")).toString();
    m_modelError.remove(instanceId);
    m_modelDraft.remove(instanceId);
    const QJsonValue saved = ProviderInstances::of(shownSettings().value_or(QJsonObject{}), instanceId, driver)
                                 .value(QLatin1String("config")).toObject().value(QLatin1String("customModels"));
    for (const QVariant& model : ProviderCustomModels::read(saved)) {
      if (model.toMap().value(QStringLiteral("slug")) == slug) m_modelDraft.insert(instanceId, model.toMap());
    }
    publish();
  } else if (action == QLatin1String("providerSettings.modelDraft")) {
    if (!m_modelDraft.contains(instanceId)) return true;
    QVariantMap& draft = m_modelDraft[instanceId];
    if (input.contains(QStringLiteral("name"))) draft.insert(QStringLiteral("name"), input.value(QStringLiteral("name")).toString());
    if (input.contains(QStringLiteral("options"))) draft.insert(QStringLiteral("options"), input.value(QStringLiteral("options")).toList());
    const QString source = input.value(QStringLiteral("copyFrom")).toString();
    for (const QVariant& model : ProviderCustomModels::copyable(provider(instanceId).value(QLatin1String("models")).toArray(), driver)) {
      if (!source.isEmpty() && model.toMap().value(QStringLiteral("slug")) == source) {
        draft.insert(QStringLiteral("options"), model.toMap().value(QStringLiteral("options")));
      }
    }
    m_modelError.remove(instanceId);
    publish();
  } else if (action == QLatin1String("providerSettings.reset")) {
    const ProviderDrivers::Driver* found = ProviderDrivers::find(driver);
    if (!found || !found->builtIn || instanceId != driver) return true;
    m_variables.remove(instanceId);
    save([driver](QJsonObject settings, const QString&) {
      settings = ProviderInstances::with(settings, driver, {});
      QJsonObject providers = settings.value(QLatin1String("providers")).toObject();
      providers.remove(driver);
      settings.insert(QStringLiteral("providers"), providers);
      return settings;
    }, {}, QStringLiteral("Could not reset provider instance"));
  } else {
    return false;
  }
  return true;
}

void ProviderSettingsController::configuration(QVariantMap& result, const QString& instanceId, const QString& driver) const {
  const ProviderDrivers::Driver* found = ProviderDrivers::find(driver);
  const bool custom = !(found && found->builtIn && instanceId == driver);
  const std::optional<QJsonObject> settings = shownSettings();
  result.insert(QStringLiteral("editable"), settings.has_value());
  result.insert(QStringLiteral("custom"), custom);
  result.insert(QStringLiteral("placeholder"), found ? found->label : driver);
  result.insert(QStringLiteral("pending"), false);
  const QJsonObject instance = settings ? ProviderInstances::of(*settings, instanceId, driver) : QJsonObject{};
  result.insert(QStringLiteral("resettable"),
                settings && !custom &&
                    (settings->value(QLatin1String("providerInstances")).toObject().contains(instanceId) ||
                     !settings->value(QLatin1String("providers")).toObject().value(driver).toObject().isEmpty()));
  result.insert(QStringLiteral("label"), instance.value(QLatin1String("displayName")).toString());
  result.insert(QStringLiteral("accentColor"), ProviderInstances::accent(instance.value(QLatin1String("accentColor")).toString()));
  result.insert(QStringLiteral("fields"), found ? fields(*found, instance.value(QLatin1String("config")).toObject()) : QVariantList{});
  const QJsonArray environment = instance.value(QLatin1String("environment")).toArray();
  QVariantList secrets;
  const QSet<QString> own = dedicated(driver);
  if (found) {
    for (const ProviderDrivers::Variable& variable : found->variables) {
      const bool stored = std::any_of(environment.begin(), environment.end(), [&variable](const QJsonValue& value) {
        return value.toObject().value(QLatin1String("name")) == variable.name;
      });
      secrets.append(QVariantMap{{QStringLiteral("name"), variable.name},
                                 {QStringLiteral("label"), variable.label},
                                 {QStringLiteral("description"), variable.description},
                                 {QStringLiteral("placeholder"), variable.placeholder},
                                 {QStringLiteral("stored"), stored}});
    }
  }
  result.insert(QStringLiteral("secrets"), secrets);
  QJsonArray rows = m_variables.value(instanceId);
  if (!m_variables.contains(instanceId)) {
    for (const QJsonValue& variable : environment) {
      if (!own.contains(variable.toObject().value(QLatin1String("name")).toString())) rows.append(variable);
    }
  }
  QVariantList variables;
  for (const QJsonValue& value : std::as_const(rows)) {
    const QJsonObject row = value.toObject();
    const bool redacted = row.value(QLatin1String("valueRedacted")).toBool();
    variables.append(QVariantMap{
        {QStringLiteral("name"), row.value(QLatin1String("name")).toString()},
        {QStringLiteral("value"), redacted ? QString() : row.value(QLatin1String("value")).toString()},
        {QStringLiteral("sensitive"), row.value(QLatin1String("sensitive")).toBool()},
        {QStringLiteral("redacted"), redacted},
        {QStringLiteral("invalid"), invalid(row)},
        {QStringLiteral("placeholder"), redacted ? QStringLiteral("Stored secret, enter a new value to replace") : QStringLiteral("value")},
    });
  }
  result.insert(QStringLiteral("variables"), variables);
  // Antigravity takes no custom models (the web's ProviderInstanceCard).
  const bool models = driver != QLatin1String("antigravity");
  result.insert(QStringLiteral("takesModels"), models);
  result.insert(QStringLiteral("customModels"),
                models ? ProviderCustomModels::read(instance.value(QLatin1String("config")).toObject().value(QLatin1String("customModels")))
                       : QVariantList{});
  result.insert(QStringLiteral("modelPresets"), ProviderCustomModels::presets(driver));
  result.insert(QStringLiteral("copyFrom"), ProviderCustomModels::copyable(provider(instanceId).value(QLatin1String("models")).toArray(), driver));
  result.insert(QStringLiteral("modelDraft"), m_modelDraft.contains(instanceId) ? QVariant(m_modelDraft.value(instanceId)) : QVariant());
  result.insert(QStringLiteral("modelError"), m_modelError.value(instanceId));
}

// Instances added on the shown environment that it has yet to list.
QVariantList ProviderSettingsController::pendingEntries() const {
  QVariantList result;
  const std::optional<QJsonObject> settings = shownSettings();
  if (!settings || !m_providers) return result;
  const QJsonObject instances = settings->value(QLatin1String("providerInstances")).toObject();
  for (auto it = instances.begin(); it != instances.end(); ++it) {
    if (!provider(it.key()).isEmpty()) continue;
    const QJsonObject instance = it.value().toObject();
    const QString driver = instance.value(QLatin1String("driver")).toString();
    if (driver.isEmpty()) continue;
    QVariantMap row = entry(QJsonObject{{QStringLiteral("instanceId"), it.key()},
                                        {QStringLiteral("driver"), driver},
                                        {QStringLiteral("displayName"), instance.value(QLatin1String("displayName"))},
                                        {QStringLiteral("enabled"), instance.value(QLatin1String("enabled")).toBool(true)},
                                        {QStringLiteral("installed"), true}});
    row.insert(QStringLiteral("headline"), QStringLiteral("Checking provider status"));
    row.insert(QStringLiteral("detail"), QStringLiteral("Waiting for the server to report installation and authentication details."));
    row.insert(QStringLiteral("pending"), true);
    row.insert(QStringLiteral("account"), QVariant::fromValue(nullptr));
    result.append(row);
  }
  return result;
}

QVariant ProviderSettingsController::wizard() const {
  if (!m_open || !m_wizard) return QVariant::fromValue(nullptr);
  QVariantList drivers;
  for (const ProviderDrivers::Driver& driver : ProviderDrivers::all()) {
    // The ACP Registry is added by searching it.
    if (driver.id == kRegistry) continue;
    drivers.append(QVariantMap{{QStringLiteral("id"), driver.id}, {QStringLiteral("label"), driver.label}, {QStringLiteral("badge"), driver.badge}});
  }
  const ProviderDrivers::Driver& driver = *ProviderDrivers::find(m_wizard->driver);
  const QJsonObject identity = m_wizard->identity.value(driver.id);
  const QString label = identity.contains(QLatin1String("label")) ? identity.value(QLatin1String("label")).toString() : driver.label;
  const QSet<QString> taken = ProviderInstances::taken(shownSettings().value_or(QJsonObject{}), m_providers.value_or(QJsonArray{}));
  const QString id = identity.contains(QLatin1String("instanceId")) ? identity.value(QLatin1String("instanceId")).toString()
                                                                    : ProviderDrivers::deriveId(driver.id, label, taken);
  return QVariantMap{
      {QStringLiteral("step"), m_wizard->step},
      {QStringLiteral("steps"), driver.id == kRegistry && !m_wizard->manual ? kRegistrySteps : kSteps},
      {QStringLiteral("registry"), registry()},
      {QStringLiteral("drivers"), drivers},
      {QStringLiteral("driver"), driver.id},
      {QStringLiteral("driverLabel"), driver.label},
      {QStringLiteral("label"), label},
      {QStringLiteral("accentColor"), identity.value(QLatin1String("accentColor")).toString()},
      {QStringLiteral("instanceId"), id},
      {QStringLiteral("instanceIdError"), m_wizard->attempted ? ProviderDrivers::validateId(id, taken) : QString()},
      {QStringLiteral("fields"), fields(driver, m_wizard->config.value(driver.id))},
      {QStringLiteral("saving"), m_wizard->saving},
  };
}
