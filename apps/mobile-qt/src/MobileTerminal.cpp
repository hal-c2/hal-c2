#include "MobileTerminal.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QPointer>
#include <QQmlPropertyMap>
#include <QQuickItem>
#include <QRegularExpression>
#include <QSaveFile>
#include <QWheelEvent>

#include <algorithm>
#include <cmath>
#include <optional>
#include <utility>

#include "McClient.h"
#include "MenuController.h"
#include "NativeShell.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "TerminalController.h"
#include "ToastController.h"

namespace mobileterminal {

QString withControl(const QString& data) {
  if (data.isEmpty()) return data;
  const QChar first = data.at(0).toLower();
  if (first >= QLatin1Char('a') && first <= QLatin1Char('z')) return QString(QChar(first.unicode() - 96));
  switch (first.unicode()) {
    case '@': return QString(QChar(0));
    case '[': return QString(QChar(0x1b));
    case '\\': return QString(QChar(0x1c));
    case ']': return QString(QChar(0x1d));
    case '^': return QString(QChar(0x1e));
    case '_': return QString(QChar(0x1f));
    case '?': return QString(QChar(0x7f));
    default: return data;
  }
}

QString forPaste(const QString& text) {
  static const QRegularExpression hidden(QStringLiteral("[\\x{0}-\\x{8}\\x{b}\\x{c}\\x{e}-\\x{1f}\\x{7f}]"));
  static const QRegularExpression newlines(QStringLiteral("\\r\\n|\\n"));
  QString pasted = text;
  pasted.replace(hidden, QStringLiteral(" "));
  pasted.replace(newlines, QStringLiteral("\r"));
  return pasted;
}

QString statusLabel(const QString& status, bool busy) {
  if (status == QLatin1String("running")) return busy ? QStringLiteral("Task running") : QStringLiteral("Ready");
  if (status == QLatin1String("starting")) return QStringLiteral("Starting");
  if (status == QLatin1String("exited")) return QStringLiteral("Exited");
  if (status == QLatin1String("error")) return QStringLiteral("Error");
  return QStringLiteral("Not started");
}

}  // namespace mobileterminal

namespace {

const QString kKey = QStringLiteral("mobileTerminal");

using namespace mobileterminal;

// The last folder of a path.
QString folderName(const QString& path) {
  return QFileInfo(QDir::cleanPath(path)).fileName();
}

bool oneCharacter(const QString& data) {
  return data.size() == 1 || (data.size() == 2 && data.at(0).isHighSurrogate());
}

}  // namespace

MobileTerminal::MobileTerminal(ShellBridge* bridge, NativeShell* native, const QString& storePath)
    : QObject(), m_bridge(bridge), m_native(native), m_storePath(storePath) {
  bridge->declareKey(kKey);
  QFile file(storePath);
  if (file.open(QIODevice::ReadOnly)) {
    const double stored = QJsonDocument::fromJson(file.readAll()).object().value(QLatin1String("textSize")).toDouble(kDefaultTextSize);
    m_textSize = std::clamp(stored, kMinTextSize, kMaxTextSize);
  }
  bridge->addInterceptor([self = QPointer(this)](const QString& action, const QVariant& payload) {
    return self && self->handle(action, payload);
  });
  connect(native->controller<TerminalController>(), &TerminalController::changed, this, &MobileTerminal::publish);
  publish();
}

bool MobileTerminal::handle(const QString& action, const QVariant& payload) {
  if (!action.startsWith(QLatin1String("mobileTerminal."))) return false;
  const QVariantMap args = payload.toMap();
  if (action == QLatin1String("mobileTerminal.input")) {
    input(args.value(QStringLiteral("data")).toString());
  } else if (action == QLatin1String("mobileTerminal.modifier")) {
    toggleModifier(args.value(QStringLiteral("key")).toString());
  } else if (action == QLatin1String("mobileTerminal.paste")) {
    paste();
  } else if (action == QLatin1String("mobileTerminal.clear")) {
    clear();
  } else if (action == QLatin1String("mobileTerminal.covered")) {
    m_native->controller<TerminalController>()->setCovered(args.value(QStringLiteral("covered")).toBool());
  } else if (action == QLatin1String("mobileTerminal.textSize")) {
    setTextSize(args.value(QStringLiteral("points")).toDouble());
  } else if (action == QLatin1String("mobileTerminal.menu")) {
    openMenu(args);
  } else if (action == QLatin1String("mobileTerminal.context.open")) {
    openContext(args.value(QStringLiteral("lines")).toStringList());
  } else if (action == QLatin1String("mobileTerminal.context.tap")) {
    tapContextLine(args.value(QStringLiteral("index")).toInt());
  } else if (action == QLatin1String("mobileTerminal.context.attach")) {
    attachContext();
  } else if (action == QLatin1String("mobileTerminal.context.cancel")) {
    closeContext();
  }
  return true;
}

