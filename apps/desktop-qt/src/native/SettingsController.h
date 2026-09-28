#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QVariant>

#include <functional>
#include <optional>

#include "NativeController.h"

class NodeClient;
class ShellBridge;

// The settings the shell reads and changes, in two stores. The `Settings`
// QML singleton; C++ reaches it with NativeShell::controller<SettingsController>().
//
// The node's settings document (`hal-c2.readSettings` / `hal-c2.writeSettings`,
// apps/server-ex lib/hal_c2/settings.ex): one versioned document that every
// client of the environment shares. A change is an edit of the whole document
// written at the version it was read at; when another client saved first the
// node refuses it as stale, and the edit is applied again to what the node now
// holds, so no one's change is lost to a stale copy. The node's `config` shape
// comes with it: the server config, and the themes the node publishes.
//
// This device's preferences (a JSON file in the shell's config directory):
// what belongs to this desktop and no other client, such as its appearance
// and theme. They are here before the node is.
//
//   Settings.value("textGenerationModelSelection.provider")   // node document
//   Settings.write("enableAssistantStreaming", true)            // null removes
//   Settings.device.appearance, Settings.writeDevice("appearance", "dark")
//
// The rows of the settings pages go through `setting` / `set` / `reset`,
// which know which store a key is in and its default (the web's
// DEFAULT_CLIENT_SETTINGS and DEFAULT_SERVER_SETTINGS). Failures are toasted.
// The page, while it still renders the centre, follows this device's rows
// (`clientSettings.follow {settings}`) instead of its own storage.
class SettingsController : public QObject, public NativeController {
  Q_OBJECT
  // The node's document has been read since the shell connected.
  Q_PROPERTY(bool ready READ ready NOTIFY settingsChanged)
  Q_PROPERTY(QVariantMap document READ documentVariant NOTIFY settingsChanged)
  Q_PROPERTY(int version READ version NOTIFY settingsChanged)
  // Why the last read or change failed; empty once one succeeds.
  Q_PROPERTY(QString error READ error NOTIFY settingsChanged)
  // The node's ServerConfig (packages/contracts server.ts), as `config` frames
  // keep it.
  Q_PROPERTY(QVariantMap config READ configVariant NOTIFY configChanged)
  // EnvironmentTheme[] the node publishes (`config.themes`).
  Q_PROPERTY(QVariantList themes READ themesVariant NOTIFY themesChanged)
  Q_PROPERTY(QVariantMap device READ deviceVariant NOTIFY deviceChanged)
  // Why this device's preferences could not be read or saved; empty otherwise.
  Q_PROPERTY(QString deviceError READ deviceError NOTIFY deviceChanged)

public:
  // Returns the whole new document from the current one.
  using Edit = std::function<QJsonObject(const QJsonObject& settings)>;
  using Done = std::function<void(const std::optional<QString>& error)>;

  SettingsController(ShellBridge* bridge, NodeClient* client, QObject* parent = nullptr);

  // Subscribes to the node's config and reads its settings.
  void activate() override;
  bool handle(const QString&, const QVariant&) override { return false; }
  // A (re)loaded page gets this device's rows.
  void pageReady();

  bool ready() const { return m_ready; }
  QJsonObject settings() const { return m_settings; }
  int version() const { return m_version; }
  QString error() const { return m_error; }
  QJsonObject config() const { return m_config; }
  QJsonArray themes() const { return m_themes; }

  // Applies `edit` to the node's document and saves it; `done` says how it
  // went. A stale save re-reads and applies `edit` again, a few times.
  void change(Edit edit, Done done = {});
  // A value in the node's document by dotted path; undefined when absent.
  Q_INVOKABLE QVariant value(const QString& path) const;
  // Sets one value by dotted path; null removes it.
  Q_INVOKABLE void write(const QString& path, const QVariant& value);

  // This device's preferences file; read now, and saved there on change.
  void setDevicePath(const QString& path);
  QString devicePath() const { return m_devicePath; }
  QJsonObject deviceSettings() const { return m_device; }
  // Replaces this device's preferences; false (and `deviceError`) when they
  // cannot be saved, leaving them as they were.
  bool setDeviceSettings(const QJsonObject& device);
  Q_INVOKABLE QVariant deviceValue(const QString& key) const { return m_device.value(key).toVariant(); }
  // One preference; null removes it.
  Q_INVOKABLE bool writeDevice(const QString& key, const QVariant& value);
  QString deviceError() const { return m_deviceError; }

  // A row's value (its default when unset), whether it is at its default, and
  // changing or resetting it in the store it belongs to. Unknown keys are
  // undefined and ignored.
  Q_INVOKABLE QVariant setting(const QString& key) const;
  Q_INVOKABLE QVariant defaultOf(const QString& key) const;
  Q_INVOKABLE bool isDefault(const QString& key) const;
  // Whether a row is kept on this device rather than by the node.
  Q_INVOKABLE bool onDevice(const QString& key) const;
  Q_INVOKABLE void set(const QString& key, const QVariant& value);
  Q_INVOKABLE void reset(const QString& key);

  // What `config.themes` delivers; tests set it.
  void setThemes(const QJsonArray& themes);

signals:
  void settingsChanged();
  void configChanged();
  void themesChanged();
  void deviceChanged();

private:
  void read(std::function<void()> then = {});
  void attempt(Edit edit, Done done, int retries);
  void onConfig(const QJsonObject& frame);
  void fail(const QString& error);
  void toast(const QString& title, const QString& reason);
  void follow(bool force = false);
  QVariantMap documentVariant() const { return m_settings.toVariantMap(); }
  QVariantMap configVariant() const { return m_config.toVariantMap(); }
  QVariantList themesVariant() const { return m_themes.toVariantList(); }
  QVariantMap deviceVariant() const { return m_device.toVariantMap(); }

  NodeClient* m_client;
  bool m_active = false;
  bool m_ready = false;
  QJsonObject m_settings;
  int m_version = 0;
  QString m_error;
  // Bumped by every read and save; a read's answer lands only if nothing was
  // read or saved since it was asked.
  quint64 m_generation = 0;
  QJsonObject m_config;
  QJsonArray m_themes;
  QString m_devicePath;
  QJsonObject m_device;
  QString m_deviceError;
  ShellBridge* m_bridge;
  // What the page was last told of this device's rows.
  QJsonObject m_followed;
};
