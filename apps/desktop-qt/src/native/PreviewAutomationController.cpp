#include "PreviewAutomationController.h"

#include <QGuiApplication>

#include "Browser.h"
#include "BrowserAutomationPage.h"
#include "LayoutController.h"
#include "NativeShell.h"
#include "PreviewAutomationHost.h"
#include "RightPanelController.h"
#include "SettingsController.h"
#include "ShellStore.h"

namespace {

const NativeControllerRegistrar<PreviewAutomationController> registrar(QStringLiteral("previewAutomation"), {},
                                                                        "PreviewAutomation", NativeControllerScope::Shared);

const QString kBrowserTab = QStringLiteral("browser:");

}  // namespace

PreviewAutomationController::PreviewAutomationController(ShellBridge*, McClient* client, ShellStore* store, QObject* parent)
    : QObject(parent), m_client(client), m_store(store) {}

PreviewAutomationController::~PreviewAutomationController() = default;

void PreviewAutomationController::activate() {
  // A build without the in-app browser has no page for an agent.
  if (m_host || !Browser::supported()) return;
  m_host = new PreviewAutomationHost(m_client, PreviewAutomationHost::machineClientId(), this);
  connect(m_host, &PreviewAutomationHost::activityChanged, this, &PreviewAutomationController::activityChanged);
  connect(m_host, &PreviewAutomationHost::reveal, this, [this](const PreviewAutomationHost::Reveal& reveal) {
    if (reveal.show == 0) return;
    for (const auto& window : NativeShell::of(this)->shell()->windows()) {
      auto* panel = window->controller<RightPanelController>();
      ThreadPreviews* previews = panel ? panel->previews() : nullptr;
      if (!previews || previews->environmentId() != reveal.environmentId || previews->threadId() != reveal.threadId) continue;
      panel->showTab(kBrowserTab + reveal.tabId);
      return;
    }
  });
  connect(m_store, &ShellStore::changed, this, &PreviewAutomationController::offer);
  connect(Browser::instance(), &Browser::pagesChanged, this, &PreviewAutomationController::attachPages);
  if (qGuiApp) connect(qGuiApp, &QGuiApplication::focusWindowChanged, this, &PreviewAutomationController::focus);
  offer();
  attachPages();
  focus();
}

QVariantMap PreviewAutomationController::activity() const {
  return m_host ? m_host->activity() : QVariantMap();
}

bool PreviewAutomationController::reduceMotion() const {
  auto* settings = NativeShell::of(this)->controller<SettingsController>();
  return LayoutController::systemReducedMotion() || (settings && settings->setting(QStringLiteral("reduceMotion")).toBool());
}

void PreviewAutomationController::offer() {
  QList<PreviewAutomationHost::Mc> mcs;
  for (const QString& environmentId : m_store->environments()) {
    const QString mc = m_store->mcServing(environmentId);
    if (!mc.isEmpty() && m_store->environmentOnline(environmentId)) mcs.append({mc, environmentId});
  }
  m_host->setMcs(mcs);
}

void PreviewAutomationController::attachPages() {
  const QList<BrowserPage*> pages = Browser::pages();
  // Gone pages took their drivers with them; a page now showing another tab
  // gets a new one, so the host never mistakes it for the old tab's.
  for (auto it = m_driven.begin(); it != m_driven.end();) {
    if (!it->driver || !pages.contains(it.key()) || it.key()->tabId() != it->tabId) {
      delete it->driver.data();
      it = m_driven.erase(it);
    } else {
      ++it;
    }
  }
  for (BrowserPage* page : pages) {
    if (m_driven.contains(page) || !page->previews()) continue;
    auto* driver = new BrowserAutomationPage(page);
    m_driven.insert(page, {driver, page->tabId()});
    m_host->attach(page->previews()->environmentId(), page->previews()->threadId(), page->tabId(), driver);
  }
}

void PreviewAutomationController::focus() {
  m_host->setFocused(qGuiApp && qGuiApp->focusWindow() != nullptr);
}
