#include "NativeShell.h"

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlEngine>
#include <QRegularExpression>
#include <QPointer>
#include <QSaveFile>
#include <QUuid>
#include <QtLogging>

#include <algorithm>

#include "ComposerController.h"
#include "DraftController.h"
#include "KeybindingController.h"
#include "NavigationController.h"
#include "RightPanelController.h"
#include "TerminalController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "WorkspaceController.h"

QList<NativeControllerRegistration>& nativeControllerRegistry() {
  static QList<NativeControllerRegistration> registry;
  return registry;
}

namespace {

const QString kNewWindow = QStringLiteral("window.new");
const QString kWindowsDir = QStringLiteral("shell-windows");

// A window's id names its directory under shell-windows/, so one from an
// action or a saved file is used only if it cannot climb out of it.
bool validWindowId(const QString& id) {
  static const QRegularExpression pattern(QStringLiteral("^[A-Za-z0-9_-]{1,32}$"));
  return pattern.match(id).hasMatch();
}

// The process's one shell, for the QML singleton factories.
NativeShell* g_shell = nullptr;

}  // namespace

NativeWindow::NativeWindow(NativeShell* shell, const QString& id, ShellBridge* bridge, std::unique_ptr<ShellBridge> owned)
    : QObject(shell),
      m_shell(shell),
      m_id(id),
      m_ownedBridge(std::move(owned)),
      m_bridge(bridge),
      m_sidebar(bridge, shell->client(), shell->store(), this) {
  for (const NativeControllerRegistration& registration : shell->registrations()) {
    for (const QString& key : registration.stateKeys) bridge->declareKey(key);
    if (registration.scope == NativeControllerScope::Shared) continue;
    std::unique_ptr<QObject> object(registration.create(bridge, shell->client(), shell->store(), this));
    auto* native = dynamic_cast<NativeController*>(object.get());
    m_controllers.push_back({registration.name, std::move(object), native, registration.qmlName});
  }
  // Every controller, this window's and the shared ones, in name order.
  for (const NativeControllerRegistration& registration : shell->registrations()) {
    for (const std::vector<NativeControllerEntry>* entries :
       std::initializer_list<const std::vector<NativeControllerEntry>*>{&m_controllers, &shell->m_shared}) {
      for (const NativeControllerEntry& entry : *entries) {
        if (entry.name == registration.name) m_handlers.push_back(entry.native);
      }
    }
  }
  if (ShellBridge* shared = shell->m_sharedBridge; bridge != shared) {
    // The shared controllers publish on the shared bridge; this one shows the
    // same.
    for (const QString& key : shell->sharedKeys()) {
      if (shared->state()->contains(key)) bridge->publish(key, shared->state()->value(key));
    }
    connect(shared, &ShellBridge::stateEntryChanged, this, [this](const QString& key, const QVariant& value) {
      if (m_shell->sharedKeys().contains(key)) m_bridge->publish(key, value);
    });
  }
  // The shared bridge outlives the first window, and keeps its interceptor.
  bridge->addInterceptor([window = QPointer<NativeWindow>(this)](const QString& action, const QVariant& payload) {
    if (!window) return false;
    window->m_shell->setActiveWindow(window);
    return window->handle(action, payload);
  });
  // The sidebar marks the thread the window shows.
  if (auto* navigation = controller<NavigationController>()) {
    connect(navigation, &NavigationController::changed, &m_sidebar, &SidebarController::refresh);
  }
  // The sidebar lists the drafts.
  if (auto* drafts = controller<DraftController>()) {
    connect(drafts, &DraftController::changed, &m_sidebar, &SidebarController::refresh);
    // The header (and the terminal) of a draft route is the draft's thread.
    if (auto* workspace = controller<WorkspaceController>()) {
      workspace->setDraftResolver([drafts](const QString& id) -> std::optional<WorkspaceController::DraftPlace> {
        const auto draft = drafts->draft(id);
        if (!draft) return std::nullopt;
        return WorkspaceController::DraftPlace{draft->environmentId, draft->projectId, draft->threadId};
      });
      connect(drafts, &DraftController::changed, workspace, &WorkspaceController::refresh);
    }
  }
  // And groups, orders and dates them as this device's preferences say.
  if (auto* settings = controller<SettingsController>()) {
    connect(settings, &SettingsController::deviceChanged, &m_sidebar, &SidebarController::refresh);
  }
}

// Controllers go before the sidebar and bridge they were built on.
NativeWindow::~NativeWindow() { m_controllers.clear(); }

QObject* NativeWindow::singleton(const char* qmlName) const {
  for (const std::vector<NativeControllerEntry>* entries :
       std::initializer_list<const std::vector<NativeControllerEntry>*>{&m_controllers, &m_shell->m_shared}) {
    for (const NativeControllerEntry& entry : *entries) {
      if (entry.qmlName && qstrcmp(entry.qmlName, qmlName) == 0) return entry.object.get();
    }
  }
  return nullptr;
}