void MobileTerminal::input(const QString& data) {
  auto* terminals = m_native->controller<TerminalController>();
  TerminalSession* session = terminals->activeSession();
  // An ended shell has no session: what is typed goes nowhere.
  if (!session) return;
  if (m_held.isEmpty() || !oneCharacter(data)) {
    session->write(data);
    return;
  }
  const QString held = std::exchange(m_held, QString());
  publish();
  const QString pasteWith = hostSystem() == QLatin1String("darwin") ? QStringLiteral("cmd") : QStringLiteral("ctrl");
  if (held == pasteWith && data.compare(QLatin1String("v"), Qt::CaseInsensitive) == 0) {
    paste();
  } else if (held == QLatin1String("ctrl")) {
    session->write(withControl(data));
  } else {
    session->write(QChar(0x1b) + data);
  }
}

void MobileTerminal::toggleModifier(const QString& key) {
  m_held = m_held == key ? QString() : key;
  m_heldFor = shownTerminalId();
  publish();
}

void MobileTerminal::paste() {
  TerminalSession* session = m_native->controller<TerminalController>()->activeSession();
  if (!session) return;
  const QString text = m_bridge->clipboardText();
  if (!text.isEmpty()) session->write(forPaste(text));
}

void MobileTerminal::clear() {
  auto* terminals = m_native->controller<TerminalController>();
  if (!terminals->activeSession() || !terminals->place()) return;
  m_held.clear();
  publish();
  m_native->client()->call(this, terminals->place()->environmentId, QStringLiteral("terminal.clear"),
                           QJsonObject{{QStringLiteral("threadId"), terminals->place()->threadId},
                                       {QStringLiteral("terminalId"), terminals->activeTerminalId()}},
                           [](const QJsonValue&, const std::optional<QString>&) {});
}

void MobileTerminal::openMenu(const QVariantMap& args) {
  auto* terminals = m_native->controller<TerminalController>();
  const auto& place = terminals->place();
  if (!place) return;
  const QString root = folderName(place->cwd);
  const QString active = terminals->activeTerminalId();
  const QStringList visible = args.value(QStringLiteral("lines")).toStringList();

  QList<MenuController::Item> items;
  MenuController::Item terminalsGroup{QStringLiteral("terminals"), QStringLiteral("Terminals")};
  QVariantList listed = terminals->listing();
  for (const QVariant& value : std::as_const(listed)) {
    const QVariantMap terminal = value.toMap();
    const QString id = terminal.value(QStringLiteral("terminalId")).toString();
    const QString status = terminal.value(QStringLiteral("status")).toString();
    const bool ended = status == QLatin1String("exited") || status == QLatin1String("error");
    if (ended && id != active) continue;
    const QString cwd = terminal.value(QStringLiteral("cwd")).toString();
    MenuController::Item row{QStringLiteral("terminal:") + id, terminal.value(QStringLiteral("label")).toString(), QStringLiteral("terminal")};
    row.checked = id == active && terminals->isOpen();
    row.subtitle = QStringLiteral("%1 · %2").arg(statusLabel(status, terminal.value(QStringLiteral("busy")).toBool()), cwd.isEmpty() ? root : folderName(cwd));
    terminalsGroup.children.append(row);
  }
  if (!terminalsGroup.children.isEmpty()) items.append(terminalsGroup);

  MenuController::Item fresh{QStringLiteral("new"), QStringLiteral("Open new terminal"), QStringLiteral("plus")};
  fresh.subtitle = QStringLiteral("Start another shell in %1").arg(root.isEmpty() ? QStringLiteral("this workspace") : root);
  items.append(fresh);

  MenuController::Item scriptsGroup{QStringLiteral("scripts"), QStringLiteral("Scripts")};
  for (const QJsonValue& value : place->scripts) {
    const QJsonObject script = value.toObject();
    const QString name = script.value(QLatin1String("name")).toString();
    MenuController::Item row{QStringLiteral("script:") + script.value(QLatin1String("id")).toString(),
                             script.value(QLatin1String("runOnWorktreeCreate")).toBool() ? QStringLiteral("%1 (setup)").arg(name) : name,
                             QStringLiteral("play")};
    row.subtitle = script.value(QLatin1String("command")).toString();
    scriptsGroup.children.append(row);
  }
  if (scriptsGroup.children.isEmpty()) {
    MenuController::Item none{QStringLiteral("no-scripts"), QStringLiteral("This project has no saved scripts yet")};
    none.enabled = false;
    scriptsGroup.children.append(none);
  }
  items.append(scriptsGroup);

  if (terminals->isOpen()) {
    items.append({QStringLiteral("context"), QStringLiteral("Add visible lines to the message"), QStringLiteral("message-square-plus")});
    MenuController::Item smaller{QStringLiteral("smaller"), QStringLiteral("Smaller text (%1 pt)").arg(m_textSize, 0, 'f', 1), QStringLiteral("minus")};
    smaller.enabled = m_textSize > kMinTextSize;
    items.append(smaller);
    MenuController::Item larger{QStringLiteral("larger"), QStringLiteral("Larger text (%1 pt)").arg(m_textSize, 0, 'f', 1), QStringLiteral("plus")};
    larger.enabled = m_textSize < kMaxTextSize;
    items.append(larger);
    MenuController::Item close{QStringLiteral("close"), QStringLiteral("Close terminal"), QStringLiteral("x")};
    close.destructive = true;
    items.append(close);
  }

  const double x = args.value(QStringLiteral("x")).toDouble();
  const double y = args.value(QStringLiteral("y")).toDouble();
  m_native->controller<MenuController>()->open(x, y, items, [this, self = QPointer(this), visible](const QString& id) {
    if (!self) return;
    if (id.startsWith(QLatin1String("terminal:"))) {
      m_bridge->dispatch(QStringLiteral("terminal.select"), QVariantMap{{QStringLiteral("terminalId"), id.mid(9)}});
    } else if (id == QLatin1String("new")) {
      m_bridge->dispatch(QStringLiteral("terminal.new"));
    } else if (id.startsWith(QLatin1String("script:"))) {
      m_native->controller<TerminalController>()->runScript(id.mid(7));
    } else if (id == QLatin1String("context")) {
      openContext(visible);
    } else if (id == QLatin1String("smaller")) {
      setTextSize(m_textSize - kTextSizeStep);
    } else if (id == QLatin1String("larger")) {
      setTextSize(m_textSize + kTextSizeStep);
    } else if (id == QLatin1String("close")) {
      m_bridge->dispatch(QStringLiteral("terminal.close"));
    }
  });
}

