#include "SnapShotController.h"

#include <QBuffer>
#include <QJsonValue>

#include <cmath>

#include "../ShellBridge.h"
#include "ComposerController.h"
#include "DraftController.h"
#include "KeybindingController.h"
#include "Keybindings.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "SettingsController.h"
#include "ShellStore.h"
#include "SnapShotBackend.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<SnapShotController> registrar(QStringLiteral("snapShot"), {QStringLiteral("snapShot")}, nullptr,
                                                              NativeControllerScope::Shared);

const QString kAccess = QStringLiteral("access");
const QString kShortcutStep = QStringLiteral("shortcut");

bool isPair(const QJsonObject& shortcut) {
  return shortcut.contains(QLatin1String("kind"));
}

QString pairModifier(const QJsonObject& shortcut) {
  return shortcut.value(QLatin1String("kind")).toString() == QLatin1String("both-shift-keys")
             ? QStringLiteral("shift")
             : shortcut.value(QLatin1String("modifier")).toString();
}

keybindings::Shortcut chordOf(const QJsonObject& shortcut) {
  keybindings::Shortcut chord;
  chord.key = shortcut.value(QLatin1String("key")).toString();
  chord.meta = shortcut.value(QLatin1String("metaKey")).toBool();
  chord.ctrl = shortcut.value(QLatin1String("ctrlKey")).toBool();
  chord.shift = shortcut.value(QLatin1String("shiftKey")).toBool();
  chord.alt = shortcut.value(QLatin1String("altKey")).toBool();
  chord.mod = shortcut.value(QLatin1String("modKey")).toBool();
  return chord;
}

QJsonObject jsonOf(const keybindings::Shortcut& chord) {
  return {{QStringLiteral("key"), chord.key},       {QStringLiteral("metaKey"), chord.meta},
          {QStringLiteral("ctrlKey"), chord.ctrl},  {QStringLiteral("shiftKey"), chord.shift},
          {QStringLiteral("altKey"), chord.alt},    {QStringLiteral("modKey"), chord.mod}};
}

// The web's shortcutConflictKey: mod is Command on macOS, Ctrl elsewhere.
QString conflictKey(const keybindings::Shortcut& chord, bool mac) {
  const bool meta = chord.meta || (mac && chord.mod);
  const bool ctrl = chord.ctrl || (!mac && chord.mod);
  return QStringLiteral("%1|%2|%3|%4|%5").arg(chord.key.toLower()).arg(meta).arg(ctrl).arg(chord.shift).arg(chord.alt);
}

// apps/desktop/src/snapShot/snapShot.ts snapShotShortcutSystemConflict.
QString systemConflict(const keybindings::Shortcut& chord) {
  const int modifiers = int(chord.mod) + int(chord.meta) + int(chord.ctrl) + int(chord.alt) + int(chord.shift);
  if (modifiers != 1) return {};
  if (chord.shift) return QObject::tr("Shift combinations are used for typing and text selection. Add another modifier.");
  const QString key = chord.key.toLower();
  if (chord.mod) {
    static const QHash<QString, QString> common{
        {QStringLiteral("a"), QStringLiteral("Select All")}, {QStringLiteral("c"), QStringLiteral("Copy")},
        {QStringLiteral("f"), QStringLiteral("Find")},       {QStringLiteral("n"), QStringLiteral("New")},
        {QStringLiteral("o"), QStringLiteral("Open")},       {QStringLiteral("p"), QStringLiteral("Print")},
        {QStringLiteral("q"), QStringLiteral("Quit")},       {QStringLiteral("s"), QStringLiteral("Save")},
        {QStringLiteral("t"), QStringLiteral("New Tab")},    {QStringLiteral("v"), QStringLiteral("Paste")},
        {QStringLiteral("w"), QStringLiteral("Close Window")}, {QStringLiteral("x"), QStringLiteral("Cut")},
        {QStringLiteral("z"), QStringLiteral("Undo")},
    };
    const QString action = common.value(key);
    return action.isEmpty() ? QString() : QObject::tr("This shortcut is %1 in most apps.").arg(action);
  }
  if (chord.ctrl && (key == QLatin1String("c") || key == QLatin1String("d") || key == QLatin1String("z"))) {
    return QObject::tr("This shortcut controls running commands in terminals.");
  }
  if (chord.alt && key == QLatin1String("tab")) return QObject::tr("The system uses Alt+Tab to switch apps.");
  if (chord.meta && (key == QLatin1String("l") || key == QLatin1String(" ") || key == QLatin1String("space"))) {
    return QObject::tr("The system already uses this shortcut.");
  }
  return {};
}

