#include "SnapShotController.h"

#include <QBuffer>
#include <QClipboard>
#include <QFileInfo>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonValue>
#include <QThread>

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
const QString kResume = QStringLiteral("snapShotSetupResume");

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

// A shortcut's conflict key: mod is Command on macOS, Ctrl elsewhere.
QString conflictKey(const keybindings::Shortcut& chord, bool mac) {
  const bool meta = chord.meta || (mac && chord.mod);
  const bool ctrl = chord.ctrl || (!mac && chord.mod);
  return QStringLiteral("%1|%2|%3|%4|%5").arg(chord.key.toLower()).arg(meta).arg(ctrl).arg(chord.shift).arg(chord.alt);
}

// The system shortcut a chord collides with, if any.
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

std::optional<CaptureShortcutConfig::Tools>& configTools() {
  static std::optional<CaptureShortcutConfig::Tools> tools;
  return tools;
}

// The changed lines of an edit, with two lines either side: {kind: context |
// removed | added, text}.
QVariantList diffLines(const QString& before, const QString& after) {
  const auto lines = [](const QString& text) {
    QStringList split = text.split(u'\n');
    for (QString& line : split) {
      if (line.endsWith(u'\r')) line.chop(1);
    }
    return split;
  };
  const QStringList a = lines(before);
  const QStringList b = lines(after);
  qsizetype head = 0;
  while (head < a.size() && head < b.size() && a[head] == b[head]) ++head;
  qsizetype tail = 0;
  while (tail < a.size() - head && tail < b.size() - head && a[a.size() - 1 - tail] == b[b.size() - 1 - tail]) ++tail;
  QVariantList diff;
  const auto add = [&](const char* kind, const QString& text) {
    diff.append(QVariantMap{{QStringLiteral("kind"), QLatin1String(kind)}, {QStringLiteral("text"), text}});
  };
  for (qsizetype i = std::max<qsizetype>(0, head - 2); i < head; ++i) add("context", a[i]);
  for (qsizetype i = head; i < a.size() - tail; ++i) add("removed", a[i]);
  for (qsizetype i = head; i < b.size() - tail; ++i) add("added", b[i]);
  for (qsizetype i = a.size() - tail; i < std::min(a.size(), a.size() - tail + 2); ++i) add("context", a[i]);
  return diff;
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

void SnapShotController::setConfigTools(const std::optional<CaptureShortcutConfig::Tools>& tools) {
  configTools() = tools;
}

SnapShotController::~SnapShotController() {
  m_active = false;
  if (m_configThread) m_configThread->wait();
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
    connect(m_backend, &SnapShotBackend::setupFailed, this, &SnapShotController::onSetupFailed);
    connect(m_backend, &SnapShotBackend::tested, this, &SnapShotController::onTested);
  }
  if (auto* settings = NativeShell::of(this)->controller<SettingsController>()) {
    connect(settings, &SettingsController::deviceChanged, this, &SnapShotController::follow, Qt::UniqueConnection);
  }
  // The user may have changed capture access or the shortcut while away.
  connect(qGuiApp, &QGuiApplication::applicationStateChanged, this, &SnapShotController::onApplicationState, Qt::UniqueConnection);
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
  if (const auto setup = m_backend->setup()) return setup->accessReady;
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
  m_backend->setIncludeAccessibility(includeAccessibility());
  if (enabled() || panelOpen() || !setting(kResume).toString().isEmpty()) m_backend->probe();
  resumeSetup();
  // Leaving the panel ends recording, and with it the pause on captures.
  if (m_recording && !panelOpen()) stopRecording();
  applyShortcut();
  publish();
}