void NativeWindow::setStoreDirs(const QString& state) {
  QDir().mkpath(state);
  if (auto* navigation = controller<NavigationController>()) {
    navigation->setStorePath(QDir(state).filePath(QStringLiteral("shell-route.json")));
  }
  if (auto* panel = controller<RightPanelController>()) {
    panel->setStorePath(QDir(state).filePath(QStringLiteral("shell-panel.json")));
  }
  if (auto* terminals = controller<TerminalController>()) terminals->setStorePath(QDir(state).filePath(QStringLiteral("shell-terminals.json")));
}

bool NativeWindow::handle(const QString& action, const QVariant& payload) {
  if (action == kNewWindow) {
    m_shell->openWindow(payload.toMap().value(QStringLiteral("id")).toString());
    return true;
  }
  if (m_sidebar.handle(action, payload)) return true;
  return std::any_of(m_handlers.cbegin(), m_handlers.cend(),
                     [&](NativeController* handler) { return handler->handle(action, payload); });
}

void NativeWindow::activate() {
  for (const NativeControllerEntry& entry : m_controllers) entry.native->activate();
  m_sidebar.activate();
  for (const NativeControllerEntry& entry : m_shell->m_shared) entry.native->attach(this);
  if (auto* keys = controller<KeybindingController>()) {
    keys->commands()->add(kNewWindow, tr("New window"), [this] { m_shell->openWindow(); });
  }
}

NativeShell::NativeShell(ShellBridge* bridge, QObject* parent)
    : QObject(parent), m_client(this), m_store(&m_client, this), m_sharedBridge(bridge) {
  g_shell = this;
  // Static initialisers register in link order; name order keeps it stable.
  m_registrations = nativeControllerRegistry();
  std::sort(m_registrations.begin(), m_registrations.end(), [](const auto& a, const auto& b) { return a.name < b.name; });
  // The shared ones first, so every window finds them; they publish on the
  // first window's bridge and every other mirrors it.
  // main.cpp's own: the backend's failure, which every window shows.
  m_sharedKeys += QStringLiteral("backendError");
  for (const NativeControllerRegistration& registration : m_registrations) {
    if (registration.scope != NativeControllerScope::Shared) continue;
    m_sharedKeys += registration.stateKeys;
    std::unique_ptr<QObject> object(registration.create(bridge, &m_client, &m_store, this));
    auto* native = dynamic_cast<NativeController*>(object.get());
    m_shared.push_back({registration.name, std::move(object), native, registration.qmlName});
  }
  m_windows.push_back(std::make_unique<NativeWindow>(this, NativeWindow::kMain, bridge));
  connect(&m_store, &ShellStore::changed, this, &NativeShell::update);
}

NativeShell::~NativeShell() {
  // Windows (and their controllers) before the shared controllers they use.
  m_windows.clear();
  m_shared.clear();
  if (g_shell == this) g_shell = nullptr;
}

NativeWindow* NativeShell::of(const QObject* controller) {
  QObject* parent = controller->parent();
  if (auto* window = qobject_cast<NativeWindow*>(parent)) return window;
  if (auto* shell = qobject_cast<NativeShell*>(parent)) return shell->activeWindow();
  return nullptr;
}

NativeWindow* NativeShell::window(const QString& id) const {
  for (const auto& window : m_windows) {
    if (window->id() == id) return window.get();
  }
  return nullptr;
}

void NativeShell::open(const QUrl& origin, const QString& token) {
  m_sharedBridge->setMcOrigin(origin);
  for (const auto& window : m_windows) window->bridge()->setMcOrigin(origin);
  m_client.open(origin, token);
}

NativeWindow* NativeShell::openWindow(const QString& id) {
  if (NativeWindow* open = window(id)) {
    open->bridge()->windowCommand(QStringLiteral("raise"));
    return open;
  }
  const QString windowId = validWindowId(id) ? id : QUuid::createUuid().toString(QUuid::Id128).left(12);
  auto bridge = std::make_unique<ShellBridge>();
  bridge->setLocalFolderImportEnabled(m_sharedBridge->localFolderImportEnabled());
  bridge->setMcOrigin(m_sharedBridge->mcOrigin());
  ShellBridge* raw = bridge.get();
  m_windows.push_back(std::make_unique<NativeWindow>(this, windowId, raw, std::move(bridge)));
  NativeWindow* window = m_windows.back().get();
  if (!m_stateDir.isEmpty()) window->setStoreDirs(windowDir(windowId));
  if (m_active) activate(window);
  saveWindows();
  emit windowOpened(window);
  return window;
}