QString desktopName(const QString& desktop) {
  if (desktop == QLatin1String("gnome")) return QStringLiteral("GNOME");
  if (desktop == QLatin1String("kde")) return QStringLiteral("KDE Plasma");
  if (desktop == QLatin1String("niri")) return QStringLiteral("Niri");
  if (desktop == QLatin1String("hyprland")) return QStringLiteral("Hyprland");
  return {};
}

}  // namespace

SnapShotController::SnapShotController(ShellBridge* bridge, McClient*, ShellStore* store, QObject* parent)
    : QObject(parent), m_bridge(bridge), m_store(store), m_now([] { return QDateTime::currentDateTimeUtc(); }) {}

SnapShotController::~SnapShotController() {
  m_active = false;
  if (!m_backend) return;
  disconnect(m_backend, nullptr, this, nullptr);
  m_backend->release();
}

void SnapShotController::activate() {
  if (!m_backend) {
    m_backend = SnapShotBackend::create(this);
    connect(m_backend, &SnapShotBackend::changed, this, &SnapShotController::publish);
    connect(m_backend, &SnapShotBackend::activated, this, &SnapShotController::onActivated);
    connect(m_backend, &SnapShotBackend::captured, this, &SnapShotController::onCaptured);
    connect(m_backend, &SnapShotBackend::failed, this, &SnapShotController::onFailed);
  }
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    connect(settings, &SettingsController::deviceChanged, this, &SnapShotController::follow, Qt::UniqueConnection);
  }
  m_active = true;
  follow();
}

void SnapShotController::attach(NativeWindow* window) {
  if (auto* navigation = window->controller<NavigationController>()) {
    connect(navigation, &NavigationController::changed, this, [this, window = QPointer<NativeWindow>(window)] {
      if (!window) return;
      noteRoute(window);
      follow();
    });
  }
  noteRoute(window);
  follow();
}

void SnapShotController::noteRoute(NativeWindow* window) {
  const auto* navigation = window->controller<NavigationController>();
  if (!navigation) return;
  const auto& route = navigation->route();
  if (route.kind == QLatin1String("thread") && !route.threadKey.isEmpty()) m_lastTarget[window->id()] = route.threadKey;
  if (route.kind == QLatin1String("draft") && !route.draftId.isEmpty()) m_lastTarget[window->id()] = route.draftId;
}

// --- Settings ---------------------------------------------------------------------

QVariant SnapShotController::setting(const QString& key) const {
  const auto* settings = NativeShell::of(this)->controller<SettingsController>();
  return settings ? settings->setting(key) : QVariant();
}

void SnapShotController::set(const QString& key, const QVariant& value) {
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) settings->set(key, value);
}

bool SnapShotController::enabled() const {
  return setting(QStringLiteral("snapShotEnabled")).toBool();
}

QJsonObject SnapShotController::savedShortcut() const {
  return QJsonValue::fromVariant(setting(QStringLiteral("snapShotShortcut"))).toObject();
}

bool SnapShotController::mac() const {
  const auto* keys = NativeShell::of(this)->controller<KeybindingController>();
  return keys && keys->mac();
}

bool SnapShotController::accessReady() const {
  const auto session = m_backend->session();
  return session.mode != QLatin1String("unavailable") && session.message.isEmpty();
}

bool SnapShotController::panelOpen() const {
  auto* shell = qobject_cast<NativeShell*>(parent());
  if (!shell) return false;
  for (const auto& window : shell->windows()) {
    const auto* navigation = window->controller<NavigationController>();
    if (navigation && navigation->route() == NavigationController::Route::settings(kSection)) return true;
  }
  return false;
}

void SnapShotController::follow() {
  if (!m_active || !m_backend) return;
  if (enabled() || panelOpen()) m_backend->probe();
  applyShortcut();
  publish();
}

void SnapShotController::applyShortcut() {
  QString trigger;
  QString problem;
  if (enabled() && m_backend->session().mode == QLatin1String("portal")) {
    trigger = SnapShotBackend::portalTrigger(savedShortcut(), &problem);
  }
  m_shortcutProblem = problem;
  if (trigger == m_bound) return;
  m_bound = trigger;
  if (trigger.isEmpty()) {
    m_backend->release();
  } else {
    m_backend->bind(trigger);
  }
}

