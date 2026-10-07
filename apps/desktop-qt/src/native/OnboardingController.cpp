#include "OnboardingController.h"

#include <QRegularExpression>
#include <QUuid>

#include <algorithm>

#include "DraftController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "McClient.h"
#include "ProviderSettingsController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarModel.h"
#include "TerminalController.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<OnboardingController> registrar(QStringLiteral("onboarding"),
                                                                {QStringLiteral("onboarding")},
                                                                "Onboarding");

const QString kCompletedAt = QStringLiteral("onboardingCompletedAt");
// Terminals are keyed by a free-form thread id; the MC checks only the cwd.
const QString kSetupThread = QStringLiteral("onboarding-agent-setup");
const QStringList kDrivers{QStringLiteral("claudeAgent"), QStringLiteral("codex")};
constexpr int kDecisionTimeoutMs = 4000;
constexpr qint64 kRecentWindowMs = 30LL * 24 * 60 * 60 * 1000;
// One or two threads in a folder is usually a one-off question, not a project.
constexpr int kDefaultSelectionMinThreads = 3;

QVariant null() {
  return QVariant::fromValue(nullptr);
}

// getOnboardingProviderState
QString providerState(const QJsonObject& provider) {
  if (provider.isEmpty()) return QStringLiteral("checking");
  const QString status = provider.value(QLatin1String("status")).toString();
  if (!provider.value(QLatin1String("enabled")).toBool() || status == QLatin1String("disabled")) return QStringLiteral("disabled");
  if (!provider.value(QLatin1String("installed")).toBool()) return QStringLiteral("install");
  if (provider.value(QLatin1String("auth")).toObject().value(QLatin1String("status")) == QLatin1String("unauthenticated")) {
    return QStringLiteral("signIn");
  }
  if (status == QLatin1String("ready")) return QStringLiteral("ready");
  return QStringLiteral("attention");
}

int priority(const QString& state) {
  static const QStringList order{QStringLiteral("checking"), QStringLiteral("disabled"), QStringLiteral("install"),
                                 QStringLiteral("attention"), QStringLiteral("signIn"), QStringLiteral("ready")};
  return int(order.indexOf(state));
}

// selectOnboardingProvidersByDriver: the most usable instance of the driver.
QJsonObject providerFor(const QJsonArray& providers, const QString& driver) {
  QJsonObject best;
  for (const QJsonValue& value : providers) {
    const QJsonObject provider = value.toObject();
    if (provider.value(QLatin1String("driver")) != driver) continue;
    if (best.isEmpty() || priority(providerState(provider)) > priority(providerState(best))) best = provider;
  }
  return best;
}

// The web's quoteProviderBinary.
QString quoteBinary(const QString& path, const QString& fallback, const QString& os) {
  static const QRegularExpression safe(QStringLiteral("^[A-Za-z0-9_./:\\\\-]+$"));
  if (safe.match(path).hasMatch() && (os == QLatin1String("windows") || !path.contains(QLatin1Char('\\')))) return path;
  if (os == QLatin1String("windows")) return QStringLiteral("& '%1'").arg(QString(path).replace(QLatin1Char('\''), QStringLiteral("''")));
  if (os == QLatin1String("darwin") || os == QLatin1String("linux")) {
    const auto escape = [](QString text) { return text.replace(QLatin1Char('\''), QStringLiteral("'\"'\"'")); };
    if (path.startsWith(QLatin1String("~/")) || path.startsWith(QLatin1String("~\\"))) {
      return QStringLiteral("~/'%1'").arg(escape(path.mid(2)));
    }
    return QStringLiteral("'%1'").arg(escape(path));
  }
  return fallback;
}

// resolveOnboardingProviderInstallCommand: the vendors' standalone installers,
// which keep Settings' updater working.
QString installCommand(const QString& driver, const QString& os) {
  const bool windows = os == QLatin1String("windows");
  if (driver == QLatin1String("claudeAgent")) {
    return windows ? QStringLiteral("irm https://claude.ai/install.ps1 | iex")
                   : QStringLiteral("curl -fsSL https://claude.ai/install.sh | bash");
  }
  return windows ? QStringLiteral("irm https://chatgpt.com/codex/install.ps1 | iex")
                 : QStringLiteral("curl -fsSL https://chatgpt.com/codex/install.sh | sh");
}

// resolveOnboardingProviderLoginCommand: the instance's own binary.
QString loginCommand(const QJsonObject& provider, const QJsonObject& settings, const QString& os) {
  const QString driver = provider.value(QLatin1String("driver")).toString();
  const QString id = provider.value(QLatin1String("instanceId")).toString();
  const QJsonObject instances = settings.value(QLatin1String("providerInstances")).toObject();
  const QJsonObject config = instances.contains(id)
                                 ? instances.value(id).toObject().value(QLatin1String("config")).toObject()
                                 : settings.value(QLatin1String("providers")).toObject().value(driver).toObject();
  const bool claude = driver == QLatin1String("claudeAgent");
  const QString fallback = claude ? QStringLiteral("claude") : QStringLiteral("codex");
  QString binary = config.value(QLatin1String("binaryPath")).toString().trimmed();
  if (binary.isEmpty()) binary = fallback;
  return quoteBinary(binary, fallback, os) + (claude ? QStringLiteral(" auth login") : QStringLiteral(" login"));
}

