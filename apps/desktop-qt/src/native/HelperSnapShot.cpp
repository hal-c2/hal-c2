#include "HelperSnapShot.h"

HelperSnapShot::HelperSnapShot(const Platform& platform, SnapShotBackend* shortcuts, CaptureHelper* helper, QObject* parent)
    : SnapShotBackend(parent), m_desktop(platform.desktop), m_shortcuts(shortcuts), m_helper(helper) {
  m_shortcuts->setParent(this);
  m_helper->setParent(this);
  connect(m_shortcuts, &SnapShotBackend::changed, this, &SnapShotBackend::changed);
  connect(m_shortcuts, &SnapShotBackend::activated, this, &SnapShotBackend::activated);
  connect(m_helper, &CaptureHelper::changed, this, &SnapShotBackend::changed);
  connect(m_helper, &CaptureHelper::captured, this, [this](const QImage& image, const QString& appName, const QString& windowTitle) {
    emit captured(image, appName, windowTitle);
  });
  connect(m_helper, &CaptureHelper::failed, this, &SnapShotBackend::failed);
  connect(m_helper, &CaptureHelper::performed, this, [this](const QString& error) {
    if (!error.isEmpty()) emit setupFailed(error);
  });
}

SnapShotBackend::Session HelperSnapShot::session() const {
  const CaptureHelper::State state = m_helper->state();
  Session session;
  // Known once the helper has been looked at; the portal's Screenshot is never used.
  session.ready = !state.status.isEmpty();
  session.mode = QStringLiteral("portal");
  session.backend = QStringLiteral("helper");
  session.desktop = m_desktop;
  session.checking = m_helper->busy();
  // The helper can draw effects where the desktop lets it, but nothing here asks it to yet.
  session.feedbackAvailable = false;
  return session;
}

void HelperSnapShot::probe() {
  if (m_helper->state().status.isEmpty()) m_helper->check();
}

void HelperSnapShot::refresh() {
  m_rechecked = true;
  m_helper->check();
}

// SnapShotSetupDialog's helper copy, and SnapShotSettings.logic's capture row
// and effects line, for the helper's state.
std::optional<SnapShotBackend::Setup> HelperSnapShot::setup() const {
  const CaptureHelper::State state = m_helper->state();
  const QString& status = state.status;
  const bool ready = status == QLatin1String("ready");
  const bool error = status == QLatin1String("error");
  Setup setup;
  setup.accessReady = ready;
  if (ready) {
    setup.heading = tr("Capture is ready");
    setup.body = tr("Next, choose your shortcut.");
    // Hyprland's helper says it may still ask for screen-sharing on the first capture.
    if (m_helper->kind() == CaptureHelper::Kind::Hyprland) setup.details = state.message;
  } else if (error) {
    setup.heading = tr("Let's fix capture access");
    setup.body = tr("Try reinstalling the capture helper, then check again.");
    setup.details = state.message;
  } else {
    setup.heading = status == QLatin1String("update-required") ? tr("Update the capture helper") : tr("Allow snapshots");
    setup.body = tr("HAL-C2's capture helper lets you capture other apps and return to your draft. It's included with HAL-C2.");
  }
  if (m_helper->busy()) {
    setup.actionLabel = status.isEmpty() || error || ready ? tr("Checking…") : tr("Installing…");
  } else if (status == QLatin1String("not-installed")) {
    setup.action = m_helper->installAction();
    setup.actionLabel = tr("Install helper");
  } else if (status == QLatin1String("update-required")) {
    setup.action = m_helper->installAction();
    setup.actionLabel = tr("Update helper");
  } else if (!ready) {
    setup.actionLabel = tr("Check again");
  }
  if (m_rechecked && !m_helper->busy() && !status.isEmpty()) {
    setup.checkMessage = error ? tr("Still unable to check access. See Advanced for help.")
                         : ready ? tr("Ready. Continue to choose your shortcut.")
                                 : tr("Not ready yet. Finish the step above.");
  }
  setup.status = error ? tr("Check capture access in setup") : tr("Install the capture helper to continue");
  setup.effects = ready ? tr("Capture effects aren't available on this desktop.") : tr("Install or update the capture helper to enable effects.");
  const QString included = tr("Included with HAL-C2. No download needed.");
  if (error) setup.advanced.append({m_helper->installAction(), tr("Reinstall helper"), included});
  if (!status.isEmpty() && status != QLatin1String("not-installed")) {
    setup.advanced.append({m_helper->removeAction(), tr("Remove capture helper"), included});
  }
  return setup;
}

void HelperSnapShot::perform(const QString& action) {
  if (action != m_helper->installAction() && action != m_helper->removeAction()) {
    SnapShotBackend::perform(action);
    return;
  }
  m_rechecked = false;
  m_helper->perform(action);
}