// --- Setup ------------------------------------------------------------------------

QString SnapShotController::initialStep(const QString& requested) const {
  if (!accessReady()) return kAccess;
  if (requested == kAccess || requested == kShortcutStep) return requested;
  return m_backend->session().backend == QLatin1String("picker") ? kAccess : kShortcutStep;
}

void SnapShotController::openSetup(const QString& requested) {
  if (!m_backend->session().ready) return;
  stopRecording();
  resetCandidate();
  const bool wasEnabled = enabled();
  const QString step = initialStep(requested);
  // Opening setup is the opt-in.
  if (!wasEnabled && step != kAccess) set(QStringLiteral("snapShotEnabled"), true);
  m_wizard = Wizard{step, wasEnabled};
  publish();
}

void SnapShotController::closeSetup(bool completed) {
  if (!m_wizard) return;
  const bool wasEnabled = m_wizard->wasEnabled;
  stopRecording();
  m_wizard.reset();
  if (enabled() && !wasEnabled && !completed) set(QStringLiteral("snapShotEnabled"), false);
  publish();
}

void SnapShotController::stopRecording() {
  m_recording = false;
  m_held.clear();
}

void SnapShotController::resetCandidate() {
  m_candidate.reset();
  m_check.reset();
}

// --- The shortcut -----------------------------------------------------------------

QString SnapShotController::label(const QJsonObject& shortcut) const {
  if (isPair(shortcut)) {
    const QString modifier = pairModifier(shortcut);
    const bool apple = mac();
    QString name = QStringLiteral("Shift");
    if (modifier == QLatin1String("meta")) name = apple ? QStringLiteral("Command") : QStringLiteral("Super");
    if (modifier == QLatin1String("control")) name = apple ? QStringLiteral("Control") : QStringLiteral("Ctrl");
    if (modifier == QLatin1String("alt")) name = apple ? QStringLiteral("Option") : QStringLiteral("Alt");
    return QStringLiteral("%1 + %1").arg(name);
  }
  return keybindings::label(chordOf(shortcut), mac());
}

QString SnapShotController::conflict(const QJsonObject& shortcut) const {
  if (isPair(shortcut)) return {};
  const auto* keys = NativeShell::of(this)->controller<KeybindingController>();
  if (!keys) return {};
  const QString key = conflictKey(chordOf(shortcut), keys->mac());
  for (const keybindings::Binding& binding : keys->resolved()) {
    if (conflictKey(binding.shortcut, keys->mac()) == key) return binding.command;
  }
  return {};
}

// DesktopSnapShot.checkShortcut.
SnapShotController::Check SnapShotController::check(const QJsonObject& shortcut) const {
  if (m_backend->session().mode != QLatin1String("portal")) {
    return {false, tr("SnapShots are not supported on this platform.")};
  }
  QString problem;
  if (!isPair(shortcut)) {
    if (const QString reserved = systemConflict(chordOf(shortcut)); !reserved.isEmpty()) return {false, reserved};
  }
  if (SnapShotBackend::portalTrigger(shortcut, &problem).isEmpty()) return {false, problem};
  return {true, tr("Your desktop will confirm this shortcut when you save it.")};
}

void SnapShotController::record(const QJsonObject& shortcut) {
  stopRecording();
  m_candidate = shortcut;
  m_check.reset();
  if (shortcutChanged() && conflict(shortcut).isEmpty()) m_check = check(shortcut);
  publish();
}

bool SnapShotController::shortcutChanged() const {
  return m_candidate && *m_candidate != savedShortcut();
}

bool SnapShotController::canSave() const {
  return shortcutChanged() && conflict(*m_candidate).isEmpty() && m_check && m_check->available;
}