QString keyOf(const QString& environmentId, const QString& path) {
  return environmentId + QLatin1Char('\n') + path;
}

QString plural(int count, const QString& one, const QString& many) {
  return QStringLiteral("%1 %2").arg(count).arg(count == 1 ? one : many);
}

}  // namespace

OnboardingController::OnboardingController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {
  m_timeout.setSingleShot(true);
  m_timeout.setInterval(kDecisionTimeoutMs);
  connect(&m_timeout, &QTimer::timeout, this, [this] {
    if (m_gate != QLatin1String("pending")) return;
    m_stalled = true;
    publish();
  });
  m_timeout.start();
  publish();
}

OnboardingController::~OnboardingController() {
  // Nothing is left running behind the wizard.
  if (m_setup) closeSetup();
}

QObject* OnboardingController::terminal() const {
  return m_session.data();
}

void OnboardingController::setDecisionTimeout(int ms) {
  m_timeout.setInterval(ms);
  if (m_gate == QLatin1String("pending") && !m_stalled) m_timeout.start();
}

SettingsController* OnboardingController::settings() const {
  const NativeWindow* window = NativeShell::of(this);
  return window ? window->controller<SettingsController>() : nullptr;
}

void OnboardingController::preview() {
  if (m_active || m_previewing) return;
  m_previewing = true;
  // The device's own record may be read after the kept rows are shown.
  if (auto* device = settings()) {
    connect(device, &SettingsController::deviceChanged, this, [this] {
      if (m_active) return;
      decide();
      publish();
    });
  }
  decide();
  publish();
}

void OnboardingController::activate() {
  if (m_active) return;
  m_active = true;
  if (auto* device = settings()) {
    connect(device, &SettingsController::deviceChanged, this, [this] {
      decide();
      publish();
    });
  }
  connect(m_store, &ShellStore::changed, this, [this] {
    updateComputers();
    if (m_landing && m_store->project(m_landing->first + QLatin1Char(':') + m_landing->second)) {
      const auto project = *m_landing;
      m_landing.reset();
      finish(project);
    }
    publish();
  });
  decide();
  updateComputers();
  publish();
}

// FirstRunGate: done when this device says so, or when the workspace already
// has something in it; the wizard otherwise. Once shown, the wizard stays
// until it finishes.
void OnboardingController::decide() {
  if (m_gate != QLatin1String("pending")) return;
  SettingsController* device = settings();
  if (!device || device->deviceUnreadable()) return;
  if (!device->deviceSettings().value(kCompletedAt).toString().isEmpty()) {
    settle(QStringLiteral("app"));
    return;
  }
  if (!m_active) return;
  if (!m_store->projects().isEmpty() || !m_store->threads().isEmpty()) {
    QJsonObject saved = device->deviceSettings();
    saved.insert(kCompletedAt, m_now().toUTC().toString(Qt::ISODateWithMs));
    device->setDeviceSettings(saved);
    settle(QStringLiteral("app"));
    return;
  }
  settle(QStringLiteral("wizard"));
}

void OnboardingController::settle(const QString& gate) {
  m_gate = gate;
  m_stalled = false;
  m_timeout.stop();
}

bool OnboardingController::handle(const QString& action, const QVariant& payload) {
  if (!action.startsWith(QLatin1String("onboarding."))) return false;
  const QVariantMap input = payload.toMap();
  if (action == QLatin1String("onboarding.reload")) {
    m_stalled = false;
    m_client->reconnect();
    if (m_gate == QLatin1String("pending")) m_timeout.start();
  } else if (action == QLatin1String("onboarding.retry")) {
    if (auto* device = settings()) device->reloadDevice();
    decide();
  } else if (!m_active || m_gate != QLatin1String("wizard")) {
    return true;
  } else if (action == QLatin1String("onboarding.select")) {
    const QString id = input.value(QStringLiteral("environmentId")).toString();
    if (input.value(QStringLiteral("selected")).toBool()) m_selected.insert(id);
    else m_selected.remove(id);
  } else if (action == QLatin1String("onboarding.pair")) {
    pair(input.value(QStringLiteral("pairingUrl")).toString().trimmed());
  } else if (action == QLatin1String("onboarding.continue")) {
    if (m_step == QLatin1String("connection")) {
      startSetup();
    } else if (m_step == QLatin1String("agents")) {
      setStage(2);
    }
  } else if (action == QLatin1String("onboarding.stage")) {
    setStage(input.value(QStringLiteral("index")).toInt());
  } else if (action == QLatin1String("onboarding.agent")) {
    openSetup(input.value(QStringLiteral("environmentId")).toString(), input.value(QStringLiteral("driver")).toString());
  } else if (action == QLatin1String("onboarding.terminal.retry")) {
    if (m_setup) startTerminal();
  } else if (action == QLatin1String("onboarding.terminal.close")) {
    closeSetup();
  } else if (action == QLatin1String("onboarding.scan.retry")) {
    scan(input.value(QStringLiteral("environmentId")).toString());
  } else if (action == QLatin1String("onboarding.project")) {
    if (m_importing) return true;
    QSet<QString> next = selectedKeys();
    for (const QVariant& key : input.value(QStringLiteral("keys")).toList()) {
      if (input.value(QStringLiteral("selected")).toBool()) next.insert(key.toString());
      else next.remove(key.toString());
    }
    m_selection = next;
  } else if (action == QLatin1String("onboarding.selectAll")) {
    if (m_importing) return true;
    QSet<QString> all;
    for (const QJsonObject& candidate : candidates()) all.insert(candidate.value(QLatin1String("key")).toString());
    m_selection = all;
  } else if (action == QLatin1String("onboarding.selectNone")) {
    if (!m_importing) m_selection = QSet<QString>();
  } else if (action == QLatin1String("onboarding.import")) {
    runImport();
  } else if (action == QLatin1String("onboarding.skip")) {
    if (m_importing) return true;
    if (m_importError.isEmpty()) finish();
    else finishAfterImport();
  } else {
    return false;
  }
  publish();
  return true;
}

