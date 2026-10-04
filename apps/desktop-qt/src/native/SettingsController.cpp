#include "SettingsController.h"
#include "SettingsScopeController.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QPointer>
#include <QSaveFile>

#include "NativeShell.h"
#include "McClient.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<SettingsController> registrar(QStringLiteral("settings"), {}, "Settings",
                                                         NativeControllerScope::Shared);

// Saves over a stale copy before giving up: each retry is another editor
// saving in between, which is rare, and never endless.
constexpr int kStaleRetries = 3;

QJsonObject withPath(QJsonObject object, const QStringList& path, const QJsonValue& value) {
  const QString& key = path.first();
  if (path.size() == 1) {
    if (value.isNull() || value.isUndefined()) object.remove(key);
    else object.insert(key, value);
    return object;
  }
  object.insert(key, withPath(object.value(key).toObject(), path.mid(1), value));
  return object;
}

// The rows of the settings pages: the store a key is in and its default.
// Device rows are the web's ClientSettings; MC rows
// its ServerSettings, which the MC's document leaves out while at default.
struct Row {
  const char* key;
  bool device;
  QJsonValue fallback;
};

const QList<Row>& rows() {
  static const QList<Row> list = {
      // General (packages/contracts settings.ts).
      {"sidebarProjectGroupingMode", true, QStringLiteral("repository")},
      {"autoResumeLimitedThreads", false, false},
      {"snoozeLimitedThreads", false, false},
      {"sidebarAutoSettleOnMerge", false, true},
      {"sidebarAutoSettleAfterDays", false, 3},
      {"notificationMode", true, QStringLiteral("off")},
      {"inAppNotificationsEnabled", true, false},
      {"timestampFormat", true, QStringLiteral("locale")},
      {"responseStreamingMode", false, QStringLiteral("paragraph")},
      {"diffIgnoreWhitespace", true, true},
      // The web starts diffs collapsed; the desktop has always opened them, and keeps to that until told otherwise.
      {"diffFilesCollapsed", true, false},
      {"diffLayout", true, QStringLiteral("stacked")},
      {"proactivePanelsEnabled", true, false},
      {"showSkillsInSlashMenu", true, true},
      {"composerRichTextEnabled", true, true},
      {"composerCollapseOnScroll", true, true},
      {"composerVimKeys", true, false},
      {"loadBalancingEnabled", true, false},
      {"loadBalancingWeights", true, QJsonObject()},
      {"sendShortcut", true, QStringLiteral("enter")},
      {"followUpBehavior", true, QStringLiteral("steer")},
      {"enableProviderUpdateChecks", false, true},
      {"continueThreadsAfterServerUpdate", false, false},
      {"newWorktreesStartFromOrigin", false, true},
      {"addProjectBaseDirectory", false, QString()},
      {"confirmThreadUnpin", true, false},
      {"confirmThreadArchive", true, false},
      {"confirmThreadDelete", true, true},
      {"confirmQuit", true, QStringLiteral("hold")},
      {"planModeEnabled", true, false},
      {"contextWindowMeterEnabled", true, false},
      {"legacySidebarEnabled", true, false},
      // Appearance.
      {"appearanceContrast", true, 100},
      {"glassOpacity", true, 80},
      {"environmentIdentificationMode", true, QStringLiteral("artwork")},
      {"diffColorScheme", true, QStringLiteral("red-green")},
      {"persistComposerContextStrip", true, false},
      {"panelAnimationDurationMs", true, 0},
      {"reduceMotion", true, false},
      {"fontSizeInterface", true, 16},
      {"fontSizePrompt", true, 14},
      {"fontSizeCode", true, 13},
      {"fontSizeTerminal", true, 12},
      {"fontFamilySans", true, QString()},
      {"fontFamilyComposer", true, QString()},
      {"fontFamilyCode", true, QString()},
      {"fontFamilyTerminal", true, QString()},
      {"fontSmoothing", true, true},
      {"wordWrap", true, true},
      // SnapShots (SnapShotController).
      {"snapShotEnabled", true, false},
      {"snapShotIncludeAccessibility", true, true},
      {"snapShotShortcut", true, QJsonObject{{QStringLiteral("kind"), QStringLiteral("both-shift-keys")}}},
      {"snapShotPlaySound", true, true},
      {"snapShotSound", true, QStringLiteral("soft-pop")},
      {"snapShotFlash", true, true},
      {"snapShotAnimations", true, true},
  };
  return list;
}

