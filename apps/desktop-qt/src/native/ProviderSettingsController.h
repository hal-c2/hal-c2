#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QVariantMap>

#include <functional>
#include <optional>

#include "NativeController.h"

class EnvironmentSettings;

// getProviderSummary: the headline and detail under a provider's name.
QPair<QString, QString> providerSummary(const QJsonObject& provider);
class NodeClient;
class ShellBridge;
class ShellStore;

// The Providers settings section ("/settings/providers"), which the shell
// owns: the providers configured on one environment, how each stands
// (installed, signed in, its version and models), turning one on or off,
// signing in and out, and updating it (the web's ProviderSettingsPanel).
//
// While the section shows, the chosen environment's `config` shape brings its
// providers, and each provider that signs in from HAL-C2 has its
// `providerAuth` shape followed (only on environments a cluster node serves;
// the shape is node-addressed). Turning a provider off is a settings edit on
// that environment, as the node reads it (HalC2.Settings provider_enabled?).
//
// Publishes `providerSettings`: {open, environmentId, environments [{id,
// label, local, online}] (this machine first, the others by name), status:
// ready | loading | offline | none, title, description (why nothing is
// listed), refreshing, readOnly and readOnlyDescription (the session may
// only view that environment: its link lacks orchestration:operate, and every
// change is ignored), providers [{instanceId, driver, name, version,
// enabled, installed, status, headline, detail, email, models [{slug, name}],
// advisory {title, detail, updateCommand, targetVersion, strong} | null,
// canUpdate, installLabel ("Install v1.2.3" when the recommended version can
// be installed, else empty), updating, account: null | {description, canSignIn, signInLabel,
// canCancel, canSignOut, url, userCode, error, methods [{id, name}] (a
// choice), terminal: null | {key, output, offset} (the agent's login
// terminal), credentials [{name, label, secret}], acceptsCallback (a pasted
// final address finishes it), docsUrl}, and how it is configured
// (ProviderSettingsInstances.cpp): custom, resettable, label, accentColor,
// placeholder, fields, secrets, variables, pending}, and a registry agent's
// sessions and model providers, acp (ProviderSettingsAcp.cpp)], health: null |
// {seconds, defaultSeconds, step} (the background provider health check
// interval), hubs: null | [{id, label, description}] (its usage-limit
// hubs), wizard: null | the add-provider wizard}.
//
// Actions: `providerSettings.environment {id}`, `.refresh`, `.enable
// {instanceId, enabled}`, `.signIn {instanceId}`, `.cancelSignIn
// {instanceId}`, `.openSignIn {instanceId}`, `.signOut {instanceId}` (asks
// first), `.signIn {instanceId, methodId}`, `.signInTerminal {instanceId,
// data, columns, rows}`, `.signInCredentials {instanceId, values}`,
// `.signInCallback {instanceId, url}`, `.copySignInLink {instanceId}`,
// `.openDocs {instanceId}`, `.update {instanceId}`, `.copyUpdateCommand {instanceId}`,
// `.healthInterval {seconds}` (0 turns it off), `.resetHealthInterval`,
// `.addHub {url, key, label}` (a CLIProxyAPI hub; url and key required),
// `.removeHub {id}` (its key is deleted from the node), and
// the actions ProviderSettingsInstances.cpp, ProviderSettingsRegistry.cpp and
// ProviderSettingsAcp.cpp list.
class ProviderSettingsController : public QObject, public NativeController {
  Q_OBJECT

public:
  ProviderSettingsController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;
  // Writes the clipboard, false when it could not; tests read what was written.
  void setClipboardWriter(std::function<bool(const QString& text)> write) { m_writeClipboard = std::move(write); }

private:
  void setOpen(bool open);
  void update();
  void follow(const QString& environmentId);
  void unfollow();
  void followAuth();
  QString chosen() const;
  QString label(const QString& environmentId) const;
  QJsonObject provider(const QString& instanceId) const;
  void setEnabled(const QString& instanceId, bool enabled);
  // Edits the shown environment's settings; `done` learns whether it saved.
  void save(const std::function<QJsonObject(QJsonObject, const QString&)>& edit, const std::function<void(bool saved)>& done = {},
            const QString& failure = {});
  // ProviderSettingsInstances.cpp: adding, editing and deleting instances.
  bool handleInstance(const QString& action, const QVariantMap& input);
  std::optional<QJsonObject> shownSettings() const;
  QString driverOf(const QString& instanceId) const;
  void editInstance(const QString& instanceId, const std::function<QJsonObject(QJsonObject)>& change,
                    const std::function<void(bool saved)>& done = {});
  void setVariables(const QString& instanceId, const QJsonArray& rows);
  void configuration(QVariantMap& result, const QString& instanceId, const QString& driver) const;
  QVariantList pendingEntries() const;
  QVariant wizard() const;
  // ProviderSettingsRegistry.cpp: the wizard's ACP Registry search.
  bool handleRegistry(const QString& action, const QVariantMap& input);
  void searchRegistry(const QString& query);
  QString registrySelectionError() const;
  QVariantMap registry() const;
  // ProviderSettingsAcp.cpp: a registry agent's sessions, model providers and sign-out.
  bool handleAcp(const QString& action, const QVariantMap& input);
  QString acpProject(const QString& instanceId) const;
  void acpCall(const QString& instanceId, const QString& busy, const QString& method, QJsonObject payload, const QString& failure,
               const std::function<void(const QJsonObject&)>& done);
  void listAcpProviders(const QString& instanceId, const QString& projectId);
  QVariant acp(const QJsonObject& provider) const;
  // ProviderSettingsRuntime.cpp: the runtime the node installs itself (Antigravity).
  void followRuntime();
  void unfollowRuntime();
  bool handleRuntime(const QString& action, const QVariantMap& input);
  void runtimeCall(const QString& instanceId, const QString& method, const QJsonObject& payload);
  QVariant runtime(const QJsonObject& provider) const;
  QVariant health() const;
  QVariant hubs() const;
  void call(const QString& instanceId, const QString& method, const QJsonObject& payload, const QString& failure);
  void sendTerminal(const QString& instanceId);
  void publish();
  QVariantMap entry(const QJsonObject& provider) const;

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  std::function<bool(const QString&)> m_writeClipboard;
  bool m_active = false;
  bool m_open = false;
  // The environment the user chose; empty for this machine.
  QString m_environment;
  // The followed environment, its settings and the providers its `config`
  // shape brought.
  QString m_followed;
  // Which following an answer belongs to: a new one with each unfollow, so
  // an answer from before a switch away and back is dropped.
  quint64 m_following = 0;
  EnvironmentSettings* m_scope;
  std::optional<QJsonArray> m_providers;
  // Each signing-in provider's `providerAuth` shape and its last state.
  QHash<QString, int> m_auth;
  QHash<QString, QJsonObject> m_authState;
  // Each managed runtime's `providerInstall` shape, its last state, and why
  // the last call about it failed.
  QHash<QString, int> m_install;
  QHash<QString, QJsonObject> m_installState;
  QHash<QString, QString> m_installError;
  // Why the last sign-in call failed, by instance.
  QHash<QString, QString> m_authError;
  QSet<QString> m_busy;
  // Input for each login terminal, sent one request at a time.
  QHash<QString, QList<QJsonObject>> m_terminalQueue;
  QSet<QString> m_terminalSending;
  QSet<QString> m_updating;
  // The add-provider wizard while it shows: the chosen driver, what was
  // entered for each driver (label, accentColor, instanceId when typed) and
  // its config, the step (Provider, Identity, Config), whether moving on was
  // tried (which shows the id's error), and whether it is saving. Its ACP
  // Registry search: the query, the agents found (none before the first
  // answer), the search in flight, why it failed, the agent being prepared,
  // the one chosen ({id, name, version}), and whether one is entered by hand.
  // Each registry agent's sessions and model providers as last listed from
  // the chosen project, the next page's cursor, and what runs ("" for nothing).
  struct Acp {
    QString projectId;
    std::optional<QJsonArray> sessions;
    QString nextCursor;
    std::optional<QJsonArray> providers;
    QString busy;
  };
  QHash<QString, Acp> m_acp;
  struct Wizard {
    int id = 0;  // a new one with each wizard opened
    QString driver = QStringLiteral("codex");
    QHash<QString, QJsonObject> identity;
    QHash<QString, QJsonObject> config;
    int step = 0;
    bool attempted = false;
    bool saving = false;
    QString query;
    std::optional<QJsonArray> agents;
    int generation = 0;
    bool searching = false;
    QString registryError;
    QString preparing;
    QJsonObject selected;
    bool manual = false;
  };
  std::optional<Wizard> m_wizard;
  int m_wizards = 0;
  // Variable rows being edited that cannot be saved yet (a blank or invalid
  // name), by instance.
  QHash<QString, QJsonArray> m_variables;
  // The custom model being edited ({slug, name, options}), and why the last
  // custom model change was refused, by instance.
  QHash<QString, QVariantMap> m_modelDraft;
  QHash<QString, QString> m_modelError;
  int m_refreshing = 0;
};