// ---- Connect ----------------------------------------------------------------

// The computers of the cluster, the MC's own first; each is selected the
// first time it is offered.
void OnboardingController::updateComputers() {
  QStringList computers = m_store->environments();
  const QString own = m_client->environment();
  computers.removeAll(own);
  std::sort(computers.begin(), computers.end(), [this](const QString& left, const QString& right) {
    return label(left).localeAwareCompare(label(right)) < 0;
  });
  if (!own.isEmpty()) computers.prepend(own);
  m_computers = computers;
  for (const QString& id : computers) {
    if (m_offered.contains(id)) continue;
    m_offered.insert(id);
    m_selected.insert(id);
  }
}

QString OnboardingController::label(const QString& environmentId) const {
  const QString label = m_store->environment(environmentId).value(QLatin1String("label")).toString();
  return label.isEmpty() ? QStringLiteral("Computer") : label;
}

// Joins the cluster of the computer the link is from (`cluster.join`); its
// machines are offered as the shell lists them.
void OnboardingController::pair(const QString& url) {
  if (m_pairing || url.isEmpty()) return;
  m_pairing = true;
  m_pairingError.clear();
  m_pairingDetail.clear();
  m_client->call(this, m_client->environment(), QStringLiteral("cluster.join"), QJsonObject{{QStringLiteral("link"), url}},
                 [this](const QJsonValue&, const std::optional<QString>& error) {
                   m_pairing = false;
                   if (error) {
                     m_pairingError = QStringLiteral("Pairing failed.");
                     m_pairingDetail = *error;
                   }
                   publish();
                 });
}

void OnboardingController::startSetup() {
  QStringList ids;
  for (const QString& id : m_computers) {
    if (m_selected.contains(id)) ids.append(id);
  }
  if (ids.isEmpty() || m_pairing) return;
  for (const QString& id : ids) {
    if (!m_store->environmentOnline(id)) return;
  }
  m_setupIds = ids;
  m_step = QStringLiteral("agents");
  watchConfigs();
  for (const QString& id : ids) {
    // Re-probe on entry so freshly installed CLIs show up.
    m_client->call(this, id, QStringLiteral("server.refreshProviders"), QJsonObject(),
                   [this, id](const QJsonValue& result, const std::optional<QString>& error) {
                     const QJsonValue providers = result.toObject().value(QLatin1String("providers"));
                     if (error || !providers.isArray() || !m_configs.contains(id)) return;
                     m_configs[id].config.insert(QStringLiteral("providers"), providers);
                     publish();
                   });
  }
}

// The progress bar goes back only, and not while an import runs.
void OnboardingController::setStage(int index) {
  const int current = m_step == QLatin1String("agents") ? 1 : m_step == QLatin1String("import") ? 2 : 0;
  if (m_importing) return;
  if (index == 2 && current == 1) {
    closeSetup();
    m_step = QStringLiteral("import");
    for (const QString& id : m_setupIds) {
      if (!m_scans.contains(id)) scan(id);
    }
    return;
  }
  if (index >= current) return;
  closeSetup();
  if (index == 0) {
    m_step = QStringLiteral("connection");
  } else {
    m_step = QStringLiteral("agents");
  }
}

// ---- Agents -----------------------------------------------------------------