const Row* rowOf(const QString& key) {
  for (const Row& row : rows()) {
    if (key == QLatin1String(row.key)) return &row;
  }
  return nullptr;
}

}  // namespace

SettingsController::SettingsController(ShellBridge*, McClient* client, QObject* parent)
    : QObject(parent), m_client(client) {
  // A reconnect may reach a restarted MC, whose versions start again; the
  // config snapshot that follows the re-sent subscription reads them afresh.
  connect(m_client, &McClient::readyChanged, this, [this](bool ready) {
    if (ready || !m_ready) return;
    m_ready = false;
    ++m_generation;
    emit settingsChanged();
  });
}

void SettingsController::activate() {
  if (m_active) return;
  m_active = true;
  m_client->subscribe(this, {{QStringLiteral("type"), QStringLiteral("config")},
                       {QStringLiteral("environment"), m_client->environment()}},
                      [this](const QJsonObject& frame) { onConfig(frame); });
}

void SettingsController::onConfig(const QJsonObject& frame) {
  const QString type = frame.value(QLatin1String("t")).toString();
  if (type == QLatin1String("config")) {
    const QJsonObject config = frame.value(QLatin1String("config")).toObject();
    if (config != m_config) {
      m_config = config;
      emit configChanged();
    }
    // The snapshot after every (re)subscription: the document may have moved on.
    read();
  } else if (type == QLatin1String("config.settings")) {
    m_config.insert(QStringLiteral("settings"), frame.value(QLatin1String("settings")));
    emit configChanged();
    // The frame has no version to save against; the read brings one.
    read();
  } else if (type == QLatin1String("config.providers")) {
    m_config.insert(QStringLiteral("providers"), frame.value(QLatin1String("providers")));
    emit configChanged();
  } else if (type == QLatin1String("config.keybindings")) {
    m_config.insert(QStringLiteral("keybindingRules"), frame.value(QLatin1String("rules")));
    emit configChanged();
    emit keybindingsPushed();
  } else if (type == QLatin1String("config.themes")) {
    setThemes(frame.value(QLatin1String("themes")).toArray());
  }
}

void SettingsController::setThemes(const QJsonArray& themes) {
  if (themes == m_themes) return;
  m_themes = themes;
  emit themesChanged();
}

void SettingsController::read(std::function<void()> then) {
  const quint64 generation = ++m_generation;
  m_client->call(this, m_client->environment(), QStringLiteral("hal-c2.readSettings"), QJsonObject{},
                 [this, generation, then = std::move(then)](const QJsonValue& result, const std::optional<QString>& error) {
                   // Answers land out of order: a read asked before a save may arrive
                   // after it. What waits on it goes on with what is newer.
                   if (generation != m_generation) {
                     if (then) then();
                     return;
                   }
                   if (error) {
                     fail(*error);
                     if (then) then();
                     return;
                   }
                   const QJsonObject answer = result.toObject();
                   const QJsonObject settings = answer.value(QLatin1String("settings")).toObject();
                   const int version = answer.value(QLatin1String("version")).toInt();
                   const bool changed = !m_ready || settings != m_settings || version != m_version || !m_error.isEmpty();
                   m_settings = settings;
                   m_version = version;
                   m_ready = true;
                   m_error.clear();
                   if (changed) emit settingsChanged();
                   if (then) then();
                 });
}

void SettingsController::change(Edit edit, Done done) {
  attempt(std::move(edit), std::move(done), kStaleRetries);
}