QString SnapShotController::shortcutStatus() const {
  // The web hides a refused modifier pair behind this while it records; the
  // refusal shows here, where the user can see why nothing was recorded.
  if (m_recording) return m_check ? m_check->message : tr("Press your shortcut. Esc cancels.");
  if (shortcutChanged()) {
    if (const QString command = conflict(*m_candidate); !command.isEmpty()) {
      return tr("HAL-C2 already uses this for \"%1\".").arg(keybindings::commandLabel(command));
    }
  }
  if (m_check) return m_check->available ? tr("Ready to save.") : m_check->message;
  const auto session = m_backend->session();
  const auto shortcut = m_backend->shortcut();
  const QJsonObject display = shortcutChanged() ? *m_candidate : savedShortcut();
  if (session.mode == QLatin1String("portal") && shortcut.label.isEmpty() && isPair(display)) {
    return tr("Try a shortcut such as Ctrl+Shift+2.");
  }
  if (!m_shortcutProblem.isEmpty()) return m_shortcutProblem;
  if (shortcut.pending) return tr("Approve the shortcut permission prompt to continue.");
  if (shortcut.registered) return session.mode == QLatin1String("portal") ? QString() : tr("Shortcut saved.");
  return shortcut.message;
}

// --- Actions ----------------------------------------------------------------------

bool SnapShotController::handle(const QString& action, const QVariant& payload) {
  if (!action.startsWith(QLatin1String("snapShot."))) return false;
  if (!m_backend) return true;
  const QVariantMap map = payload.toMap();

  if (action == QLatin1String("snapShot.enable")) {
    if (map.value(QStringLiteral("on")).toBool()) {
      openSetup(QStringLiteral("resume"));
    } else {
      stopRecording();
      m_wizard.reset();
      set(QStringLiteral("snapShotEnabled"), false);
      publish();
    }
    return true;
  }
  if (action == QLatin1String("snapShot.setup.open")) {
    openSetup(map.value(QStringLiteral("step"), QStringLiteral("resume")).toString());
    return true;
  }
  if (action == QLatin1String("snapShot.setup.continue")) {
    if (!m_wizard) return true;
    if (!enabled() || !m_backend->session().message.isEmpty()) set(QStringLiteral("snapShotEnabled"), true);
    if (accessReady()) {
      stopRecording();
      m_wizard->step = kShortcutStep;
    }
    publish();
    return true;
  }
  if (action == QLatin1String("snapShot.setup.back")) {
    if (!m_wizard) return true;
    stopRecording();
    m_wizard->step = kAccess;
    publish();
    return true;
  }
  if (action == QLatin1String("snapShot.setup.close")) {
    closeSetup(map.value(QStringLiteral("completed")).toBool());
    return true;
  }
  if (action == QLatin1String("snapShot.setup.done")) {
    if (!m_wizard || !accessReady()) return true;
    if (shortcutChanged()) {
      if (!canSave()) return true;
      set(QStringLiteral("snapShotShortcut"), m_candidate->toVariantMap());
      resetCandidate();
    }
    const auto shortcut = m_backend->shortcut();
    if (shortcut.registered || shortcut.pending) closeSetup(true);
    else publish();
    return true;
  }
  if (action == QLatin1String("snapShot.record.start")) {
    m_recording = true;
    m_held.clear();
    m_check.reset();
    publish();
    return true;
  }
  if (action == QLatin1String("snapShot.record.cancel")) {
    if (!m_recording) return true;
    stopRecording();
    publish();
    return true;
  }
  if (action == QLatin1String("snapShot.record.key")) {
    if (!m_recording) return true;
    const int key = map.value(QStringLiteral("key")).toInt();
    if (key == Qt::Key_Escape) {
      stopRecording();
      publish();
      return true;
    }
    const QString recorded = keybindings::recordedKey(key, map.value(QStringLiteral("modifiers")).toInt(), mac());
    const auto chord = recorded.isEmpty() ? std::nullopt : keybindings::parseShortcut(recorded);
    if (chord) record(jsonOf(*chord));
    return true;
  }
  if (action == QLatin1String("snapShot.record.modifier")) {
    if (!m_recording) return true;
    const QString modifier = map.value(QStringLiteral("modifier")).toString();
    const QString held = modifier + u':' + map.value(QStringLiteral("code")).toString();
    if (!map.value(QStringLiteral("down")).toBool()) {
      m_held.remove(held);
      return true;
    }
    m_held.insert(held);
    // Both of one modifier's keys make a pair.
    const auto count = std::count_if(m_held.cbegin(), m_held.cend(),
                                     [&](const QString& entry) { return entry.startsWith(modifier + u':'); });
    if (count < 2) return true;
    if (m_backend->session().mode == QLatin1String("portal")) {
      m_check = Check{false, tr("Add a letter, number, or function key to your shortcut.")};
      publish();
      return true;
    }
    record(modifier == QLatin1String("shift")
               ? QJsonObject{{QStringLiteral("kind"), QStringLiteral("both-shift-keys")}}
               : QJsonObject{{QStringLiteral("kind"), QStringLiteral("modifier-pair")}, {QStringLiteral("modifier"), modifier}});
    return true;
  }
  if (action == QLatin1String("snapShot.shortcut.save")) {
    if (!canSave()) return true;
    const QJsonObject shortcut = *m_candidate;
    resetCandidate();
    set(QStringLiteral("snapShotShortcut"), shortcut.toVariantMap());
    publish();
    return true;
  }
  if (action == QLatin1String("snapShot.shortcut.discard")) {
    stopRecording();
    resetCandidate();
    publish();
    return true;
  }
  if (action == QLatin1String("snapShot.shortcut.permissions")) {
    m_backend->configure();
    return true;
  }
  if (action == QLatin1String("snapShot.set")) {
    static const QHash<QString, QString> keys{{QStringLiteral("accessibility"), QStringLiteral("snapShotIncludeAccessibility")},
                                              {QStringLiteral("flash"), QStringLiteral("snapShotFlash")},
                                              {QStringLiteral("animations"), QStringLiteral("snapShotAnimations")}};
    const QString key = keys.value(map.value(QStringLiteral("key")).toString());
    if (!key.isEmpty()) set(key, map.value(QStringLiteral("value")).toBool());
    return true;
  }
  if (action == QLatin1String("snapShot.sound")) {
    const QString value = map.value(QStringLiteral("value")).toString();
    if (value == QLatin1String("off")) {
      set(QStringLiteral("snapShotPlaySound"), false);
    } else if (value == QLatin1String("soft-pop") || value == QLatin1String("camera-shutter")) {
      set(QStringLiteral("snapShotPlaySound"), true);
      set(QStringLiteral("snapShotSound"), value);
    }
    return true;
  }
  if (action == QLatin1String("snapShot.sound.play")) {
    m_backend->play(map.value(QStringLiteral("sound")).toString());
    return true;
  }
  return false;
}