void OnboardingController::watchConfigs() {
  for (auto it = m_configs.begin(); it != m_configs.end();) {
    if (m_setupIds.contains(it.key())) {
      ++it;
      continue;
    }
    m_client->unsubscribe(it->subscription);
    it = m_configs.erase(it);
  }
  for (const QString& id : m_setupIds) {
    if (m_configs.contains(id)) continue;
    m_configs[id].subscription = m_client->subscribe(
        this, {{QStringLiteral("type"), QStringLiteral("config")}, {QStringLiteral("environment"), id}},
        [this, id](const QJsonObject& frame) {
          if (!m_configs.contains(id)) return;
          QJsonObject& config = m_configs[id].config;
          const QString type = frame.value(QLatin1String("t")).toString();
          if (type == QLatin1String("config")) {
            config = frame.value(QLatin1String("config")).toObject();
          } else if (type == QLatin1String("config.providers")) {
            config.insert(QStringLiteral("providers"), frame.value(QLatin1String("providers")));
          } else if (type == QLatin1String("config.settings")) {
            config.insert(QStringLiteral("settings"), frame.value(QLatin1String("settings")));
          } else {
            return;
          }
          publish();
        });
  }
}

QVariantMap OnboardingController::agents() const {
  QVariantList computers;
  for (const QString& id : m_setupIds) {
    const QJsonObject config = m_configs.value(id).config;
    const QJsonArray providers = config.value(QLatin1String("providers")).toArray();
    QVariantList cards;
    for (const QString& driver : kDrivers) {
      // Checking until the MC has said which providers it has.
      const QJsonObject provider = config.contains(QLatin1String("providers")) ? providerFor(providers, driver) : QJsonObject();
      const auto summary = provider.isEmpty()
                               ? QPair<QString, QString>(QStringLiteral("Checking provider status"),
                                                         QStringLiteral("Waiting for the server to report installation and authentication details."))
                               : providerSummary(provider);
      cards.append(QVariantMap{
          {QStringLiteral("driver"), driver},
          {QStringLiteral("name"), driver == QLatin1String("claudeAgent") ? QStringLiteral("Claude Code") : QStringLiteral("Codex")},
          {QStringLiteral("state"), providerState(provider)},
          {QStringLiteral("headline"), summary.first},
          {QStringLiteral("detail"), summary.second},
          {QStringLiteral("terminalOpen"), m_setup && m_setup->environmentId == id && m_setup->driver == driver},
          {QStringLiteral("terminalAvailable"), !config.isEmpty()},
      });
    }
    computers.append(QVariantMap{{QStringLiteral("environmentId"), id}, {QStringLiteral("label"), label(id)}, {QStringLiteral("cards"), cards}});
  }
  return {{QStringLiteral("computers"), computers}};
}

// Install or sign in: a terminal on the computer, run as the provider
// instance, with the command typed but not run.
void OnboardingController::openSetup(const QString& environmentId, const QString& driver) {
  if (!m_setupIds.contains(environmentId) || !kDrivers.contains(driver)) return;
  const QJsonObject config = m_configs.value(environmentId).config;
  if (config.isEmpty()) return;
  const QJsonObject provider = providerFor(config.value(QLatin1String("providers")).toArray(), driver);
  if (provider.isEmpty()) return;
  // One setup terminal at a time: another card's replaces it.
  closeSetup();
  const QString os = config.value(QLatin1String("environment")).toObject().value(QLatin1String("platform")).toObject()
                         .value(QLatin1String("os")).toString();
  Setup setup;
  setup.environmentId = environmentId;
  setup.driver = driver;
  setup.instanceId = provider.value(QLatin1String("instanceId")).toString();
  setup.cwd = config.value(QLatin1String("cwd")).toString();
  setup.command = provider.value(QLatin1String("installed")).toBool()
                      ? loginCommand(provider, config.value(QLatin1String("settings")).toObject(), os)
                      : installCommand(driver, os);
  setup.terminalId = QStringLiteral("onboarding-%1-%2").arg(driver, QUuid::createUuid().toString(QUuid::WithoutBraces));
  m_setup = setup;
  startTerminal();
}

void OnboardingController::startTerminal() {
  if (m_session) m_session->deleteLater();
  m_setup->status = QStringLiteral("preparing");
  TerminalPlace place;
  place.environmentId = m_setup->environmentId;
  place.threadId = kSetupThread;
  place.cwd = m_setup->cwd;
  place.providerInstanceId = m_setup->instanceId;
  auto* session = new TerminalSession(m_client, place, m_setup->terminalId, QSize(), this);
  m_session = session;
  connect(session, &TerminalSession::attached, this, [this, session] {
    if (m_session != session || !m_setup) return;
    session->write(m_setup->command);
    m_setup->status = QStringLiteral("ready");
    emit terminalChanged();
    publish();
  });
  connect(session, &TerminalSession::failed, this, [this, session] {
    if (m_session != session || !m_setup) return;
    m_setup->status = QStringLiteral("openFailed");
    m_session = nullptr;
    session->deleteLater();
    emit terminalChanged();
    publish();
  });
  connect(session, &TerminalSession::closed, this, [this, session] {
    if (m_session != session) return;
    closeSetup();
    publish();
  });
  emit terminalChanged();
}