void SettingsController::attempt(Edit edit, Done done, int retries) {
  const auto finish = [done](const std::optional<QString>& error) {
    if (done) done(error);
  };
  if (!m_ready) {
    const QString message = QStringLiteral("The MC's settings are not loaded.");
    fail(message);
    finish(message);
    return;
  }
  const QJsonObject next = edit(m_settings);
  if (next == m_settings) {
    finish(std::nullopt);
    return;
  }
  const quint64 generation = ++m_generation;
  const QJsonObject payload{{QStringLiteral("settings"), next}, {QStringLiteral("version"), m_version}};
  m_client->call(this, m_client->environment(), QStringLiteral("hal-c2.writeSettings"), payload,
                 [this, edit, done, retries, next, generation, finish](const QJsonValue& result,
                                                                       const std::optional<QString>& error) {
                   if (error) {
                     const bool stale = result.toObject().value(QLatin1String("_tag")) == QLatin1String("StaleSettings");
                     if (stale && retries > 0) {
                       // Another client saved first: apply the edit to what it saved.
                       read([this, edit, done, retries] { attempt(edit, done, retries - 1); });
                       return;
                     }
                     const QString message = stale ? QStringLiteral("Settings kept changing elsewhere; not saved.") : *error;
                     fail(message);
                     finish(message);
                     return;
                   }
                   // A read overtaken by this save is dropped; this is newer.
                   if (generation == m_generation) {
                     m_settings = next;
                     m_version = result.toObject().value(QLatin1String("version")).toInt(m_version + 1);
                     m_error.clear();
                     emit settingsChanged();
                   }
                   finish(std::nullopt);
                 });
}

void SettingsController::fail(const QString& error) {
  m_error = error;
  emit settingsChanged();
}

QVariant SettingsController::value(const QString& path) const {
  QJsonValue current = m_settings;
  for (const QString& key : path.split(QLatin1Char('.'))) current = current.toObject().value(key);
  return current.toVariant();
}

void SettingsController::write(const QString& path, const QVariant& value) {
  const QStringList keys = path.split(QLatin1Char('.'), Qt::SkipEmptyParts);
  if (keys.isEmpty()) return;
  const QJsonValue json = QJsonValue::fromVariant(value);
  change([keys, json](const QJsonObject& settings) { return withPath(settings, keys, json); },
         [this, window = QPointer<NativeWindow>(NativeShell::of(this))](const std::optional<QString>& error) {
           if (error) toast(QStringLiteral("Setting not saved"), *error, window);
         });
}

QVariant SettingsController::defaultOf(const QString& key) const {
  const Row* row = rowOf(key);
  return row ? row->fallback.toVariant() : QVariant();
}

namespace {

// The MC's rows a project can override (packages/contracts ProjectSettingsOverrides).
bool projectOverridable(const QString& key) {
  static const QStringList keys{QStringLiteral("newWorktreesStartFromOrigin"), QStringLiteral("sidebarAutoSettleOnMerge"),
                                QStringLiteral("sidebarAutoSettleAfterDays"), QStringLiteral("continueThreadsAfterServerUpdate"),
                                QStringLiteral("responseStreamingMode")};
  return keys.contains(key);
}

// A row's stored value on one environment: the project's override when the
// scope is a project and it has one, else the environment's; undefined when unset.
QJsonValue storedIn(const QJsonObject& settings, const QString& projectId, const QString& key) {
  if (!projectId.isEmpty() && projectOverridable(key)) {
    const QJsonValue override = SettingsScopeController::overrideOf(settings, projectId, key);
    if (!override.isUndefined()) return override;
  }
  return settings.contains(key) ? settings.value(key) : QJsonValue(QJsonValue::Undefined);
}

}  // namespace

SettingsScopeController* SettingsController::scope() const {
  auto* shell = NativeShell::of(this);
  auto* scope = shell ? shell->controller<SettingsScopeController>() : nullptr;
  if (scope && !m_followsScope) {
    m_followsScope = true;
    connect(scope, &SettingsScopeController::changed, this, &SettingsController::settingsChanged);
  }
  return scope;
}

SettingsScopeController* SettingsController::scopeFor(const QString& key) const {
  const Row* row = rowOf(key);
  if (!row || row->device) return nullptr;
  SettingsScopeController* scope = this->scope();
  if (!scope) return nullptr;
  const QStringList targets = scope->targets();
  if (targets.isEmpty()) return nullptr;
  if (!scope->projectScope() && targets == QStringList{m_client->environment()}) return nullptr;
  return scope;
}