void MobileTerminal::setTextSize(double size) {
  m_textSize = std::clamp(size, kMinTextSize, kMaxTextSize);
  publish();
  QDir().mkpath(QFileInfo(m_storePath).absolutePath());
  QSaveFile file(m_storePath);
  if (!file.open(QIODevice::WriteOnly)) return;
  file.write(QJsonDocument(QJsonObject{{QStringLiteral("textSize"), m_textSize}}).toJson(QJsonDocument::Compact));
  file.commit();
}

void MobileTerminal::openContext(const QStringList& lines) {
  auto* toasts = m_native->controller<ToastController>();
  QStringList kept = lines;
  while (!kept.isEmpty() && kept.constLast().trimmed().isEmpty()) kept.removeLast();
  if (kept.isEmpty()) {
    toasts->show(QStringLiteral("error"), QStringLiteral("No terminal output"), QStringLiteral("There is no visible output to attach."));
    return;
  }
  const QVariantMap composer = m_bridge->state()->value(QStringLiteral("composer")).toMap();
  if (composer.value(QStringLiteral("terminalContexts")).toList().size() >= kMaxContextItems) {
    toasts->show(QStringLiteral("error"), QStringLiteral("Too many context items"), QStringLiteral("Remove some context from the draft and try again."));
    return;
  }
  m_choosing = true;
  m_contextTerminal = shownTerminal();
  m_contextLines = kept;
  m_contextStart = 0;
  m_contextEnd = int(kept.size()) - 1;
  m_contextAnchor = -1;
  publish();
}

void MobileTerminal::tapContextLine(int index) {
  if (!m_choosing || index < 0 || index >= m_contextLines.size()) return;
  if (m_contextAnchor < 0) {
    m_contextAnchor = index;
    m_contextStart = m_contextEnd = index;
  } else {
    m_contextStart = std::min(m_contextAnchor, index);
    m_contextEnd = std::max(m_contextAnchor, index);
    m_contextAnchor = -1;
  }
  publish();
}

QString MobileTerminal::contextText() const {
  return m_contextLines.mid(m_contextStart, m_contextEnd - m_contextStart + 1).join(QLatin1Char('\n'));
}

void MobileTerminal::attachContext() {
  if (!m_choosing) return;
  const QString text = contextText();
  if (text.trimmed().isEmpty() || text.size() > kMaxContextChars) return;
  m_bridge->dispatch(QStringLiteral("composer.terminalContext.add"),
                     QVariantMap{{QStringLiteral("terminalId"), m_contextTerminal.value(QStringLiteral("terminalId"))},
                                 {QStringLiteral("terminalLabel"), QStringLiteral("%1 (visible output)").arg(m_contextTerminal.value(QStringLiteral("label")).toString())},
                                 {QStringLiteral("lineStart"), m_contextStart + 1},
                                 {QStringLiteral("lineEnd"), m_contextEnd + 1},
                                 {QStringLiteral("text"), text}});
  closeContext();
  // Back at the thread, where the draft is.
  if (m_native->controller<TerminalController>()->isOpen()) m_bridge->dispatch(QStringLiteral("terminal.toggle"));
}

