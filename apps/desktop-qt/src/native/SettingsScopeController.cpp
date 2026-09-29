#include "SettingsScopeController.h"

#include <QPointer>

#include <algorithm>

#include "NativeShell.h"
#include "NavigationController.h"
#include "NodeClient.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarController.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<SettingsScopeController> registrar(QStringLiteral("settingsScope"), {QStringLiteral("settingsScope")});

const QString kKey = QStringLiteral("settingsScope");

// The native sections that edit environments' settings, which follow the scope.
const QStringList kScopedSections{QStringLiteral("/settings/storage"), QStringLiteral("/settings/source-control"),
                                  QStringLiteral("/settings/projects"), QStringLiteral("/settings/scheduled-tasks"),
                                  QStringLiteral("/settings/integrations")};

}  // namespace

SettingsScopeController::SettingsScopeController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store), m_documents(new EnvironmentSettings(client, this)) {
  connect(m_documents, &EnvironmentSettings::frame, this, [this](const QString& environmentId, const QJsonObject& frame) {
    const QString type = frame.value(QLatin1String("t")).toString();
    if (type == QLatin1String("config.providers")) {
      m_providers.insert(environmentId, frame.value(QLatin1String("providers")).toArray());
      emit changed();
      return;
    }
    if (type != QLatin1String("config")) return;
    const QJsonObject config = frame.value(QLatin1String("config")).toObject();
    m_capabilities.insert(environmentId, config.value(QLatin1String("environment")).toObject().value(QLatin1String("capabilities")).toObject());
    m_providers.insert(environmentId, config.value(QLatin1String("providers")).toArray());
  });
  connect(m_documents, &EnvironmentSettings::changed, this, [this] {
    publish();
    emit changed();
  });
}

void SettingsScopeController::activate() {
  if (m_active) return;
  m_active = true;
  m_bridge->claimKey(kKey);
  auto* navigation = NativeShell::of(this)->controller<NavigationController>();
  const auto follow = [this, navigation] {
    const NavigationController::Route& route = navigation->route();
    m_open = route.kind == QLatin1String("settings") && kScopedSections.contains(route.section);
    update();
  };
  connect(navigation, &NavigationController::changed, this, follow);
  // Projects and environments that come and go change what the scope covers.
  connect(m_store, &ShellStore::changed, this, [this] {
    // After the sidebar has grouped the projects anew.
    QMetaObject::invokeMethod(this, &SettingsScopeController::update, Qt::QueuedConnection);
  });
  follow();
}

bool SettingsScopeController::handle(const QString& action, const QVariant& payload) {
  if (!m_active || !action.startsWith(QLatin1String("settingsScope."))) return false;
  const QVariantMap input = payload.toMap();
  if (action == QLatin1String("settingsScope.project")) {
    m_projectKey = input.value(QStringLiteral("key")).toString();
  } else if (action == QLatin1String("settingsScope.environment")) {
    m_environmentId = input.value(QStringLiteral("id")).toString();
  } else {
    return true;
  }
  update();
  return true;
}

QString SettingsScopeController::label(const QString& environmentId) const {
  const QString label = m_store->environment(environmentId).value(QLatin1String("label")).toString();
  if (!label.isEmpty()) return label;
  return environmentId == m_client->environment() ? QStringLiteral("This machine") : environmentId;
}

// The environments the scope can choose: this machine first, the others by name.
QStringList SettingsScopeController::listed() const {
  const QString local = m_client->environment();
  QStringList ids;
  for (const QString& environmentId : m_store->environments()) {
    if (environmentId == local || m_store->reaches(environmentId)) ids.append(environmentId);
  }
  ids.removeDuplicates();
  std::sort(ids.begin(), ids.end(), [this, &local](const QString& a, const QString& b) {
    if ((a == local) != (b == local)) return a == local;
    return QString::localeAwareCompare(label(a).toLower(), label(b).toLower()) < 0;
  });
  return ids;
}