bool SettingsController::mixed(const QString& key) const {
  const SettingsScopeController* scope = scopeFor(key);
  if (!scope) return false;
  const Row* row = rowOf(key);
  // An environment that leaves the row unset holds its default.
  return scope
      ->read([key, row](const QJsonObject& settings, const QString& projectId) {
        const QJsonValue stored = storedIn(settings, projectId, key);
        return stored.isUndefined() ? row->fallback : stored;
      })
      .mixed;
}

QString SettingsController::disabledReason(const QString& key) const {
  const Row* row = rowOf(key);
  if (!row || row->device) return {};
  const SettingsScopeController* scope = this->scope();
  if (!scope) return {};
  if (scope->projectScope() && !projectOverridable(key)) return QStringLiteral("Environment-wide setting. Select an environment to change it.");
  return scopeFor(key) ? scope->disabledReason() : QString();
}

QStringList SettingsController::unreachable() const {
  const SettingsScopeController* scope = this->scope();
  QStringList labels;
  if (!scope) return labels;
  for (const QString& environmentId : scope->environments()) {
    if (!scope->online(environmentId)) labels.append(scope->label(environmentId));
  }
  return labels;
}

bool SettingsController::supports(const QString& capability) const {
  const SettingsScopeController* scope = this->scope();
  if (!scope || scope->targets().isEmpty()) return false;
  for (const QString& environmentId : scope->targets()) {
    if (!scope->settings(environmentId)) return false;
  }
  return scope->lacking(capability).isEmpty();
}

QVariant SettingsController::setting(const QString& key) const {
  const Row* row = rowOf(key);
  if (!row) return {};
  if (const SettingsScopeController* scope = scopeFor(key)) {
    const auto reading = scope->read([key](const QJsonObject& settings, const QString& projectId) { return storedIn(settings, projectId, key); });
    if (reading.known > 0) return reading.value.isUndefined() ? row->fallback.toVariant() : reading.value.toVariant();
  }
  const QJsonObject& store = row->device ? m_device : m_settings;
  // An explicit null is a value (inactive settling off), an absent key is not.
  return store.contains(key) ? store.value(key).toVariant() : row->fallback.toVariant();
}

bool SettingsController::isDefault(const QString& key) const {
  const Row* row = rowOf(key);
  if (!row) return true;
  if (const SettingsScopeController* scope = scopeFor(key)) {
    // A project is at its default while it inherits; environments while none holds another value.
    const bool project = scope->projectScope() && projectOverridable(key);
    const auto reading = scope->read([key, row, project](const QJsonObject& settings, const QString& projectId) {
      if (project) return QJsonValue(SettingsScopeController::overrideOf(settings, projectId, key).isUndefined());
      return QJsonValue(!settings.contains(key) || settings.value(key) == row->fallback);
    });
    if (reading.known > 0) return !reading.mixed && reading.value.toBool();
  }
  const QJsonObject& store = row->device ? m_device : m_settings;
  return !store.contains(key) || store.value(key) == row->fallback;
}

bool SettingsController::onDevice(const QString& key) const {
  const Row* row = rowOf(key);
  return row && row->device;
}

void SettingsController::set(const QString& key, const QVariant& value) {
  const Row* row = rowOf(key);
  if (!row) return;
  // The default is stored as absence, so a row at its default offers no reset.
  QJsonValue json = QJsonValue::fromVariant(value);
  const bool absent = json == row->fallback;
  if (row->device) {
    QJsonObject device = m_device;
    if (absent) device.remove(key);
    else device.insert(key, json);
    if (!setDeviceSettings(device)) toast(QStringLiteral("Setting not saved"), m_deviceError);
    return;
  }
  if (!disabledReason(key).isEmpty()) {
    toast(QStringLiteral("Setting not saved"), disabledReason(key));
    return;
  }
  if (SettingsScopeController* scope = scopeFor(key)) {
    const bool project = scope->projectScope();
    scope->write([key, json, project](QJsonObject settings, const QString& projectId) {
      // A project keeps its own value as an override.
      if (project) return SettingsScopeController::withOverride(settings, projectId, key, json);
      // Each environment holds what was chosen, its default too: what it would
      // otherwise fall back to is its own.
      settings.insert(key, json);
      return settings;
    });
    // An environment out of reach keeps what it had.
    if (const QStringList skipped = unreachable(); !skipped.isEmpty()) {
      if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) {
        toasts->show(QStringLiteral("warning"), QStringLiteral("Not updated: %1").arg(skipped.join(QStringLiteral(", "))),
                     QStringLiteral("An offline environment keeps its settings until they are changed while it is connected."));
      }
    }
    return;
  }
  change(
      [key, json, absent](QJsonObject settings) {
        if (absent) settings.remove(key);
        else settings.insert(key, json);
        return settings;
      },
      [this, window = QPointer<NativeWindow>(NativeShell::of(this))](const std::optional<QString>& error) {
        if (error) toast(QStringLiteral("Setting not saved"), *error, window);
      });
}