void MobileTerminal::closeContext() {
  m_choosing = false;
  m_contextLines.clear();
  publish();
}

QString MobileTerminal::hostSystem() const {
  auto* terminals = m_native->controller<TerminalController>();
  if (!terminals->place()) return {};
  auto* store = m_native->store();
  QJsonObject platform = store->environment(terminals->place()->environmentId).value(QLatin1String("platform")).toObject();
  if (platform.isEmpty()) platform = m_native->client()->descriptor().value(QLatin1String("platform")).toObject();
  return platform.value(QLatin1String("os")).toString();
}

QString MobileTerminal::shownTerminalId() const {
  auto* terminals = m_native->controller<TerminalController>();
  const QString active = terminals->activeTerminalId();
  if (!active.isEmpty()) return active;
  const QVariantList listed = terminals->listing();
  return listed.isEmpty() ? QString() : listed.constFirst().toMap().value(QStringLiteral("terminalId")).toString();
}

QVariantMap MobileTerminal::shownTerminal() const {
  const QString id = shownTerminalId();
  const QVariantList listed = m_native->controller<TerminalController>()->listing();
  for (const QVariant& value : listed) {
    if (value.toMap().value(QStringLiteral("terminalId")).toString() == id) return value.toMap();
  }
  return {};
}

void MobileTerminal::publish() {
  // A modifier is held for the terminal it was pressed in.
  if (!m_held.isEmpty() && m_heldFor != shownTerminalId()) m_held.clear();
  const QVariantMap shown = shownTerminal();
  const QString system = hostSystem();
  QVariant context;
  if (m_choosing) {
    const QString text = contextText();
    context = QVariantMap{{QStringLiteral("lines"), m_contextLines},
                          {QStringLiteral("start"), m_contextStart},
                          {QStringLiteral("end"), m_contextEnd},
                          {QStringLiteral("tooLarge"), text.size() > kMaxContextChars}};
  }
  m_bridge->publish(kKey, QVariantMap{
                              {QStringLiteral("label"), statusLabel(shown.value(QStringLiteral("status")).toString(), shown.value(QStringLiteral("busy")).toBool())},
                              {QStringLiteral("modifiers"), system == QLatin1String("darwin") ? QStringList{QStringLiteral("cmd"), QStringLiteral("ctrl")}
                                                                                              : QStringList{QStringLiteral("ctrl"), QStringLiteral("alt")}},
                              {QStringLiteral("held"), m_held},
                              {QStringLiteral("textSize"), m_textSize},
                              {QStringLiteral("terminal"), shown.value(QStringLiteral("label")).toString()},
                              {QStringLiteral("context"), context},
                          });
}

void TerminalEvents::key(QQuickItem* item, int key, int modifiers) {
  if (!item) return;
  QKeyEvent press(QEvent::KeyPress, key, Qt::KeyboardModifiers(modifiers));
  QCoreApplication::sendEvent(item, &press);
  QKeyEvent release(QEvent::KeyRelease, key, Qt::KeyboardModifiers(modifiers));
  QCoreApplication::sendEvent(item, &release);
}

void TerminalEvents::wheel(QQuickItem* item, qreal pixels) {
  if (!item) return;
  const QPointF centre(item->width() / 2, item->height() / 2);
  QWheelEvent event(centre, item->mapToGlobal(centre), QPoint(0, std::lround(pixels)), QPoint(0, std::lround(pixels * 120 / 15)), Qt::NoButton, Qt::NoModifier,
                    Qt::NoScrollPhase, false);
  QCoreApplication::sendEvent(item, &event);
}

void TerminalEvents::mouse(QQuickItem* item, const QString& what, qreal x, qreal y, int modifiers) {
  if (!item) return;
  const QPointF at(x, y);
  const QEvent::Type type = what == QLatin1String("press")     ? QEvent::MouseButtonPress
                            : what == QLatin1String("release") ? QEvent::MouseButtonRelease
                                                               : QEvent::MouseMove;
  const Qt::MouseButton button = type == QEvent::MouseMove ? Qt::NoButton : Qt::LeftButton;
  const Qt::MouseButtons buttons = type == QEvent::MouseButtonRelease ? Qt::NoButton : Qt::LeftButton;
  QMouseEvent event(type, at, item->mapToScene(at), item->mapToGlobal(at), button, buttons, Qt::KeyboardModifiers(modifiers));
  QCoreApplication::sendEvent(item, &event);
}
