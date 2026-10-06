#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariant>

#include <functional>
#include <optional>

#include "NativeController.h"

class NativeWindow;
class SettingsScopeController;
class McClient;
class ShellBridge;

// The settings the shell reads and changes, in two stores. The `Settings`
// QML singleton; C++ reaches it with NativeShell::controller<SettingsController>().
//
// The MC's settings document (`hal-c2.readSettings` / `hal-c2.writeSettings`,
// apps/server-ex lib/hal_c2/settings.ex): one versioned document that every
// client of the environment shares. A change is an edit of the whole document
// written at the version it was read at; when another client saved first the
// MC refuses it as stale, and the edit is applied again to what the MC now
// holds, so no one's change is lost to a stale copy. The MC's `config` shape
// comes with it: the server config, and the themes the MC publishes.
//
// This device's preferences (a JSON file in the shell's config directory):
// what belongs to this desktop and no other client, such as its appearance
// and theme. They are here before the MC is.
//
//   Settings.value("textGenerationModelSelection.provider")   // MC document
//   Settings.write("enableAssistantStreaming", true)            // null removes
//   Settings.device.appearance, Settings.writeDevice("appearance", "dark")
//
// The rows of the settings pages go through `setting` / `set` / `reset`,
// which know which store a key is in and its default (the web's
// DEFAULT_CLIENT_SETTINGS and DEFAULT_SERVER_SETTINGS). Failures are toasted.
class SettingsController : public QObject, public NativeController {
  Q_OBJECT
  // The MC's document has been read since the shell connected.
  Q_PROPERTY(bool ready READ ready NOTIFY settingsChanged)
  Q_PROPERTY(QVariantMap document READ documentVariant NOTIFY settingsChanged)
  Q_PROPERTY(int version READ version NOTIFY settingsChanged)
  // Why the last read or change failed; empty once one succeeds.
  Q_PROPERTY(QString error READ error NOTIFY settingsChanged)
  // The MC's ServerConfig (packages/contracts server.ts), as `config` frames
  // keep it.
  Q_PROPERTY(QVariantMap config READ configVariant NOTIFY configChanged)
  // EnvironmentTheme[] the MC publishes (`config.themes`).
  Q_PROPERTY(QVariantList themes READ themesVariant NOTIFY themesChanged)
  Q_PROPERTY(QVariantMap device READ deviceVariant NOTIFY deviceChanged)
  // Why this device's preferences could not be read or saved; empty otherwise.
  Q_PROPERTY(QString deviceError READ deviceError NOTIFY deviceChanged)

public:
  // Returns the whole new document from the current one.
  using Edit = std::function<QJsonObject(const QJsonObject& settings)>;
  using Done = std::function<void(const std::optional<QString>& error)>;

  SettingsController(ShellBridge*, McClient* client, QObject* parent = nullptr);

  // Subscribes to the MC's config and reads its settings.
  void activate() override;
  bool handle(const QString&, const QVariant&) override { return false; }

  bool ready() const { return m_ready; }
  QJsonObject settings() const { return m_settings; }
  int version() const { return m_version; }
  QString error() const { return m_error; }
  QJsonObject config() const { return m_config; }
  QJsonArray themes() const { return m_themes; }

  // Applies `edit` to the MC's document and saves it; `done` says how it
  // went. A stale save re-reads and applies `edit` again, a few times.
  void change(Edit edit, Done done = {});
  // A value in the MC's document by dotted path; undefined when absent.
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
  // The preferences file exists but is not a JSON object. Saving is refused
  // until it reads again, so defaults never replace what the user saved.
  bool deviceUnreadable() const { return m_deviceUnreadable; }
  // Reads the preferences file again.
  Q_INVOKABLE void reloadDevice() { setDevicePath(m_devicePath); }

  // A row's value (its default when unset), whether it is at its default, and
  // changing or resetting it in the store it belongs to. Unknown keys are
  // undefined and ignored.
  Q_INVOKABLE QVariant setting(const QString& key) const;
  Q_INVOKABLE QVariant defaultOf(const QString& key) const;
  Q_INVOKABLE bool isDefault(const QString& key) const;
  // The MC's rows follow the settings scope while a scoped section shows
  // (SettingsScopeController): read from the selected environments, written
  // to each of them, and for a project as its override where the MC allows
  // one. `mixed` says the environments disagree; `disabledReason` why the row
  // cannot be changed at this scope ("" when it can).
  Q_INVOKABLE bool mixed(const QString& key) const;
  Q_INVOKABLE QString disabledReason(const QString& key) const;
  // The selected environments that are out of reach, by label: a change leaves them as they were.
  Q_INVOKABLE QStringList unreachable() const;
  // Whether every selected environment is connected and has the capability
  // (ServerConfig environment.capabilities).
  Q_INVOKABLE bool supports(const QString& capability) const;
  // Whether a row is kept on this device rather than by the MC.
  Q_INVOKABLE bool onDevice(const QString& key) const;
  Q_INVOKABLE void set(const QString& key, const QVariant& value);
  Q_INVOKABLE void reset(const QString& key);
  // Resets rows together: one save of this device's and one of the MC's
  // (restoring defaults).
  Q_INVOKABLE void resetAll(const QStringList& keys);

  // What `config.themes` delivers; tests set it.
  void setThemes(const QJsonArray& themes);

signals:
  void settingsChanged();
  void configChanged();
  // The MC pushed changed keybindings (`config.keybindings`), not the
  // snapshot a subscription starts with.
  void keybindingsPushed();
  void themesChanged();
  void deviceChanged();

private:
  // The scope a row of the MC's goes through: none for this device's rows, or
  // while the scope is only this machine's own document.
  SettingsScopeController* scopeFor(const QString& key) const;
  // The window's settings scope, followed from first use.
  SettingsScopeController* scope() const;
  void read(std::function<void()> then = {});
  void attempt(Edit edit, Done done, int retries);
  void onConfig(const QJsonObject& frame);
  // Follows the config of the environment the client's MC serves.
  void follow();
  void fail(const QString& error);
  // In `window` (the one that made the change), else the one in use.
  void toast(const QString& title, const QString& reason, NativeWindow* window = nullptr);
  QVariantMap documentVariant() const { return m_settings.toVariantMap(); }
  QVariantMap configVariant() const { return m_config.toVariantMap(); }
  QVariantList themesVariant() const { return m_themes.toVariantList(); }
  QVariantMap deviceVariant() const { return m_device.toVariantMap(); }

  McClient* m_client;
  bool m_active = false;
  bool m_ready = false;
  // The config subscription, and the environment it names.
  int m_subscription = 0;
  QString m_followed;
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
  bool m_deviceUnreadable = false;
  mutable bool m_followsScope = false;
};