// resolveSettingsScope: a selection that no longer exists is unavailable, and
// never broadens to everything.
SettingsScopeController::Resolved SettingsScopeController::resolve() const {
  Resolved resolved;
  const QStringList environments = listed();
  if (!m_environmentId.isEmpty() && !environments.contains(m_environmentId)) {
    return {QStringLiteral("unavailable"), QStringLiteral("This environment is no longer available."), {}, {}};
  }
  if (!m_projectKey.isEmpty()) {
    const sidebar::ProjectGroup* group = NativeShell::of(this)->sidebar()->group(m_projectKey);
    if (group == nullptr) return {QStringLiteral("unavailable"), QStringLiteral("This project is no longer available."), {}, {}};
    for (const sidebar::Project& member : group->members) {
      if (!m_environmentId.isEmpty() && member.environmentId != m_environmentId) continue;
      if (!environments.contains(member.environmentId) || resolved.members.contains(member.environmentId)) continue;
      resolved.members.insert(member.environmentId, member.id);
      resolved.environments.append(member.environmentId);
    }
    if (resolved.environments.isEmpty()) {
      return {QStringLiteral("unavailable"), QStringLiteral("This project has no checkout on this environment."), {}, {}};
    }
    resolved.kind = QStringLiteral("project");
    return resolved;
  }
  resolved.kind = m_environmentId.isEmpty() ? QStringLiteral("all") : QStringLiteral("environment");
  resolved.environments = m_environmentId.isEmpty() ? environments : QStringList{m_environmentId};
  return resolved;
}

void SettingsScopeController::update() {
  if (!m_active) return;
  const Resolved resolved = resolve();
  m_members = resolved.members;
  QStringList targets;
  if (m_open) {
    for (const QString& environmentId : resolved.environments) {
      if (m_store->environmentOnline(environmentId)) targets.append(environmentId);
    }
  }
  // setTargets announces a change of targets itself.
  if (targets != m_documents->targets()) {
    m_documents->setTargets(targets);
    return;
  }
  publish();
  emit changed();
}

QStringList SettingsScopeController::lacking(const QString& capability) const {
  QStringList result;
  for (const QString& environmentId : targets()) {
    if (!m_documents->settings(environmentId)) continue;
    if (m_capabilities.value(environmentId).value(capability) != QJsonValue(true)) result.append(environmentId);
  }
  return result;
}

EnvironmentSettings::Reading SettingsScopeController::read(const Pick& pick) const {
  return m_documents->read([this, pick](const QJsonObject& settings, const QString& environmentId) {
    return pick(settings, m_members.value(environmentId));
  });
}

bool SettingsScopeController::covers(const QString& environmentId, const QString& projectId) const {
  const Resolved resolved = resolve();
  if (!resolved.environments.contains(environmentId)) return false;
  return resolved.kind != QLatin1String("project") || resolved.members.value(environmentId) == projectId;
}

bool SettingsScopeController::online(const QString& environmentId) const {
  return m_store->environmentOnline(environmentId);
}

bool SettingsScopeController::editable() const {
  return disabledReason().isEmpty();
}

QString SettingsScopeController::disabledReason() const {
  const Resolved resolved = resolve();
  if (resolved.kind == QLatin1String("unavailable")) return resolved.message;
  if (targets().isEmpty()) return QStringLiteral("Reconnect the selected environment to change this setting.");
  for (const QString& environmentId : targets()) {
    if (!m_store->mayOperate(environmentId)) {
      return QStringLiteral("This session can view %1's settings but can't change them.").arg(label(environmentId));
    }
  }
  return {};
}