// --- Capturing --------------------------------------------------------------------

void SnapShotController::onActivated() {
  // Recording a shortcut suppresses the one held.
  if (m_recording || !enabled()) return;
  m_backend->capture();
}

QString SnapShotController::target(NativeWindow* window) {
  noteRoute(window);
  const QString last = m_lastTarget.value(window->id());
  auto* drafts = window->controller<DraftController>();
  if (!last.isEmpty() && (m_store->thread(last) || (drafts && drafts->draft(last)))) return last;
  m_lastTarget.remove(window->id());
  if (!drafts) return {};
  drafts->handle(QStringLiteral("thread.new"), QVariantMap());
  noteRoute(window);
  return m_lastTarget.value(window->id());
}

void SnapShotController::onCaptured(const QImage& image, const QString& appName, const QString& windowTitle) {
  if (setting(QStringLiteral("snapShotPlaySound")).toBool()) {
    m_backend->play(setting(QStringLiteral("snapShotSound")).toString());
  }
  NativeWindow* window = NativeShell::of(this);
  if (!window) return;
  auto* toasts = window->controller<ToastController>();
  const QString to = target(window);
  if (to.isEmpty()) {
    if (toasts) toasts->error(tr("Snapshot taken, but no project is available"), tr("Add a project, then capture the window again."));
    return;
  }
  QString mimeType;
  const auto bytes = encode(image, m_maxImageBytes, &mimeType);
  if (!bytes) {
    onFailed(tr("The captured window is too large to attach."));
    return;
  }
  const QString capturedAt = m_now().toUTC().toString(Qt::ISODateWithMs);
  QString name = QStringLiteral("window-%1").arg(QString(capturedAt).replace(u':', u'-'));
  name += mimeType == QLatin1String("image/png") ? QStringLiteral(".png") : QStringLiteral(".jpg");
  const QJsonObject source{{QStringLiteral("kind"), QStringLiteral("snap-shot")},
                           {QStringLiteral("capturedAt"), capturedAt},
                           {QStringLiteral("appName"), appName.trimmed().isEmpty() ? QStringLiteral("Window") : appName.trimmed()},
                           {QStringLiteral("windowTitle"), windowTitle.trimmed()}};
  if (auto* composer = window->controller<ComposerController>()) composer->attachImage(to, name, mimeType, *bytes, source);
  window->bridge()->windowCommand(QStringLiteral("raise"));
  window->bridge()->sendToBricks(QStringLiteral("composer.focus"));
}