void SnapShotController::applyShortcut() {
  m_backend->setCues(setting(QStringLiteral("snapShotFlash")).toBool(), setting(QStringLiteral("snapShotAnimations")).toBool());
  QString trigger;
  QString problem;
  // Niri's shortcut is a binding in its config. Hyprland's is too, but it
  // reaches HAL-C2 through the portal session this opens.
  const QString mode = m_backend->session().mode;
  const QString desktop = managed() ? m_backend->session().desktop : QString();
  if (enabled() && mode == QLatin1String("portal") && desktop != QLatin1String("niri")) {
    trigger = SnapShotBackend::portalTrigger(savedShortcut(), &problem);
    // The keys live in Hyprland's config; the session only has to exist, and
    // modifier pair or not, the portal needs a trigger to open it.
    if (trigger.isEmpty() && desktop == QLatin1String("hyprland")) {
      trigger = QStringLiteral("CTRL+SHIFT+2");
      problem.clear();
    }
  } else if (enabled() && mode != QLatin1String("unavailable") && desktop != QLatin1String("niri")) {
    trigger = m_backend->trigger(savedShortcut(), &problem);
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
  // Permissions and the test capture come first, every time.
  if (!accessReady() || m_backend->session().permissions) return kAccess;
  if (requested == kAccess || requested == kShortcutStep) return requested;
  return m_backend->session().backend == QLatin1String("picker") ? kAccess : kShortcutStep;
}

void SnapShotController::openSetup(const QString& requested) {
  // A desktop without capture has nothing to set up.
  if (!m_backend->session().ready || m_backend->session().mode == QLatin1String("unavailable")) return;
  // Nor does one that needs no setup: opening it turns capture on.
  if (m_backend->session().setupFree) {
    if (!enabled()) set(QStringLiteral("snapShotEnabled"), true);
    publish();
    return;
  }
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
  set(kResume, QString());
  m_flow = {};
  // A shortcut in the compositor's config is only ever a proposal for this setup.
  if (managed()) resetCandidate();
  if (enabled() && !wasEnabled && !completed) set(QStringLiteral("snapShotEnabled"), false);
  publish();
}

bool SnapShotController::includeAccessibility() const {
  return setting(QStringLiteral("snapShotIncludeAccessibility")).toBool();
}

bool SnapShotController::permissionsReady() const {
  const auto session = m_backend->session();
  return session.permissions && session.permissionsError.isEmpty() && session.permissions->screenRecording &&
         (!includeAccessibility() || session.permissions->accessibility);
}

// macOS can quit the app from its permission prompt.
void SnapShotController::saveResume() {
  if (m_wizard) set(kResume, m_wizard->wasEnabled ? QStringLiteral("enabled") : QStringLiteral("disabled"));
}

void SnapShotController::resumeSetup() {
  const auto session = m_backend->session();
  if (!m_resumeChecked && session.ready) {
    // Once per start, so opening System Settings cannot redirect later.
    m_resumeChecked = true;
    const QString resume = setting(kResume).toString();
    if (!resume.isEmpty() && session.permissions && !m_wizard) {
      m_wizard = Wizard{kAccess, resume == QLatin1String("enabled")};
      m_resumeShown = false;
    }
  }
  // The window may come after the answer.
  if (m_resumeShown) return;
  if (auto* navigation = NativeShell::of(this)->controller<NavigationController>()) {
    m_resumeShown = true;
    navigation->open(NavigationController::Route::settings(kSection));
  }
}

void SnapShotController::stopRecording() {
  m_held.clear();
  if (!std::exchange(m_recording, false)) return;
  m_backend->pause(false, nullptr);
  // Recording cleared the check; the shortcut recorded before it can still be saved.
  checkCandidate();
}

void SnapShotController::resetCandidate() {
  m_candidate.reset();
  ++m_checkId;
  m_checking = false;
  m_check.reset();
}

bool SnapShotController::busy() const {
  return m_wizard && m_backend->session().checking;
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

// SnapShotSettings' checkShortcut: HAL-C2's own keybindings first, then the
// system's, then the desktop (DesktopSnapShot.checkShortcut).
void SnapShotController::checkCandidate() {
  const quint64 id = ++m_checkId;
  m_checking = false;
  m_check.reset();
  if (m_candidate && managed()) {
    QString problem;
    m_check = CaptureShortcutConfig::keys(label(*m_candidate), &problem)
                  ? Check{false, m_backend->session().desktop == QLatin1String("niri")
                                     ? tr("Configure the capture shortcut in your Niri config, not in HAL-C2.")
                                     : tr("Change the capture binding in your Hyprland config, then save it.")}
                  : Check{false, problem};
    return;
  }
  if (!shortcutChanged() || !conflict(*m_candidate).isEmpty()) return;
  if (!isPair(*m_candidate)) {
    if (const QString reserved = systemConflict(chordOf(*m_candidate)); !reserved.isEmpty()) {
      m_check = Check{false, reserved};
      return;
    }
  }
  m_checking = true;
  m_backend->checkShortcut(*m_candidate, [this, guard = QPointer<SnapShotController>(this), id](const Check& answer) {
    if (!guard || id != m_checkId) return;
    m_checking = false;
    m_check = answer;
    if (!answer.available && answer.message.isEmpty()) m_check->message = tr("Could not check this shortcut.");
    publish();
  });
}

void SnapShotController::record(const QJsonObject& shortcut) {
  m_candidate = shortcut;
  // A review is of the keys it was prepared for.
  withdrawReview();
  stopRecording();
  publish();
}

bool SnapShotController::shortcutChanged() const {
  return !managed() && m_candidate && *m_candidate != savedShortcut();
}

bool SnapShotController::canSave() const {
  return shortcutChanged() && conflict(*m_candidate).isEmpty() && m_check && m_check->available;
}

QString SnapShotController::shortcutStatus() const {
  // The web hides a refused modifier pair behind this while it records; the
  // refusal shows here, where the user can see why nothing was recorded.
  if (m_recording) return m_check ? m_check->message : tr("Press your shortcut. Esc cancels.");
  if (managed() && !m_check) return m_backend->shortcut().message;
  if (shortcutChanged()) {
    if (const QString command = conflict(*m_candidate); !command.isEmpty()) {
      return tr("HAL-C2 already uses this for \"%1\".").arg(keybindings::commandLabel(command));
    }
  }
  if (m_checking) return tr("Checking shortcut…");
  // A direct backend's word on a free shortcut is worth reading (it may only
  // be observed); the portal's only promises what saving will do.
  if (m_check) {
    if (!m_check->available) return m_check->message;
    return m_backend->session().mode == QLatin1String("direct") && !m_check->message.isEmpty() ? m_check->message : tr("Ready to save.");
  }
  const auto session = m_backend->session();
  const auto shortcut = m_backend->shortcut();
  const QJsonObject display = shortcutChanged() ? *m_candidate : savedShortcut();
  if (session.mode == QLatin1String("portal") && shortcut.label.isEmpty() && isPair(display)) {
    return tr("Try a shortcut such as Ctrl+Shift+2.");
  }
  if (!m_shortcutProblem.isEmpty()) return m_shortcutProblem;
  if (shortcut.pending) return tr("Approve the shortcut permission prompt to continue.");
  if (shortcut.registered) {
    return session.mode == QLatin1String("portal") || !shortcut.message.isEmpty() ? shortcut.message : tr("Shortcut saved.");
  }
  return shortcut.message;
}

// --- Actions ----------------------------------------------------------------------

bool SnapShotController::handle(const QString& action, const QVariant& payload) {
  if (!action.startsWith(QLatin1String("snapShot."))) return false;
  if (!m_backend) return true;
  const QVariantMap map = payload.toMap();

  // Setup waits on the desktop before it can be left or stepped through.
  if (busy() && (action.startsWith(QLatin1String("snapShot.setup.")) || action == QLatin1String("snapShot.enable") ||
                 action == QLatin1String("snapShot.record.start"))) {
    return true;
  }
  if (action == QLatin1String("snapShot.enable")) {
    if (map.value(QStringLiteral("on")).toBool()) {
      openSetup(QStringLiteral("resume"));
    } else {
      stopRecording();
      m_wizard.reset();
      set(kResume, QString());
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
    if (!m_wizard || m_testing) return true;
    if (m_backend->session().permissions) {
      if (!permissionsReady()) return true;
      saveResume();
      m_wizard->error.clear();
      m_testing = true;
      publish();
      m_backend->test();
      return true;
    }
    const auto setup = m_backend->setup();
    const bool retry = setup ? !setup->accessReady : !m_backend->session().message.isEmpty();
    m_wizard->error.clear();
    if (!enabled() || retry) set(QStringLiteral("snapShotEnabled"), true);
    // Try again: the desktop is asked once more, and setup moves on once it answers.
    m_wizard->checked = retry;
    if (retry) m_backend->refresh();
    if (accessReady()) {
      stopRecording();
      m_wizard->step = kShortcutStep;
    }
    publish();
    return true;
  }
  if (action == QLatin1String("snapShot.setup.action")) {
    // Only a step the user chose: checking access never installs anything.
    if (m_wizard) {
      m_wizard->error.clear();
      m_wizard->checked = false;
    }
    publish();
    m_backend->perform(map.value(QStringLiteral("action")).toString());
    return true;
  }
  if (action == QLatin1String("snapShot.permission.allow")) {
    if (!m_wizard || m_testing) return true;
    saveResume();
    m_backend->allow(map.value(QStringLiteral("id")).toString());
    publish();
    return true;
  }
  if (action == QLatin1String("snapShot.setup.back")) {
    if (!m_wizard || m_testing) return true;
    stopRecording();
    m_wizard->step = kAccess;
    publish();
    return true;
  }
  if (action == QLatin1String("snapShot.setup.close")) {
    if (m_testing) return true;
    closeSetup(map.value(QStringLiteral("completed")).toBool());
    return true;
  }
  if (action == QLatin1String("snapShot.config.review")) {
    review(map.value(QStringLiteral("remove")).toBool(), map.value(QStringLiteral("file")).toString());
    return true;
  }
  if (action == QLatin1String("snapShot.config.save")) {
    saveReview(map.value(QStringLiteral("id")).toString());
    return true;
  }
  if (action == QLatin1String("snapShot.config.cancel")) {
    withdrawReview();
    m_flow.error.clear();
    m_flow.details.clear();
    publish();
    return true;
  }
  if (action == QLatin1String("snapShot.config.copy")) {
    if (!managed()) return true;
    QGuiApplication::clipboard()->setText(binding());
    m_flow.copied = true;
    publish();
    return true;
  }
  if (action == QLatin1String("snapShot.config.complete")) {
    if (managed()) closeSetup(true);
    return true;
  }
  if (action == QLatin1String("snapShot.setup.done")) {
    if (!m_wizard || !accessReady()) return true;
    if (managed()) {
      if (m_flow.saved || (m_flow.preview && m_flow.preview->before == m_flow.preview->after)) closeSetup(true);
      return true;
    }
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
    m_held.clear();
    ++m_checkId;
    m_checking = false;
    m_check.reset();
    // The capture shortcut must not fire while its replacement is pressed.
    QString reason;
    if (m_recording || m_backend->pause(true, &reason)) {
      m_recording = true;
    } else {
      m_check = Check{false, reason.isEmpty() ? tr("Could not start shortcut recording.") : reason};
    }
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
    const int modifiers = map.value(QStringLiteral("modifiers")).toInt();
    // A held key repeats, and a plain Tab moves focus on: neither is a shortcut.
    if (map.value(QStringLiteral("repeat")).toBool()) return true;
    if ((key == Qt::Key_Tab || key == Qt::Key_Backtab) && !(modifiers & (Qt::ControlModifier | Qt::AltModifier | Qt::MetaModifier))) {
      return true;
    }
    if (key == Qt::Key_Escape) {
      stopRecording();
      publish();
      return true;
    }
    const QString recorded = keybindings::recordedKey(key, modifiers, mac());
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
    // A desktop that gives only a screenshot has no app text to include.
    if (key.isEmpty() || !m_backend->session().appText && key == QLatin1String("snapShotIncludeAccessibility")) {
      return true;
    }
    if (key == QLatin1String("snapShotIncludeAccessibility") && map.value(QStringLiteral("value")).toBool() && enabled() &&
        m_backend->session().permissions) {
      if (const QString refused = m_backend->requestPermissions(true); !refused.isEmpty()) {
        const QString title = tr("Couldn't allow app text capture");
        if (m_wizard) m_wizard->error = title + u'.' + u' ' + refused;
        else if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) toasts->error(title, refused);
        publish();
        return true;
      }
    }
    set(key, map.value(QStringLiteral("value")).toBool());
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

// --- The compositor's config ------------------------------------------------------

bool SnapShotController::managed() const {
  if (!m_backend) return false;
  // A sandbox can neither reach the compositor's config nor answer its binding.
  const QProcessEnvironment env = SnapShotBackend::environment();
  if (env.contains(QStringLiteral("FLATPAK_ID")) || env.contains(QStringLiteral("SNAP"))) return false;
  const QString desktop = m_backend->session().desktop;
  return m_backend->session().mode == QLatin1String("portal") && (desktop == QLatin1String("niri") || desktop == QLatin1String("hyprland"));
}

CaptureShortcutConfig::Target SnapShotController::configTarget() const {
  const QProcessEnvironment env = SnapShotBackend::environment();
  const QString desktop = m_backend->session().desktop;
  const QString standard = desktop == QLatin1String("niri") ? CaptureShortcutConfig::niriConfigPath(env) : CaptureShortcutConfig::hyprlandConfigPath(env);
  const QString appId = QGuiApplication::desktopFileName();
  return {desktop, m_flow.file.isEmpty() ? standard : m_flow.file, appId.isEmpty() ? QStringLiteral("hal-c2") : appId};
}

QString SnapShotController::binding() const {
  const auto target = configTarget();
  const auto format = target.desktop == QLatin1String("niri") ? CaptureShortcutConfig::Format::Niri
                      : target.path.endsWith(QLatin1String(".lua")) ? CaptureShortcutConfig::Format::HyprlandLua
                                                                    : CaptureShortcutConfig::Format::Hyprland;
  QString keys = m_flow.preview ? m_flow.preview->shortcut : m_candidate ? label(*m_candidate) : QStringLiteral("Ctrl+Shift+2");
  QString ignored;
  if (!CaptureShortcutConfig::keys(keys, &ignored)) keys = QStringLiteral("Ctrl+Shift+2");
  return CaptureShortcutConfig::binding(format, target.appId, keys);
}

bool SnapShotController::runConfig(std::function<void()> work, std::function<void()> done) {
  if (m_configThread) return false;
  if (!m_config) {
    m_config = std::make_unique<CaptureShortcutConfig>(CaptureShortcutConfig::home(SnapShotBackend::environment()),
                                                       configTools().value_or(CaptureShortcutConfig::systemTools()));
  }
  m_configThread = QThread::create(std::move(work));
  connect(m_configThread, &QThread::finished, this, [this, done = std::move(done)] {
    m_configThread->deleteLater();
    m_configThread = nullptr;
    done();
    publish();
  });
  m_configThread->start();
  return true;
}

void SnapShotController::review(bool remove, const QString& file) {
  if (!managed()) {
    m_flow.error = tr("Couldn't prepare the changes. Check Advanced for help.");
    m_flow.details = tr("Config setup requires a Niri or Hyprland session.");
    publish();
    return;
  }
  if (m_configThread) {
    m_flow.details = tr("Wait for the current config change to finish.");
    m_flow.error = tr("Couldn't prepare the changes. Check Advanced for help.");
    publish();
    return;
  }
  stopRecording();
  if (!file.isEmpty()) m_flow.file = file;
  const QString chosen = m_flow.file;
  m_flow = {};
  m_flow.file = chosen;
  m_flow.preparing = true;
  m_flow.removing = remove;
  const auto target = configTarget();
  const QString keys = !remove && m_candidate ? label(*m_candidate) : QString();
  auto preview = std::make_shared<std::optional<CaptureShortcutConfig::Preview>>();
  auto reason = std::make_shared<QString>();
  // The config is made on the first run, so it is the thread's to read then.
  runConfig([this, target, remove, keys, preview, reason] { *preview = m_config->preview(target, !remove, keys, reason.get()); },
            [this, preview, reason] {
              m_flow.preparing = false;
              m_flow.preview = *preview;
              if (!*preview) {
                m_flow.error = tr("Couldn't prepare the changes. Check Advanced for help.");
                m_flow.details = *reason;
              }
            });
  publish();
}

void SnapShotController::saveReview(const QString& id) {
  if (!managed() || !m_flow.preview || m_configThread) return;
  if (m_flow.preview->before == m_flow.preview->after) return;
  // Hyprland's binding does nothing until the portal session that serves it is up.
  const auto shortcut = m_backend->shortcut();
  if (m_flow.preview->install && !shortcut.registered && (m_backend->session().desktop == QLatin1String("hyprland") || !shortcut.message.isEmpty())) {
    return;
  }
  m_flow.saving = true;
  m_flow.error.clear();
  m_flow.details.clear();
  const QString reviewed = id.isEmpty() ? m_flow.preview->id : id;
  const QString desktop = m_backend->session().desktop;
  auto applied = std::make_shared<std::optional<CaptureShortcutConfig::Applied>>();
  auto reason = std::make_shared<QString>();
  runConfig([this, reviewed, desktop, applied, reason] { *applied = m_config->apply(reviewed, desktop, reason.get()); },
            [this, applied, reason] {
              const auto preview = std::exchange(m_flow.preview, std::nullopt);
              m_flow.saving = false;
              if (!*applied) {
                m_flow.error = tr("Couldn't save your shortcut. Review the changes and try again.");
                m_flow.details = *reason;
                return;
              }
              m_flow.backup = (*applied)->backupPath;
              if (preview->install && m_candidate) set(QStringLiteral("snapShotShortcut"), m_candidate->toVariantMap());
              if (!(*applied)->warning.isEmpty()) {
                m_flow.result = tr("Saved, but the shortcut needs attention. Check Advanced for help.");
                m_flow.details = (*applied)->warning;
                return;
              }
              if (!preview->install) {
                m_flow.result = tr("Shortcut removed.");
                m_flow.saved = true;
                return;
              }
              NativeWindow* window = NativeShell::of(this);
              if (auto* toasts = window ? window->controller<ToastController>() : nullptr) {
                toasts->show(QStringLiteral("success"), tr("Shortcut saved"), tr("Use %1 from another app.").arg(preview->shortcut));
              }
              closeSetup(true);
            });
  publish();
}

void SnapShotController::withdrawReview() {
  m_flow.preview.reset();
  m_flow.result.clear();
  m_flow.saved = false;
  m_flow.copied = false;
}

QVariant SnapShotController::configState() const {
  if (!managed()) return {};
  const auto session = m_backend->session();
  const auto shortcut = m_backend->shortcut();
  const bool niri = session.desktop == QLatin1String("niri");
  const auto target = configTarget();
  const bool busy = m_flow.preparing || m_flow.saving;
  const auto& preview = m_flow.preview;
  QString connecting;
  if (!niri && !shortcut.registered) {
    connecting = shortcut.message.isEmpty() ? tr("Connecting to your desktop…") : tr("Restart HAL-C2 to finish connecting your shortcut.");
  }
  const bool unconnected = !shortcut.registered && (!niri || !shortcut.message.isEmpty());

  QString intro = tr("Allow HAL-C2 to read your desktop settings. You'll review any changes here before saving.");
  if (preview) {
    const bool same = preview->before == preview->after;
    intro = same ? (preview->install ? tr("This shortcut is already set up.") : tr("There's no capture shortcut to remove."))
                 : (preview->install ? tr("Review the change below, then save your shortcut.") : tr("Review the change below to remove your shortcut."));
  }
  if (!m_flow.result.isEmpty()) intro = m_flow.result;

  QVariant reviewed;
  if (preview) {
    const bool same = preview->before == preview->after;
    const bool linked = !preview->resolvedPath.isEmpty() && preview->resolvedPath != preview->path;
    reviewed = QVariantMap{
        {QStringLiteral("id"), preview->id},
        {QStringLiteral("changed"), !same},
        {QStringLiteral("install"), preview->install},
        {QStringLiteral("shortcut"), preview->shortcut},
        {QStringLiteral("note"), same ? QString() : tr("Only these changes will be saved. We'll keep a backup.")},
        {QStringLiteral("lines"), same ? QVariantList() : diffLines(preview->before, preview->after)},
        {QStringLiteral("saveLabel"), m_flow.saving ? tr("Saving…") : preview->install ? tr("Save shortcut") : tr("Remove shortcut")},
        {QStringLiteral("canSave"), !same && !busy && (!preview->install || !unconnected)},
        {QStringLiteral("linked"), linked ? tr("Linked to %1. The link will be kept.").arg(preview->resolvedPath) : QString()},
    };
  }
  return QVariantMap{
      {QStringLiteral("intro"), intro},
      {QStringLiteral("reviewLabel"), m_flow.preparing ? tr("Preparing changes…") : tr("Review changes")},
      {QStringLiteral("canReview"), !busy && !preview},
      {QStringLiteral("review"), reviewed},
      {QStringLiteral("connecting"), connecting},
      {QStringLiteral("error"), m_flow.error},
      {QStringLiteral("details"), m_flow.details},
      {QStringLiteral("backup"), m_flow.backup.isEmpty() ? QString() : tr("Backup: %1").arg(m_flow.backup)},
      {QStringLiteral("file"), preview ? preview->path : target.path},
      {QStringLiteral("fileHint"), niri ? tr("HAL-C2 also reads any files included by this file.") : tr("On Omarchy, use your own bindings file, not its defaults.")},
      {QStringLiteral("binding"), binding()},
      {QStringLiteral("manual"), niri ? tr("Paste this inside binds { … } in your Niri config, then save. Change the keys if needed.")
                                      : tr("Add this binding to your Hyprland config, then save. Change the keys if needed.")},
      {QStringLiteral("copyLabel"), m_flow.copied ? tr("Copied") : tr("Copy shortcut")},
      {QStringLiteral("removeNote"), tr("Turn capture off in HAL-C2 to stop it. Remove the shortcut from %1 to free up the keys.").arg(niri ? QStringLiteral("Niri") : QStringLiteral("Hyprland"))},
  };
}

// --- Capturing --------------------------------------------------------------------

void SnapShotController::onApplicationState(Qt::ApplicationState state) {
  if (m_active && m_backend && state == Qt::ApplicationActive && (enabled() || panelOpen())) m_backend->refresh();
}

void SnapShotController::onActivated() {
  // Recording a shortcut suppresses the one held.
  if (m_recording || !enabled()) return;
  m_backend->setEffects(setting(QStringLiteral("snapShotFlash")).toBool(), setting(QStringLiteral("snapShotAnimations")).toBool());
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

// The test image is the backend's to throw away; only the answer comes here.
void SnapShotController::onTested(const QString& error) {
  if (!m_testing) return;
  m_testing = false;
  if (!m_wizard) return publish();
  if (!error.isEmpty()) {
    m_wizard->error = tr("Couldn't verify capture access. %1").arg(error);
    return publish();
  }
  m_backend->requestPermissions(includeAccessibility());
  if (!enabled()) set(QStringLiteral("snapShotEnabled"), true);
  if (accessReady()) {
    stopRecording();
    m_wizard->step = kShortcutStep;
  }
  publish();
}

void SnapShotController::onCaptured(const QImage& image, const QString& appName, const QString& windowTitle, const QJsonObject& context) {
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
  QJsonObject source{{QStringLiteral("kind"), QStringLiteral("snap-shot")},
                     {QStringLiteral("capturedAt"), capturedAt},
                     {QStringLiteral("appName"), appName.trimmed().isEmpty() ? QStringLiteral("Window") : appName.trimmed()},
                     {QStringLiteral("windowTitle"), windowTitle.trimmed()}};
  if (includeAccessibility()) {
    for (auto it = context.begin(); it != context.end(); ++it) source.insert(it.key(), it.value());
  }
  if (auto* composer = window->controller<ComposerController>()) composer->attachImage(to, name, mimeType, *bytes, source);
  window->bridge()->windowCommand(QStringLiteral("raise"));
  window->bridge()->sendToBricks(QStringLiteral("composer.focus"));
}

void SnapShotController::onSetupFailed(const QString& message) {
  // Setup errors stay in setup; without it open, the panel has nowhere else.
  if (!m_wizard) {
    onFailed(message);
    return;
  }
  m_wizard->error = message;
  publish();
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
  // A data URL's budget, in bytes.
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
  // A permission can change in System Settings while setup or the panel shows
  // it, and one granted again brings the shortcut back without a restart.
  m_backend->watchPermissions(!m_testing && ((m_wizard && m_wizard->step == kAccess) ||
                                             (enabled() && (panelOpen() || !m_backend->session().message.isEmpty()))));
  const QVariantMap next = state();
  if (next == m_published) return;
  m_published = next;
  m_bridge->publish(QStringLiteral("snapShot"), next);
}

QVariantMap SnapShotController::state() const {
  const auto session = m_backend->session();
  const auto shortcut = m_backend->shortcut();
  const auto setup = m_backend->setup();
  const bool on = enabled();
  const bool portal = session.mode == QLatin1String("portal");
  const bool available = session.ready && session.mode != QLatin1String("unavailable");
  const bool picker = portal && session.backend == QLatin1String("picker");
  const bool ready = accessReady();
  const QString desktop = portal ? desktopName(session.desktop) : QString();
  const QJsonObject saved = savedShortcut();
  const bool changed = shortcutChanged();
  const bool inConfig = managed();
  const QJsonObject display = changed || (inConfig && m_candidate) ? *m_candidate : saved;

  // snapShotStatus
  QString status;
  if (!session.ready) status = tr("Checking snapshots…");
  else if (!available) status = session.message.isEmpty() ? tr("Not supported on this platform.") : session.message;
  else if (!on) status = tr("Turn this on to set up snapshots.");
  else if (!session.message.isEmpty()) status = tr("Capture needs attention");
  else if (setup && !setup->accessReady && !setup->status.isEmpty()) status = setup->status;
  else if (picker) status = tr("Manual capture only — you'll choose a window each time");
  else if (managed() && shortcut.registered) status = tr("Use your shortcut from another app");
  else if (shortcut.pending) status = tr("Waiting for shortcut permission");
  else if (shortcut.registered) status = shortcut.label.isEmpty() ? tr("Shortcut saved") : tr("Ready to capture");
  else status = tr("Finish shortcut setup");

  QString setupLabel;
  // macOS hides setup once there is nothing left to do in it.
  const bool complete = session.permissions && ready && permissionsReady() && shortcut.registered;
  if (on && session.ready && !session.setupFree && !complete) {
    // The button is short: "Set up KDE capture".
    const QString name = session.desktop == QLatin1String("kde") ? QStringLiteral("KDE") : desktop;
    setupLabel = ready ? tr("Manage capture") : name.isEmpty() ? tr("Continue setup") : tr("Set up %1 capture").arg(name);
  }

  QString keys;
  if (m_recording) keys = tr("Press shortcut…");
  else if (inConfig && !m_wizard) keys = tr("Change shortcut");
  else if (!isPair(display) && display.value(QLatin1String("key")).toString().isEmpty()) keys = tr("Change shortcut");
  else if (portal && isPair(display)) keys = tr("Choose shortcut");
  else if (!changed && !shortcut.label.isEmpty()) keys = shortcut.label;
  else keys = label(display);

  const bool canRetry = shortcut.canRetry && !isPair(saved) && !inConfig;
  const QString effects = setup && !setup->effects.isEmpty() ? setup->effects
                          : portal && !session.feedbackAvailable
                              ? (session.desktop == QLatin1String("niri") ? tr("Capture effects aren't available on Niri.")
                                                                          : tr("Capture effects aren't available on this desktop."))
                              : QString();
  const QString screenshotOnly = available && !session.appText ? tr("This desktop only provides a screenshot.") : QString();
  const auto toggle = [&](const char* key, const QString& unavailable) {
    return QVariantMap{{QStringLiteral("checked"), unavailable.isEmpty() && setting(QLatin1String(key)).toBool()},
                       {QStringLiteral("enabled"), available && unavailable.isEmpty()},
                       {QStringLiteral("status"), unavailable}};
  };
  const QString sound =
      setting(QStringLiteral("snapShotPlaySound")).toBool() ? setting(QStringLiteral("snapShotSound")).toString() : QStringLiteral("off");
  const QVariantList sounds{QVariantMap{{QStringLiteral("value"), QStringLiteral("off")}, {QStringLiteral("label"), tr("Off")}},
                            QVariantMap{{QStringLiteral("value"), QStringLiteral("soft-pop")}, {QStringLiteral("label"), tr("Whoosh (Default)")}},
                            QVariantMap{{QStringLiteral("value"), QStringLiteral("camera-shutter")}, {QStringLiteral("label"), tr("Click")}}};
  QString soundLabel;
  for (const QVariant& choice : sounds) {
    if (choice.toMap().value(QStringLiteral("value")) == sound) soundLabel = choice.toMap().value(QStringLiteral("label")).toString();
  }

  QVariant wizard;
  if (m_wizard) {
    const bool access = m_wizard->step == kAccess;
    QString heading;
    QString body;
    if (access && setup) {
      heading = setup->heading;
      body = setup->body;
    } else if (access) {
      if (session.permissions) {
        heading = tr("Allow snapshots");
        body = permissionsReady() ? tr("Test a snapshot of the current window. If macOS asks to bypass its window picker, choose Allow. The test "
                                       "image is discarded.")
                                  : tr("Allow each permission, then continue.");
      } else if (!session.message.isEmpty()) {
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
      body = m_recording ? tr("Click the shortcut, then press the keys you want.")
             : portal    ? tr("Choose your keys, then approve the permission prompt if asked.")
                         : tr("Use both Shift keys, or record a different shortcut.");
    }
    QVariantList advanced;
    if (access && setup) {
      for (const auto& option : setup->advanced) {
        advanced.append(QVariantMap{{QStringLiteral("action"), option.action},
                                    {QStringLiteral("label"), option.label},
                                    {QStringLiteral("note"), option.note}});
      }
    }
    QVariantList permissionRows;
    if (session.permissions) {
      const bool text = includeAccessibility();
      permissionRows = {QVariantMap{{QStringLiteral("id"), QStringLiteral("screen-recording")},
                                    {QStringLiteral("title"), tr("Screen Recording")},
                                    {QStringLiteral("description"), tr("Capture the window you're using.")},
                                    {QStringLiteral("required"), true},
                                    {QStringLiteral("granted"), session.permissions->screenRecording}},
                        QVariantMap{{QStringLiteral("id"), QStringLiteral("accessibility")},
                                    {QStringLiteral("title"), tr("Accessibility")},
                                    {QStringLiteral("description"), text ? tr("Include text and controls from the captured app.")
                                                                         : tr("Optional. Include text and controls from the captured app.")},
                                    {QStringLiteral("required"), text},
                                    {QStringLiteral("granted"), session.permissions->accessibility}}};
    }
    const QString continueLabel = m_testing            ? tr("Working…")
                                  : busy()              ? tr("Checking…")
                                  : session.permissions ? tr("Test capture and continue")
                                  : setup && !setup->actionLabel.isEmpty() ? setup->actionLabel
                                  : ready               ? tr("Continue")
                                                        : tr("Try again");
    wizard = QVariantMap{
        {QStringLiteral("step"), m_wizard->step},
        {QStringLiteral("busy"), busy()},
        {QStringLiteral("permissionRows"), permissionRows},
        {QStringLiteral("permissionsBusy"), m_testing},
        {QStringLiteral("permissionsError"), session.permissionsError},
        {QStringLiteral("continueEnabled"), !m_testing && (!session.permissions || permissionsReady())},
        {QStringLiteral("title"), desktop.isEmpty() ? tr("Set up snapshots") : tr("Set up snapshots for %1").arg(desktop)},
        {QStringLiteral("heading"), heading},
        {QStringLiteral("body"), body},
        {QStringLiteral("details"), !m_wizard->error.isEmpty() ? m_wizard->error
                                    : !access || session.permissions ? QString()
                                    : setup ? setup->details
                                            : session.message},
        // The access step's own button runs this setup step, else checks again or continues.
        {QStringLiteral("action"), access && setup ? setup->action : QString()},
        {QStringLiteral("checkMessage"), access && setup && m_wizard->checked && !busy() ? setup->checkMessage : QString()},
        {QStringLiteral("advanced"), advanced},
        {QStringLiteral("attention"), !access && !ready ? tr("Capture needs attention. Go back to check access.") : QString()},
        {QStringLiteral("closeLabel"), m_wizard->wasEnabled ? tr("Close") : tr("Finish later")},
        {QStringLiteral("continueLabel"), continueLabel},
        {QStringLiteral("doneLabel"), changed ? tr("Save and finish") : tr("Done")},
        {QStringLiteral("doneEnabled"), ready && (inConfig ? m_flow.saved || (m_flow.preview && m_flow.preview->before == m_flow.preview->after)
                                                  : changed ? canSave() : shortcut.registered || shortcut.pending)},
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
       QVariantMap{{QStringLiteral("managed"), inConfig},
                   {QStringLiteral("description"), picker ? tr("Choose a window to capture from any app.")
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
       QVariantMap{{QStringLiteral("value"), sound}, {QStringLiteral("label"), soundLabel}, {QStringLiteral("choices"), sounds}}},
      {QStringLiteral("flash"), toggle("snapShotFlash", effects)},
      {QStringLiteral("animations"), toggle("snapShotAnimations", effects)},
      {QStringLiteral("wizard"), wizard},
      {QStringLiteral("config"), configState()},
  };
}