void NativeShell::closeWindow(const QString& id) {
  const auto it = std::find_if(m_windows.begin(), m_windows.end(), [&](const auto& window) { return window->id() == id; });
  if (it == m_windows.end()) return;
  // The last one keeps its place and files, to reopen with.
  if (m_windows.size() == 1) {
    emit lastWindowClosed();
    return;
  }
  NativeWindow* window = it->release();
  m_windows.erase(it);
  if (m_activeWindow == window) m_activeWindow = nullptr;
  saveWindows();
  // Its route and panels; the drafts are every window's.
  if (!m_stateDir.isEmpty() && id == NativeWindow::kMain) {
    QFile::remove(QDir(m_stateDir).filePath(QStringLiteral("shell-route.json")));
    QFile::remove(QDir(m_stateDir).filePath(QStringLiteral("shell-panel.json")));
    QFile::remove(QDir(m_stateDir).filePath(QStringLiteral("shell-terminals.json")));
  } else if (!m_stateDir.isEmpty()) {
    QDir(windowDir(id)).removeRecursively();
  }
  emit windowClosing(window);
  window->deleteLater();
}

void NativeShell::setStoreDirs(const QString& state, const QString& data) {
  m_stateDir = state;
  const QStringList saved = savedWindows();
  if (!saved.isEmpty()) main()->m_id = saved.first();
  main()->setStoreDirs(windowDir(main()->id()));
  // Every window's alike, so the first window's load them.
  QDir().mkpath(data);
  if (auto* drafts = controller<DraftController>()) drafts->setStorePath(QDir(data).filePath(QStringLiteral("shell-drafts.json")));
  if (auto* composer = controller<ComposerController>()) {
    composer->setStorePath(QDir(data).filePath(QStringLiteral("shell-composer.json")));
  }
}

void NativeShell::restoreWindows() {
  for (const QString& id : savedWindows()) {
    if (!window(id)) openWindow(id);
  }
}

QStringList NativeShell::savedWindows() const {
  if (m_stateDir.isEmpty()) return {};
  QFile file(QDir(m_stateDir).filePath(kWindowsDir + QStringLiteral(".json")));
  if (!file.open(QIODevice::ReadOnly)) return {};
  QStringList ids;
  for (const QJsonValue& id : QJsonDocument::fromJson(file.readAll()).object().value(QStringLiteral("open")).toArray()) {
    if (validWindowId(id.toString()) && !ids.contains(id.toString())) ids.append(id.toString());
  }
  return ids;
}

QString NativeShell::windowDir(const QString& id) const {
  return id == NativeWindow::kMain ? m_stateDir : QDir(m_stateDir).filePath(kWindowsDir + QLatin1Char('/') + id);
}

void NativeShell::saveWindows() const {
  if (m_stateDir.isEmpty()) return;
  QJsonArray ids;
  for (const auto& window : m_windows) ids.append(window->id());
  QDir().mkpath(m_stateDir);
  QSaveFile file(QDir(m_stateDir).filePath(kWindowsDir + QStringLiteral(".json")));
  if (!file.open(QIODevice::WriteOnly)) return;
  file.write(QJsonDocument(QJsonObject{{QStringLiteral("open"), ids}}).toJson(QJsonDocument::Compact));
  if (!file.commit()) qWarning("shell windows not saved: %s", qPrintable(file.errorString()));
}

NativeWindow* NativeShell::windowFor(QQmlEngine* engine) const {
  if (engine) {
    auto* bridge = qvariant_cast<ShellBridge*>(engine->property("halC2Bridge"));
    for (const auto& window : m_windows) {
      if (window->bridge() == bridge) return window.get();
    }
  }
  return main();
}

void NativeShell::registerQmlSingletons() {
  static QSet<QByteArray> registered;
  for (const NativeControllerRegistration& registration : m_registrations) {
    if (!registration.qmlName || registered.contains(registration.qmlName)) continue;
    registered.insert(registration.qmlName);
    const QByteArray name = registration.qmlName;
    // Every engine asks the shell of the moment, so a test's next shell
    // (World::restart) is the one its engines see.
    registration.registerSingleton([name](QQmlEngine* engine) -> QObject* {
      if (!g_shell) return nullptr;
      QObject* object = g_shell->windowFor(engine)->singleton(name.constData());
      if (object) QQmlEngine::setObjectOwnership(object, QQmlEngine::CppOwnership);
      return object;
    });
  }
}

void NativeShell::update() {
  if (m_active || !m_store.synchronized()) return;
  m_active = true;
  for (const NativeControllerEntry& entry : m_shared) entry.native->activate();
  for (const auto& window : m_windows) activate(window.get());
  emit ready();
}

void NativeShell::activate(NativeWindow* window) { window->activate(); }