void SnapShotController::onFailed(const QString& message) {
  NativeWindow* window = NativeShell::of(this);
  auto* toasts = window ? window->controller<ToastController>() : nullptr;
  if (toasts) toasts->error(tr("Snapshot failed"), message);
}

std::optional<QByteArray> SnapShotController::encode(const QImage& image, qint64 maxBytes, QString* mimeType) {
  const auto write = [](const QImage& picture, const char* format, int quality) {
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    picture.save(&buffer, format, quality);
    return bytes;
  };
  const QByteArray png = write(image, "PNG", -1);
  if (!png.isEmpty() && png.size() <= maxBytes) {
    *mimeType = QStringLiteral("image/png");
    return png;
  }
  // imageCompression.ts: a data URL's budget, in bytes.
  const qint64 budget = maxBytes / 3 * 3;
  const QImage opaque = image.convertToFormat(QImage::Format_RGB32);
  const int base = std::max(opaque.width(), opaque.height());
  for (const double scale : {1.0, 0.75, 0.55}) {
    const int dimension = std::max(1, int(std::lround(base * scale)));
    const QImage scaled = dimension >= base ? opaque : opaque.scaled(dimension, dimension, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    for (const int quality : {92, 85, 78, 68}) {
      const QByteArray jpeg = write(scaled, "JPEG", quality);
      if (!jpeg.isEmpty() && jpeg.size() <= budget) {
        *mimeType = QStringLiteral("image/jpeg");
        return jpeg;
      }
    }
  }
  return std::nullopt;
}

// --- State ------------------------------------------------------------------------

void SnapShotController::publish() {
  if (!m_active || !m_backend) return;
  const QVariantMap next = state();
  if (next == m_published) return;
  m_published = next;
  m_bridge->publish(QStringLiteral("snapShot"), next);
}

QVariantMap SnapShotController::state() const {
  const auto session = m_backend->session();
  const auto shortcut = m_backend->shortcut();
  const bool on = enabled();
  const bool portal = session.mode == QLatin1String("portal");
  const bool available = session.ready && session.mode != QLatin1String("unavailable");
  const bool picker = portal && session.backend == QLatin1String("picker");
  const bool ready = accessReady();
  const QString desktop = portal ? desktopName(session.desktop) : QString();
  const QJsonObject saved = savedShortcut();
  const bool changed = shortcutChanged();
  const QJsonObject display = changed ? *m_candidate : saved;

  // snapShotStatus
  QString status;
  if (!session.ready) status = tr("Checking snapshots…");
  else if (!available) status = session.message.isEmpty() ? tr("Not supported on this platform.") : session.message;
  else if (!on) status = tr("Turn this on to set up snapshots.");
  else if (!session.message.isEmpty()) status = tr("Capture needs attention");
  else if (picker) status = tr("Manual capture only — you'll choose a window each time");
  else if (shortcut.pending) status = tr("Waiting for shortcut permission");
  else if (shortcut.registered) status = shortcut.label.isEmpty() ? tr("Shortcut saved") : tr("Ready to capture");
  else status = tr("Finish shortcut setup");

  QString setupLabel;
  if (on && session.ready) {
    setupLabel = ready ? tr("Manage capture") : desktop.isEmpty() ? tr("Continue setup") : tr("Set up %1 capture").arg(desktop);
  }

  QString keys;
  if (m_recording) keys = tr("Press shortcut…");
  else if (portal && isPair(display)) keys = tr("Choose shortcut");
  else if (!changed && !shortcut.label.isEmpty()) keys = shortcut.label;
  else keys = label(display);

  const bool canRetry = shortcut.canRetry && !isPair(saved);
  const QString effects = portal && !session.feedbackAvailable
                              ? (session.desktop == QLatin1String("niri") ? tr("Capture effects aren't available on Niri.")
                                                                          : tr("Capture effects aren't available on this desktop."))
                              : QString();
  const QString screenshotOnly = portal ? tr("This desktop only provides a screenshot.") : QString();
  const auto toggle = [&](const char* key, const QString& unavailable) {
    return QVariantMap{{QStringLiteral("checked"), unavailable.isEmpty() && setting(QLatin1String(key)).toBool()},
                       {QStringLiteral("enabled"), available && unavailable.isEmpty()},
                       {QStringLiteral("status"), unavailable}};
  };
  const QString sound =
      setting(QStringLiteral("snapShotPlaySound")).toBool() ? setting(QStringLiteral("snapShotSound")).toString() : QStringLiteral("off");

  QVariant wizard;
  if (m_wizard) {
    const bool access = m_wizard->step == kAccess;
    QString heading;
    QString body;
    if (access) {
      if (!session.message.isEmpty()) {
        heading = tr("Let's try that again");
        body = tr("Couldn't check snapshots. Try again to continue.");
      } else if (picker) {
        heading = tr("Choose a window each time");
        body = tr("Your desktop doesn't support automatic capture. You'll choose the window to capture instead.");
      } else {
        heading = tr("Allow snapshots");
        body = portal ? tr("Your desktop may ask for permission when you first capture.")
                      : tr("Allow access when prompted to start capturing windows.");
      }
    } else {
      heading = tr("Choose your shortcut");
      body = portal ? tr("Choose your keys, then approve the permission prompt if asked.")
                    : tr("Use both Shift keys, or record a different shortcut.");
    }
    wizard = QVariantMap{
        {QStringLiteral("step"), m_wizard->step},
        {QStringLiteral("title"), desktop.isEmpty() ? tr("Set up snapshots") : tr("Set up snapshots for %1").arg(desktop)},
        {QStringLiteral("heading"), heading},
        {QStringLiteral("body"), body},
        {QStringLiteral("details"), access ? session.message : QString()},
        {QStringLiteral("attention"), !access && !ready ? tr("Capture needs attention. Go back to check access.") : QString()},
        {QStringLiteral("closeLabel"), m_wizard->wasEnabled ? tr("Close") : tr("Finish later")},
        {QStringLiteral("continueLabel"), ready ? tr("Continue") : tr("Try again")},
        {QStringLiteral("doneLabel"), changed ? tr("Save and finish") : tr("Done")},
        {QStringLiteral("doneEnabled"), ready && (changed ? canSave() : shortcut.registered || shortcut.pending)},
        {QStringLiteral("permissions"), !changed && !shortcut.registered && !shortcut.pending && canRetry},
        {QStringLiteral("permissionsLabel"), portal ? tr("Shortcut permissions") : tr("Try again")},
    };
  }

  return {
      {QStringLiteral("ready"), session.ready},
      {QStringLiteral("available"), available},
      {QStringLiteral("mode"), session.mode},
      {QStringLiteral("backend"), session.backend},
      {QStringLiteral("desktop"), session.desktop},
      {QStringLiteral("enabled"), on},
      {QStringLiteral("switchOn"), on || m_wizard.has_value()},
      {QStringLiteral("status"), status},
      {QStringLiteral("description"), picker ? tr("Automatic capture isn't available here. Choose a window instead.")
                                             : tr("Capture a window and attach it to your current draft.")},
      {QStringLiteral("setupLabel"), setupLabel},
      {QStringLiteral("rows"), on && available},
      {QStringLiteral("shortcut"),
       QVariantMap{{QStringLiteral("description"), picker ? tr("Choose a window to capture from any app.")
                                                          : tr("Capture the window you're using without switching apps.")},
                   {QStringLiteral("keys"), keys},
                   {QStringLiteral("label"), label(display)},
                   {QStringLiteral("recording"), m_recording},
                   {QStringLiteral("status"), shortcutStatus()},
                   {QStringLiteral("changed"), changed},
                   {QStringLiteral("canSave"), canSave()},
                   {QStringLiteral("registered"), shortcut.registered},
                   {QStringLiteral("pending"), shortcut.pending},
                   {QStringLiteral("permissions"), !changed && portal && canRetry},
                   {QStringLiteral("permissionsEnabled"), !shortcut.pending}}},
      {QStringLiteral("accessibility"), toggle("snapShotIncludeAccessibility", screenshotOnly)},
      {QStringLiteral("sound"),
       QVariantMap{{QStringLiteral("value"), sound},
                   {QStringLiteral("label"), sound == QLatin1String("off")        ? tr("Off")
                                             : sound == QLatin1String("soft-pop") ? tr("Whoosh (Default)")
                                                                                  : tr("Click")}}},
      {QStringLiteral("flash"), toggle("snapShotFlash", effects)},
      {QStringLiteral("animations"), toggle("snapShotAnimations", effects)},
      {QStringLiteral("wizard"), wizard},
  };
}