// Every way out ends the terminal, and the cards look again.
void OnboardingController::closeSetup() {
  if (!m_setup) return;
  const Setup setup = *m_setup;
  m_setup.reset();
  if (m_session) m_session->deleteLater();
  m_session = nullptr;
  emit terminalChanged();
  m_client->call(this, setup.environmentId, QStringLiteral("terminal.close"),
                 QJsonObject{{QStringLiteral("threadId"), kSetupThread},
                             {QStringLiteral("terminalId"), setup.terminalId},
                             {QStringLiteral("deleteHistory"), true}},
                 [](const QJsonValue&, const std::optional<QString>&) {});
  m_client->call(this, setup.environmentId, QStringLiteral("server.refreshProviders"), QJsonObject(),
                 [this, id = setup.environmentId](const QJsonValue& result, const std::optional<QString>& error) {
                   const QJsonValue providers = result.toObject().value(QLatin1String("providers"));
                   if (error || !providers.isArray() || !m_configs.contains(id)) return;
                   m_configs[id].config.insert(QStringLiteral("providers"), providers);
                   publish();
                 });
}

// ---- Import -----------------------------------------------------------------

void OnboardingController::scan(const QString& environmentId) {
  if (!m_setupIds.contains(environmentId)) return;
  Scan& entry = m_scans[environmentId];
  entry.pending = true;
  entry.error.clear();
  m_client->call(this, environmentId, QStringLiteral("agentSessions.scan"), QJsonObject(),
                 [this, environmentId](const QJsonValue& result, const std::optional<QString>& error) {
                   Scan& entry = m_scans[environmentId];
                   entry.pending = false;
                   if (error) {
                     entry.error = *error;
                   } else {
                     entry.data = result.toObject();
                   }
                   publish();
                 });
}

QList<QJsonObject> OnboardingController::candidates() const {
  QList<QJsonObject> result;
  for (const QString& id : m_setupIds) {
    for (const QJsonValue& value : m_scans.value(id).data.value(QLatin1String("candidates")).toArray()) {
      QJsonObject candidate = value.toObject();
      candidate.insert(QStringLiteral("environmentId"), id);
      candidate.insert(QStringLiteral("key"), keyOf(id, candidate.value(QLatin1String("path")).toString()));
      result.append(candidate);
    }
  }
  return result;
}

// partitionOnboardingProjects: by default, git repositories active in the
// last 30 days with enough threads to look like real work.
QSet<QString> OnboardingController::selectedKeys() const {
  if (m_selection) return *m_selection;
  QSet<QString> recent;
  const QDateTime now = m_now();
  for (const QJsonObject& candidate : candidates()) {
    if (candidate.value(QLatin1String("git")).isNull()) continue;
    if (candidate.value(QLatin1String("threadCount")).toInt() < kDefaultSelectionMinThreads) continue;
    const QDateTime last = QDateTime::fromString(candidate.value(QLatin1String("lastActiveAt")).toString(), Qt::ISODateWithMs);
    if (!last.isValid() || last > now || last.msecsTo(now) > kRecentWindowMs) continue;
    recent.insert(candidate.value(QLatin1String("key")).toString());
  }
  return recent;
}

void OnboardingController::runImport() {
  if (m_importing) return;
  const QSet<QString> keys = selectedKeys();
  QList<QJsonObject> selection;
  for (const QJsonObject& candidate : candidates()) {
    if (keys.contains(candidate.value(QLatin1String("key")).toString())) selection.append(candidate);
  }
  if (selection.isEmpty()) {
    finish();
    return;
  }
  m_importing = true;
  m_importError.clear();
  m_lastSelection.clear();
  m_importedProjects = 0;
  for (const QJsonObject& candidate : selection) {
    const QString key = candidate.value(QLatin1String("key")).toString();
    m_lastSelection.append(key);
    // Retries skip what already landed.
    if (m_imported.contains(key)) ++m_importedProjects;
  }
  m_importedThreads = 0;
  m_skippedThreads = 0;
  m_selectionSize = int(selection.size());
  m_rescan.clear();
  m_queue = selection;
  importNext();
}