void SettingsScopeController::write(const Edit& edit, const QString& failureTitle) {
  const QString reason = disabledReason();
  auto* toasts = NativeShell::of(this)->controller<ToastController>();
  if (!reason.isEmpty()) {
    if (toasts) toasts->show(QStringLiteral("warning"), failureTitle.isEmpty() ? QStringLiteral("Setting not saved") : failureTitle, reason);
    return;
  }
  const QHash<QString, QString> members = m_members;
  const QPointer<SettingsScopeController> self(this);
  m_documents->change(
      [edit, members](QJsonObject settings, const QString& environmentId) { return edit(settings, members.value(environmentId)); },
      [self, failureTitle](const QHash<QString, QString>& failed, int saved) {
        if (!self || failed.isEmpty()) return;
        QStringList labels;
        for (const QString& environmentId : self->targets()) {
          if (failed.contains(environmentId)) labels.append(self->label(environmentId));
        }
        if (auto* toasts = NativeShell::of(self)->controller<ToastController>()) {
          const QString title = !failureTitle.isEmpty() ? failureTitle
                                : saved > 0              ? QStringLiteral("Setting saved on some environments")
                                                         : QStringLiteral("Setting not saved");
          toasts->error(title,
                        QStringLiteral("Could not update %1.%2")
                            .arg(labels.join(QStringLiteral(", ")),
                                 saved > 0 ? QStringLiteral(" The other selected environments saved the change.") : QString()));
        }
      });
}

QJsonObject SettingsScopeController::withOverride(QJsonObject settings, const QString& projectId, const QString& key,
                                                  const QJsonValue& value) {
  QJsonObject overrides = settings.value(QLatin1String("projectSettingsOverrides")).toObject();
  QJsonObject entry = overrides.value(projectId).toObject();
  if (value.isUndefined()) {
    entry.remove(key);
  } else {
    entry.insert(key, value);
  }
  if (entry.isEmpty()) {
    overrides.remove(projectId);
  } else {
    overrides.insert(projectId, entry);
  }
  settings.insert(QStringLiteral("projectSettingsOverrides"), overrides);
  return settings;
}

QJsonValue SettingsScopeController::overrideOf(const QJsonObject& settings, const QString& projectId, const QString& key) {
  const QJsonObject entry = settings.value(QLatin1String("projectSettingsOverrides")).toObject().value(projectId).toObject();
  return entry.contains(key) ? entry.value(key) : QJsonValue(QJsonValue::Undefined);
}

void SettingsScopeController::publish() {
  if (!m_active) return;
  const Resolved resolved = resolve();
  QVariantList environments;
  for (const QString& id : listed()) {
    environments.append(QVariantMap{
        {QStringLiteral("id"), id}, {QStringLiteral("label"), label(id)}, {QStringLiteral("online"), m_store->environmentOnline(id)}});
  }
  QVariantList projects;
  QString projectLabel = QStringLiteral("All projects");
  for (const sidebar::ProjectGroup& group : NativeShell::of(this)->sidebar()->groups()) {
    const QString title = group.summary.value(QStringLiteral("displayName")).toString();
    projects.append(QVariantMap{{QStringLiteral("key"), group.key}, {QStringLiteral("title"), title}});
    if (group.key == m_projectKey) projectLabel = title;
  }
  if (!m_projectKey.isEmpty() && projectLabel == QLatin1String("All projects")) projectLabel = QStringLiteral("Unavailable project");
  QString environmentLabel = QStringLiteral("All environments");
  if (!m_environmentId.isEmpty()) {
    environmentLabel = listed().contains(m_environmentId) ? label(m_environmentId) : QStringLiteral("Unavailable environment");
  }
  const QString reason = disabledReason();
  m_bridge->publish(kKey, QVariantMap{
                              {QStringLiteral("kind"), resolved.kind},
                              {QStringLiteral("projectKey"), m_projectKey},
                              {QStringLiteral("environmentId"), m_environmentId},
                              {QStringLiteral("projectLabel"), projectLabel},
                              {QStringLiteral("environmentLabel"), environmentLabel},
                              {QStringLiteral("connective"), m_environmentId.isEmpty() ? QStringLiteral("across") : QStringLiteral("on")},
                              {QStringLiteral("message"), resolved.message},
                              {QStringLiteral("projects"), projects},
                              {QStringLiteral("environments"), environments},
                              {QStringLiteral("editable"), reason.isEmpty()},
                              {QStringLiteral("disabledReason"), reason},
                          });
}