void SettingsController::reset(const QString& key) {
  // A project goes back to inheriting its environment's value.
  if (SettingsScopeController* scope = scopeFor(key); scope && scope->projectScope() && projectOverridable(key)) {
    scope->write([key](QJsonObject settings, const QString& projectId) {
      return SettingsScopeController::withOverride(settings, projectId, key, QJsonValue(QJsonValue::Undefined));
    });
    return;
  }
  if (const Row* row = rowOf(key)) set(key, row->fallback.toVariant());
}

void SettingsController::resetAll(const QStringList& keys) {
  QJsonObject device = m_device;
  QStringList mc;
  for (const QString& key : keys) {
    const Row* row = rowOf(key);
    if (!row) continue;
    if (row->device) device.remove(key);
    else mc.append(key);
  }
  if (!setDeviceSettings(device)) toast(QStringLiteral("Settings not restored"), m_deviceError);
  if (mc.isEmpty()) return;
  change(
      [mc](QJsonObject settings) {
        for (const QString& key : mc) settings.remove(key);
        return settings;
      },
      [this, window = QPointer<NativeWindow>(NativeShell::of(this))](const std::optional<QString>& error) {
        if (error) toast(QStringLiteral("Settings not restored"), *error, window);
      });
}

void SettingsController::toast(const QString& title, const QString& reason, NativeWindow* window) {
  // The window that asked, if it is still open, else the one in use. Toasts
  // are built after this controller: looked up when needed.
  if (!window) window = NativeShell::of(this);
  if (!window) return;
  if (auto* toasts = window->controller<ToastController>()) toasts->error(title, reason);
}

void SettingsController::setDevicePath(const QString& path) {
  m_devicePath = path;
  QJsonObject device;
  QString error;
  QFile file(path);
  if (file.exists()) {
    QJsonParseError parse;
    const QJsonDocument doc =
        file.open(QIODevice::ReadOnly) ? QJsonDocument::fromJson(file.readAll(), &parse) : QJsonDocument();
    if (doc.isObject()) device = doc.object();
    else error = QStringLiteral("Cannot read %1").arg(path);
  }
  m_device = device;
  m_deviceError = error;
  m_deviceUnreadable = !error.isEmpty();
  emit deviceChanged();
}

bool SettingsController::setDeviceSettings(const QJsonObject& device) {
  if (device == m_device) return true;
  QString error;
  if (m_deviceUnreadable) {
    error = QStringLiteral("Cannot read %1").arg(m_devicePath);
  } else if (m_devicePath.isEmpty()) {
    error = QStringLiteral("This device has nowhere to keep its preferences.");
  } else {
    QDir().mkpath(QFileInfo(m_devicePath).absolutePath());
    QSaveFile file(m_devicePath);
    if (!file.open(QIODevice::WriteOnly) || file.write(QJsonDocument(device).toJson()) < 0 || !file.commit()) {
      error = QStringLiteral("Cannot save %1").arg(m_devicePath);
    }
  }
  if (!error.isEmpty()) {
    m_deviceError = error;
    emit deviceChanged();
    return false;
  }
  m_device = device;
  m_deviceError.clear();
  emit deviceChanged();
  return true;
}

bool SettingsController::writeDevice(const QString& key, const QVariant& value) {
  if (setDeviceSettings(withPath(m_device, {key}, QJsonValue::fromVariant(value)))) return true;
  toast(QStringLiteral("Setting not saved"), m_deviceError);
  return false;
}