// One candidate at a time: its project (the MC's match, the shell's, or a
// new one), then its history.
void OnboardingController::importNext() {
  while (!m_queue.isEmpty() && m_imported.contains(m_queue.first().value(QLatin1String("key")).toString())) {
    m_queue.removeFirst();
  }
  if (m_queue.isEmpty()) {
    afterImport();
    return;
  }
  const QJsonObject candidate = m_queue.takeFirst();
  const QString env = candidate.value(QLatin1String("environmentId")).toString();
  const QString key = candidate.value(QLatin1String("key")).toString();
  const QString path = candidate.value(QLatin1String("path")).toString();
  auto importThreads = [this, env, key, path](const QString& projectId) {
    m_client->call(this, env, QStringLiteral("agentSessions.import"),
                   QJsonObject{{QStringLiteral("projectId"), projectId}, {QStringLiteral("expectedWorkspaceRoot"), path}},
                   [this, env, key, projectId](const QJsonValue& result, const std::optional<QString>& error) {
                     if (error) {
                       m_attempts.remove(key);
                       m_rescan.insert(env);
                     } else {
                       const int imported = result.toObject().value(QLatin1String("importedCount")).toInt();
                       const int skipped = result.toObject().value(QLatin1String("skippedCount")).toInt();
                       m_importedThreads += imported;
                       m_skippedThreads += skipped;
                       if (imported > 0) m_withHistory.insert(key, {env, projectId});
                       if (skipped == 0) {
                         ++m_importedProjects;
                         m_imported.insert(key, {env, projectId});
                       }
                     }
                     importNext();
                   });
  };
  QString projectId = candidate.value(QLatin1String("projectId")).toString();
  if (projectId.isEmpty()) {
    const QString root = sidebar::normalizePath(path);
    for (const sidebar::Project& project : m_store->projects()) {
      if (project.environmentId == env && sidebar::normalizePath(project.workspaceRoot) == root) {
        projectId = project.id;
        break;
      }
    }
  }
  if (!projectId.isEmpty()) {
    importThreads(projectId);
    return;
  }
  if (!m_attempts.contains(key)) m_attempts.insert(key, QUuid::createUuid().toString(QUuid::WithoutBraces));
  const QString created = m_attempts.value(key);
  m_client->call(this, env, QStringLiteral("projects.mutate"),
                 QJsonObject{{QStringLiteral("type"), QStringLiteral("project.create")},
                             {QStringLiteral("projectId"), created},
                             {QStringLiteral("title"), candidate.value(QLatin1String("title")).toString()},
                             {QStringLiteral("workspaceRoot"), path},
                             {QStringLiteral("createWorkspaceRootIfMissing"), false}},
                 [this, env, key, created, importThreads](const QJsonValue&, const std::optional<QString>& error) {
                   if (error) {
                     m_attempts.remove(key);
                     m_rescan.insert(env);
                     importNext();
                     return;
                   }
                   importThreads(created);
                 });
}

void OnboardingController::afterImport() {
  for (const QString& env : std::as_const(m_rescan)) scan(env);
  m_importing = false;
  if (m_importedProjects < m_selectionSize) {
    const int imported = m_importedThreads;
    const int skipped = m_skippedThreads;
    if (imported > 0 && skipped > 0) {
      m_importError = QStringLiteral("Imported %1. %2 could not be imported.")
                          .arg(plural(imported, QStringLiteral("thread"), QStringLiteral("threads")),
                               plural(skipped, QStringLiteral("thread"), QStringLiteral("threads")));
    } else if (skipped > 0) {
      m_importError = QStringLiteral("%1 not be imported.").arg(plural(skipped, QStringLiteral("thread could"), QStringLiteral("threads could")));
    } else if (imported > 0) {
      m_importError = QStringLiteral("Imported %1. Some thread history could not be imported.")
                          .arg(plural(imported, QStringLiteral("thread"), QStringLiteral("threads")));
    } else {
      m_importError = QStringLiteral("Could not import thread history.");
    }
    publish();
    return;
  }
  finishAfterImport();
  publish();
}

// resolveOnboardingLandingProject: a selected project with imported history
// first, else one that imported cleanly; opened once the shell lists it.
void OnboardingController::finishAfterImport() {
  std::optional<QPair<QString, QString>> project;
  for (const QString& key : std::as_const(m_lastSelection)) {
    if (m_withHistory.contains(key)) {
      project = m_withHistory.value(key);
      break;
    }
  }
  if (!project) {
    for (const QString& key : std::as_const(m_lastSelection)) {
      if (m_imported.contains(key)) {
        project = m_imported.value(key);
        break;
      }
    }
  }
  if (!project) {
    finish();
    return;
  }
  if (m_store->project(project->first + QLatin1Char(':') + project->second)) {
    finish(project);
    return;
  }
  m_importing = true;
  m_landing = project;
}

