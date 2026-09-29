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
// listed), refreshing, providers [{instanceId, driver, name, version,
// enabled, installed, status, headline, detail, email, models [{slug, name}],
// advisory {title, detail, updateCommand, targetVersion, strong} | null,
// canUpdate, updating, account: null | {description, canSignIn, signInLabel,
// canCancel, canSignOut, url, userCode, error}}]}.
//
// Actions: `providerSettings.environment {id}`, `.refresh`, `.enable
// {instanceId, enabled}`, `.signIn {instanceId}`, `.cancelSignIn
// {instanceId}`, `.openSignIn {instanceId}`, `.signOut {instanceId}` (asks
// first), `.update {instanceId}`, `.copyUpdateCommand {instanceId}`.
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
  void editSettings(const QString& environmentId, std::function<QJsonObject(QJsonObject)> edit, int retries);
  void call(const QString& instanceId, const QString& method, const QJsonObject& payload, const QString& failure);
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
  // The followed environment's `config` shape and the providers it brought.
  QString m_followed;
  int m_config = -1;
  std::optional<QJsonArray> m_providers;
  // Each signing-in provider's `providerAuth` shape and its last state.
  QHash<QString, int> m_auth;
  QHash<QString, QJsonObject> m_authState;
  // Why the last sign-in call failed, by instance.
  QHash<QString, QString> m_authError;
  QSet<QString> m_busy;
  QSet<QString> m_updating;
  int m_refreshing = 0;
};
