#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QStringList>
#include <QVariantMap>

#include <functional>

#include "EnvironmentSettings.h"
#include "NativeController.h"

class NodeClient;
class ShellBridge;
class ShellStore;

// Where the native settings sections that edit environments' settings apply
// (the web's settingsScope.ts and scopedSettings.ts): all projects or one
// logical project, across every environment or on one. A change is written
// to every connected environment in the scope, and a project's to its
// `projectSettingsOverrides` entry on each environment with a checkout of it.
// The environments' documents are followed while a settings page shows.
//
// Publishes `settingsScope`: {kind: all | environment | project | unavailable,
// projectKey, environmentId ("" for all), projectLabel, environmentLabel,
// connective ("across" | "on"), message (why the scope is unavailable),
// projects [{key, title}], environments [{id, label, online}], editable, and
// why not: disabledReason}.
//
// Actions: `settingsScope.project {key}` ("" for all projects) and
// `settingsScope.environment {id}` ("" for all environments); each keeps the
// other axis.
//
// Sections read and write through it:
//
//   auto* scope = NativeShell::of(this)->controller<SettingsScopeController>();
//   scope->read([](const QJsonObject& settings, const QString& projectId) { ... });
//   scope->write([](QJsonObject settings, const QString& projectId) { ...; return settings; });
class SettingsScopeController : public QObject, public NativeController {
  Q_OBJECT

public:
  // A value from an environment's document, and for a project scope the
  // project on that environment ("" otherwise).
  using Pick = std::function<QJsonValue(const QJsonObject& settings, const QString& projectId)>;
  using Edit = std::function<QJsonObject(QJsonObject settings, const QString& projectId)>;

  SettingsScopeController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  bool projectScope() const { return !m_projectKey.isEmpty(); }
  // The logical project picked ("" for all projects), and the environment
  // picked ("" for all environments).
  QString projectKey() const { return m_projectKey; }
  QString environmentFilter() const { return m_environmentId; }
  // The connected environments a change is written to, in reading order.
  QStringList targets() const { return m_documents->targets(); }
  QString label(const QString& environmentId) const;
  // Whether every connected target's environment has the capability
  // (ServerConfig environment.capabilities); the ones that lack it.
  QStringList lacking(const QString& capability) const;
  EnvironmentSettings::Reading read(const Pick& pick) const;
  // Changes every target; a failure is toasted with the environments that
  // could not save, titled `failureTitle` when given. Nothing is written
  // while the scope is not editable.
  void write(const Edit& edit, const QString& failureTitle = {});
  bool editable() const;
  QString disabledReason() const;
  // The scope's environments, connected or not ("unavailable" has none), and
  // for a project scope its checkout on one ("" otherwise).
  QString kind() const { return resolve().kind; }
  QStringList environments() const { return resolve().environments; }
  QString projectOn(const QString& environmentId) const { return m_members.value(environmentId); }
  // Whether a project of the environment is in the scope.
  bool covers(const QString& environmentId, const QString& projectId) const;
  bool online(const QString& environmentId) const;
  std::optional<QJsonObject> settings(const QString& environmentId) const { return m_documents->settings(environmentId); }
  // A target's providers (ServerConfig providers), as its config frames last said.
  QJsonArray providers(const QString& environmentId) const { return m_providers.value(environmentId); }

  // `settings` with the project's override of `key` set; undefined removes it,
  // and an override left empty goes.
  static QJsonObject withOverride(QJsonObject settings, const QString& projectId, const QString& key, const QJsonValue& value);
  static QJsonValue overrideOf(const QJsonObject& settings, const QString& projectId, const QString& key);

signals:
  // The scope, or a target's settings, changed.
  void changed();

private:
  struct Resolved {
    QString kind;
    QString message;
    // The selected environments, connected or not, and by environment the
    // project's checkout there.
    QStringList environments;
    QHash<QString, QString> members;
  };
  Resolved resolve() const;
  QStringList listed() const;
  void update();
  void publish();

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  EnvironmentSettings* m_documents;
  bool m_active = false;
  bool m_open = false;
  QString m_projectKey;
  QString m_environmentId;
  // The picked project's folders when it was last found, so a regrouping
  // that renames its key keeps it picked.
  QStringList m_followed;
  QHash<QString, QString> m_members;
  QHash<QString, QJsonObject> m_capabilities;
  QHash<QString, QJsonArray> m_providers;
};