QVariantMap OnboardingController::importState() const {
  const QSet<QString> selected = selectedKeys();
  const QList<QJsonObject> all = candidates();
  const QDateTime now = m_now();
  // formatRelativeTime, with "just now" as "now" to fit the column.
  const auto age = [&now](const QString& at) -> QString {
    const QDateTime time = QDateTime::fromString(at, Qt::ISODateWithMs);
    if (!time.isValid()) return {};
    const qint64 seconds = time.secsTo(now);
    if (seconds < 60) return QStringLiteral("now");
    if (seconds < 3600) return QStringLiteral("%1m").arg(seconds / 60);
    if (seconds < 86400) return QStringLiteral("%1h").arg(seconds / 3600);
    return QStringLiteral("%1d").arg(seconds / 86400);
  };
  const auto sourced = [](const QJsonArray& sources, const char* source) {
    return sources.contains(QJsonValue(QLatin1String(source)));
  };
  const auto row = [&](const QJsonObject& candidate) {
    const QJsonArray sources = candidate.value(QLatin1String("sources")).toArray();
    return QVariantMap{
        {QStringLiteral("key"), candidate.value(QLatin1String("key")).toString()},
        {QStringLiteral("path"), candidate.value(QLatin1String("path")).toString()},
        {QStringLiteral("checked"), selected.contains(candidate.value(QLatin1String("key")).toString())},
        {QStringLiteral("threadCount"), candidate.value(QLatin1String("threadCount")).toInt()},
        {QStringLiteral("age"), age(candidate.value(QLatin1String("lastActiveAt")).toString())},
        {QStringLiteral("claude"), sourced(sources, "claudeAgent")},
        {QStringLiteral("codex"), sourced(sources, "codex")},
    };
  };
  QVariantList scans;
  // Nothing found anywhere yet, and something still looking.
  bool anyData = false;
  bool anyPending = false;
  for (const QString& id : m_setupIds) {
    const Scan entry = m_scans.value(id);
    anyData = anyData || !entry.data.isEmpty();
    anyPending = anyPending || entry.pending;
    // groupOnboardingProjects: clones of one remote share a group; folders
    // that are not repositories are the "Other folders".
    struct Group {
      QString key, label, repository, lastActiveAt;
      int threadCount = 0;
      QList<QJsonObject> members;
    };
    QList<Group> groups;
    QList<QJsonObject> other;
    for (const QJsonObject& candidate : all) {
      if (candidate.value(QLatin1String("environmentId")) != id) continue;
      const QJsonValue git = candidate.value(QLatin1String("git"));
      if (git.isNull()) {
        other.append(candidate);
        continue;
      }
      const QString remote = git.toObject().value(QLatin1String("remoteKey")).toString();
      const QString key = remote.isEmpty() ? QStringLiteral("path:") + candidate.value(QLatin1String("path")).toString()
                                           : QStringLiteral("remote:") + remote;
      auto found = std::find_if(groups.begin(), groups.end(), [&key](const Group& group) { return group.key == key; });
      const QString last = candidate.value(QLatin1String("lastActiveAt")).toString();
      if (found == groups.end()) {
        const QString repository = git.toObject().value(QLatin1String("repository")).toString();
        groups.append({key, repository.isEmpty() ? candidate.value(QLatin1String("title")).toString() : repository, repository,
                       last, candidate.value(QLatin1String("threadCount")).toInt(), {candidate}});
      } else {
        found->members.append(candidate);
        found->threadCount += candidate.value(QLatin1String("threadCount")).toInt();
        if (last > found->lastActiveAt) found->lastActiveAt = last;
      }
    }
    std::stable_sort(groups.begin(), groups.end(), [](const Group& left, const Group& right) {
      if (left.lastActiveAt == right.lastActiveAt) return left.label.localeAwareCompare(right.label) < 0;
      if (left.lastActiveAt.isEmpty()) return false;
      if (right.lastActiveAt.isEmpty()) return true;
      return left.lastActiveAt > right.lastActiveAt;
    });
    QVariantList repositories;
    for (const Group& group : groups) {
      QVariantList members;
      int checked = 0;
      bool claude = false;
      bool codex = false;
      for (const QJsonObject& candidate : group.members) {
        const QVariantMap member = row(candidate);
        if (member.value(QStringLiteral("checked")).toBool()) ++checked;
        claude = claude || member.value(QStringLiteral("claude")).toBool();
        codex = codex || member.value(QStringLiteral("codex")).toBool();
        members.append(member);
      }
      const bool single = group.members.size() == 1;
      repositories.append(QVariantMap{
          {QStringLiteral("key"), group.key},
          {QStringLiteral("label"), group.label},
          {QStringLiteral("secondary"), single && !group.repository.isEmpty() ? group.members.first().value(QLatin1String("path")).toString() : QString()},
          {QStringLiteral("single"), single},
          {QStringLiteral("checked"), checked == group.members.size()},
          {QStringLiteral("partial"), checked > 0 && checked < group.members.size()},
          {QStringLiteral("threadCount"), group.threadCount},
          {QStringLiteral("age"), age(group.lastActiveAt)},
          {QStringLiteral("claude"), claude},
          {QStringLiteral("codex"), codex},
          {QStringLiteral("candidates"), members},
      });
    }
    QVariantList others;
    int otherChecked = 0;
    for (const QJsonObject& candidate : other) {
      const QVariantMap member = row(candidate);
      if (member.value(QStringLiteral("checked")).toBool()) ++otherChecked;
      others.append(member);
    }
    const bool empty = std::none_of(all.cbegin(), all.cend(), [&id](const QJsonObject& candidate) {
      return candidate.value(QLatin1String("environmentId")) == id;
    });
    scans.append(QVariantMap{
        {QStringLiteral("environmentId"), id},
        {QStringLiteral("label"), label(id)},
        {QStringLiteral("pending"), entry.pending && entry.data.isEmpty()},
        {QStringLiteral("error"), entry.error},
        {QStringLiteral("truncated"), entry.data.value(QLatin1String("truncated")).toBool()},
        {QStringLiteral("empty"), empty && !entry.pending && entry.error.isEmpty()},
        {QStringLiteral("repositories"), repositories},
        {QStringLiteral("other"), QVariantMap{{QStringLiteral("count"), others.size()},
                                              {QStringLiteral("checked"), !others.isEmpty() && otherChecked == others.size()},
                                              {QStringLiteral("partial"), otherChecked > 0 && otherChecked < others.size()},
                                              {QStringLiteral("candidates"), others}}},
    });
  }
  int selectedCount = 0;
  for (const QJsonObject& candidate : all) {
    if (selected.contains(candidate.value(QLatin1String("key")).toString())) ++selectedCount;
  }
  return {
      {QStringLiteral("loading"), !anyData && anyPending},
      {QStringLiteral("multiple"), m_setupIds.size() > 1},
      {QStringLiteral("total"), all.size()},
      {QStringLiteral("selectedCount"), selectedCount},
      {QStringLiteral("error"), m_importError},
      {QStringLiteral("scans"), scans},
  };
}

// ---- Finishing --------------------------------------------------------------

// Saves that setup is done, then opens the app: on a new thread in the
// project it lands on, else home.
void OnboardingController::finish(std::optional<QPair<QString, QString>> project) {
  if (m_finishing) return;
  SettingsController* device = settings();
  auto* toasts = NativeShell::of(this)->controller<ToastController>();
  QJsonObject saved = device ? device->deviceSettings() : QJsonObject();
  saved.insert(kCompletedAt, m_now().toUTC().toString(Qt::ISODateWithMs));
  m_finishing = true;
  const bool done = device && device->setDeviceSettings(saved);
  m_finishing = false;
  if (!done) {
    m_importing = false;
    const QString title = QStringLiteral("Could not finish setup");
    const QString description = QStringLiteral("Your settings could not be saved. Try again.");
    if (m_finishToast.isEmpty() || !toasts->update(m_finishToast, title, description)) {
      m_finishToast = toasts->show(QStringLiteral("error"), title, description);
    }
    publish();
    return;
  }
  if (!m_finishToast.isEmpty()) toasts->dismiss(m_finishToast);
  m_finishToast.clear();
  closeSetup();
  m_importing = false;
  m_gate = QStringLiteral("app");
  publish();
  if (project) {
    land(project->first, project->second);
  } else {
    NativeShell::of(this)->controller<NavigationController>()->open(NavigationController::Route::of(QStringLiteral("home")));
  }
}

void OnboardingController::land(const QString& environmentId, const QString& projectId) {
  NativeShell::of(this)->controller<DraftController>()->start(environmentId, projectId);
}

// ---- Publishing -------------------------------------------------------------

void OnboardingController::publish() {
  SettingsController* device = settings();
  QString recovery;
  if (device && device->deviceUnreadable()) {
    recovery = QStringLiteral("settings");
  } else if (m_gate == QLatin1String("pending") && m_stalled) {
    recovery = QStringLiteral("connection");
  }
  QVariantList computers;
  bool ready = false;
  for (const QString& id : std::as_const(m_computers)) {
    const bool selected = m_selected.contains(id);
    if (selected) ready = true;
    computers.append(QVariantMap{{QStringLiteral("environmentId"), id},
                                 {QStringLiteral("label"), label(id)},
                                 {QStringLiteral("connected"), m_store->environmentOnline(id)},
                                 {QStringLiteral("selected"), selected}});
  }
  for (const QString& id : std::as_const(m_selected)) {
    if (m_computers.contains(id) && !m_store->environmentOnline(id)) ready = false;
  }
  QVariant terminal = null();
  if (m_setup) {
    terminal = QVariantMap{{QStringLiteral("environmentId"), m_setup->environmentId},
                           {QStringLiteral("driver"), m_setup->driver},
                           {QStringLiteral("command"), m_setup->command},
                           {QStringLiteral("status"), m_setup->status}};
  }
  const int stage = m_step == QLatin1String("agents") ? 1 : m_step == QLatin1String("import") ? 2 : 0;
  m_bridge->publish(QStringLiteral("onboarding"),
                    QVariantMap{
                        {QStringLiteral("gate"), m_gate},
                        {QStringLiteral("recovery"), recovery.isEmpty() ? null() : QVariant(recovery)},
                        {QStringLiteral("step"), m_step},
                        {QStringLiteral("stage"), stage},
                        {QStringLiteral("importing"), m_importing},
                        {QStringLiteral("computers"), computers},
                        {QStringLiteral("canContinue"), ready && !m_pairing},
                        {QStringLiteral("pairing"), m_pairing},
                        {QStringLiteral("pairingError"), m_pairingError},
                        {QStringLiteral("pairingDetail"), m_pairingDetail},
                        {QStringLiteral("agents"), m_step == QLatin1String("agents") ? agents().value(QStringLiteral("computers")) : QVariantList()},
                        {QStringLiteral("terminal"), terminal},
                        {QStringLiteral("import"), m_step == QLatin1String("import") ? importState() : QVariantMap()},
                    });
}
