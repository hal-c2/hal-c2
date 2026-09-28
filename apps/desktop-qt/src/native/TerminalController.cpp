#include "TerminalController.h"

#include <QJsonValue>
#include <QQmlPropertyMap>
#include <QRegularExpression>

#include <algorithm>

#include "NodeClient.h"
#include "ShellBridge.h"
#include "ShellStore.h"

namespace {

// The drawer reads it as the `Terminals` singleton.
const NativeControllerRegistrar<TerminalController> registrar(QStringLiteral("terminals"), {}, "Terminals");

// TerminalWriteInput's limit.
constexpr qsizetype kMaxWrite = 65536;
// What the transcript keeps for a late Terminal, as the other clients cap their
// buffers (docs/internals/terminal-runtime.md); the node keeps the full history.
constexpr qsizetype kMaxTranscript = 512 * 1024;

int terminalNumber(const QString& terminalId) {
  static const QRegularExpression pattern(QStringLiteral("^term(?:inal)?-(\\d+)$"),
                                          QRegularExpression::CaseInsensitiveOption);
  const QRegularExpressionMatch match = pattern.match(terminalId);
  return match.hasMatch() ? match.captured(1).toInt() : -1;
}

// packages/shared terminalLabels: the node's label, else "Terminal N".
QString terminalLabel(const QString& terminalId, const QString& label) {
  if (!label.trimmed().isEmpty()) return label.trimmed();
  const int number = terminalNumber(terminalId);
  return number >= 0 ? QStringLiteral("Terminal %1").arg(number) : terminalId;
}

// Numbered terminals in order, anything else after them.
bool terminalBefore(const QString& left, const QString& right) {
  const int a = terminalNumber(left);
  const int b = terminalNumber(right);
  if ((a < 0) != (b < 0)) return a >= 0;
  if (a != b) return a < b;
  return left < right;
}

QString threadKeyOf(const QString& environmentId, const QString& threadId) {
  return environmentId + QLatin1Char(':') + threadId;
}

}  // namespace

QJsonObject TerminalPlace::launchInput(const QString& terminalId) const {
  QJsonObject input{
      {QStringLiteral("threadId"), threadId},
      {QStringLiteral("terminalId"), terminalId},
      {QStringLiteral("cwd"), cwd},
      {QStringLiteral("env"), env},
  };
  if (!worktreePath.isEmpty()) input.insert(QStringLiteral("worktreePath"), worktreePath);
  return input;
}

// --- TerminalSession -------------------------------------------------------------

TerminalSession::TerminalSession(NodeClient* client, const TerminalPlace& place, const QString& terminalId,
                                 QSize size, QObject* parent)
    : QObject(parent),
      m_client(client),
      m_environmentId(place.environmentId),
      m_threadId(place.threadId),
      m_terminalId(terminalId),
      m_wanted(size),
      m_sent(size) {
  QJsonObject input = place.launchInput(terminalId);
  if (size.isValid()) {
    input.insert(QStringLiteral("cols"), size.width());
    input.insert(QStringLiteral("rows"), size.height());
  }
  m_subscription = client->subscribe(
      {
          {QStringLiteral("type"), QStringLiteral("terminal")},
          {QStringLiteral("environment"), place.environmentId},
          {QStringLiteral("input"), input},
      },
      [this](const QJsonObject& frame) { onFrame(frame); });
}

TerminalSession::~TerminalSession() {
  if (m_subscription) m_client->unsubscribe(m_subscription);
}

void TerminalSession::onFrame(const QJsonObject& frame) {
  const QString type = frame.value(QLatin1String("t")).toString();
  if (type == QLatin1String("error")) {
    // The node refused the attach and forgot the shape.
    m_client->unsubscribe(m_subscription);
    m_subscription = 0;
    note(frame.value(QLatin1String("reason")).toString());
    return;
  }
  if (type != QLatin1String("terminal")) return;
  const QJsonObject event = frame.value(QLatin1String("event")).toObject();
  const QString kind = event.value(QLatin1String("type")).toString();
  if (kind == QLatin1String("snapshot") || kind == QLatin1String("restarted")) {
    // Every (re)subscription starts with a snapshot: the screen starts over.
    replace(event.value(QLatin1String("snapshot")).toObject().value(QLatin1String("history")).toString());
    if (!m_attached) {
      m_attached = true;
      flushWrites();
    }
    // The attach's size can be older than what the Terminal settled on since.
    if (m_wanted.isValid()) {
      m_sent = QSize();
      flushResize();
    }
  } else if (kind == QLatin1String("output")) {
    append(event.value(QLatin1String("data")).toString());
  } else if (kind == QLatin1String("cleared")) {
    replace(QString());
  } else if (kind == QLatin1String("exited")) {
    note(QStringLiteral("process exited"));
  } else if (kind == QLatin1String("error")) {
    note(event.value(QLatin1String("message")).toString());
  } else if (kind == QLatin1String("closed")) {
    emit closed();
  }
}

void TerminalSession::append(const QString& data) {
  if (data.isEmpty()) return;
  m_transcript.append(data);
  m_transcriptSize += data.size();
  while (m_transcriptSize > kMaxTranscript && m_transcript.size() > 1) {
    m_transcriptSize -= m_transcript.takeFirst().size();
  }
  emit output(data);
}

void TerminalSession::replace(const QString& history) {
  m_transcript.clear();
  m_transcriptSize = 0;
  if (!history.isEmpty()) {
    m_transcript.append(history);
    m_transcriptSize = history.size();
  }
  emit replaced(history);
}

// Said in the terminal itself, as the terminal client does.
void TerminalSession::note(const QString& text) {
  append(QStringLiteral("\r\n[%1]\r\n").arg(text));
}

void TerminalSession::write(const QString& data) {
  m_pendingWrite.append(data);
  flushWrites();
}

void TerminalSession::flushWrites() {
  if (m_writing || !m_attached || m_pendingWrite.isEmpty()) return;
  qsizetype length = std::min(m_pendingWrite.size(), kMaxWrite);
  // Never split a surrogate pair across two writes.
  if (length < m_pendingWrite.size() && m_pendingWrite.at(length - 1).isHighSurrogate()) --length;
  const QString chunk = m_pendingWrite.left(length);
  m_pendingWrite.remove(0, length);
  m_writing = true;
  m_client->call(m_environmentId, QStringLiteral("terminal.write"),
                 QJsonObject{
                     {QStringLiteral("threadId"), m_threadId},
                     {QStringLiteral("terminalId"), m_terminalId},
                     {QStringLiteral("data"), chunk},
                 },
                 [self = QPointer(this)](const QJsonValue&, const std::optional<QString>& error) {
                   if (!self) return;
                   self->m_writing = false;
                   if (error) {
                     // Typing into an ended shell, or no node: what was typed is gone.
                     self->m_pendingWrite.clear();
                     return;
                   }
                   self->flushWrites();
                 });
}

void TerminalSession::resize(int columns, int rows) {
  if (columns <= 0 || rows <= 0) return;
  m_wanted = QSize(columns, rows);
  emit resized(m_wanted);
  flushResize();
}

void TerminalSession::flushResize() {
  if (m_resizing || !m_attached || !m_wanted.isValid() || m_wanted == m_sent) return;
  m_sent = m_wanted;
  m_resizing = true;
  m_client->call(m_environmentId, QStringLiteral("terminal.resize"),
                 QJsonObject{
                     {QStringLiteral("threadId"), m_threadId},
                     {QStringLiteral("terminalId"), m_terminalId},
                     {QStringLiteral("cols"), m_sent.width()},
                     {QStringLiteral("rows"), m_sent.height()},
                 },
                 [self = QPointer(this)](const QJsonValue&, const std::optional<QString>&) {
                   if (!self) return;
                   self->m_resizing = false;
                   self->flushResize();
                 });
}

// --- TerminalTabs ------------------------------------------------------------------

int TerminalTabs::rowCount(const QModelIndex& parent) const {
  return parent.isValid() ? 0 : int(m_rows.size());
}

QVariant TerminalTabs::data(const QModelIndex& index, int role) const {
  if (!index.isValid() || index.row() >= m_rows.size()) return {};
  const Row& row = m_rows.at(index.row());
  switch (role) {
    case TerminalIdRole:
      return row.terminalId;
    case LabelRole:
      return row.label;
    case BusyRole:
      return row.busy;
    case SessionRole:
      return QVariant::fromValue<QObject*>(row.session);
    default:
      return {};
  }
}

QHash<int, QByteArray> TerminalTabs::roleNames() const {
  return {
      {TerminalIdRole, "terminalId"},
      {LabelRole, "label"},
      {BusyRole, "busy"},
      {SessionRole, "session"},
  };
}

int TerminalTabs::indexOf(const QString& terminalId) const {
  for (int i = 0; i < m_rows.size(); ++i) {
    if (m_rows.at(i).terminalId == terminalId) return i;
  }
  return -1;
}

void TerminalTabs::insert(int index, const Row& row) {
  beginInsertRows(QModelIndex(), index, index);
  m_rows.insert(index, row);
  endInsertRows();
  emit countChanged();
}

void TerminalTabs::remove(int index) {
  beginRemoveRows(QModelIndex(), index, index);
  TerminalSession* session = m_rows.takeAt(index).session;
  endRemoveRows();
  // Its Terminal item may still be finishing a signal from it.
  if (session) session->deleteLater();
  emit countChanged();
}

void TerminalTabs::update(int index, const QString& label, bool busy) {
  Row& row = m_rows[index];
  if (row.label == label && row.busy == busy) return;
  row.label = label;
  row.busy = busy;
  const QModelIndex changed = this->index(index);
  emit dataChanged(changed, changed, {LabelRole, BusyRole});
}

void TerminalTabs::clear() {
  if (m_rows.isEmpty()) return;
  beginResetModel();
  for (const Row& row : std::as_const(m_rows)) {
    if (row.session) row.session->deleteLater();
  }
  m_rows.clear();
  endResetModel();
  emit countChanged();
}

// --- TerminalController ------------------------------------------------------------

TerminalController::TerminalController(ShellBridge* bridge, NodeClient* client, ShellStore* store,
                                       QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store), m_tabs(this) {
  connect(store, &ShellStore::changed, this, &TerminalController::refresh);
  connect(bridge, &ShellBridge::stateEntryChanged, this, [this](const QString& key) {
    if (key == QLatin1String("workspace")) refresh();
  });
}

void TerminalController::activate() {
  if (m_active) return;
  m_active = true;
  refresh();
}

bool TerminalController::isOpen() const {
  return m_place && m_ui.value(m_threadKey).open;
}

QString TerminalController::activeTerminalId() const {
  return m_place ? m_ui.value(m_threadKey).active : QString();
}

bool TerminalController::handle(const QString& action, const QVariant& payload) {
  if (!m_active) return false;
  const QVariantMap args = payload.toMap();
  if (action == QLatin1String("terminal.toggle")) {
    if (m_place && setOpen(!isOpen()) && isOpen()) emit focusRequested();
    return true;
  }
  if (action == QLatin1String("terminal.resize")) {
    const int height = std::max(minimumHeight, args.value(QStringLiteral("height")).toInt());
    if (height != m_height) {
      m_height = height;
      emit changed();
    }
    return true;
  }
  if (action == QLatin1String("terminal.new")) {
    if (!m_place) return true;
    if (terminalIds().size() >= maxTerminals) {
      toast(QStringLiteral("At most %1 terminals per thread.").arg(maxTerminals), QString());
      return true;
    }
    openTerminal(nextTerminalId());
    return true;
  }
  if (action == QLatin1String("terminal.select")) {
    const QString terminalId = args.value(QStringLiteral("terminalId")).toString();
    if (m_place && terminalIds().contains(terminalId)) openTerminal(terminalId);
    return true;
  }
  if (action == QLatin1String("terminal.close")) {
    if (!m_place) return true;
    const QString terminalId = args.value(QStringLiteral("terminalId"), activeTerminalId()).toString();
    if (terminalIds().contains(terminalId)) closeTerminal(terminalId);
    return true;
  }
  if (action == QLatin1String("workspace.runScript")) {
    if (!m_place) return false;
    runScript(args.value(QStringLiteral("scriptId")).toString());
    return true;
  }
  return false;
}

// Where the page's thread (a draft too) runs its terminals, from what the page
// resolved for its header: the thread, its project root, worktree and scripts.
std::optional<TerminalPlace> TerminalController::placeFor(const QVariantMap& workspace) const {
  if (!workspace.value(QStringLiteral("terminalAvailable")).toBool()) return std::nullopt;
  const QString threadKey = workspace.value(QStringLiteral("threadKey")).toString();
  const qsizetype colon = threadKey.indexOf(QLatin1Char(':'));
  const QString root = workspace.value(QStringLiteral("projectRoot")).toString();
  if (colon <= 0 || root.isEmpty()) return std::nullopt;
  TerminalPlace place;
  place.environmentId = threadKey.left(colon);
  place.threadId = threadKey.mid(colon + 1);
  if (!m_store->reaches(place.environmentId) || place.threadId.isEmpty()) return std::nullopt;
  place.worktreePath = workspace.value(QStringLiteral("worktreePath")).toString();
  place.cwd = place.worktreePath.isEmpty() ? root : place.worktreePath;
  // packages/shared projectScriptRuntimeEnv; T3CODE_ is what older scripts read.
  place.env = {
      {QStringLiteral("HAL_C2_PROJECT_ROOT"), root},
      {QStringLiteral("T3CODE_PROJECT_ROOT"), root},
  };
  if (!place.worktreePath.isEmpty()) {
    place.env.insert(QStringLiteral("HAL_C2_WORKTREE_PATH"), place.worktreePath);
    place.env.insert(QStringLiteral("T3CODE_WORKTREE_PATH"), place.worktreePath);
  }
  place.scripts = QJsonArray::fromVariantList(workspace.value(QStringLiteral("scripts")).toList());
  return place;
}

void TerminalController::refresh() {
  if (!m_active) return;
  const QVariantMap workspace = m_bridge->state()->value(QStringLiteral("workspace")).toMap();
  auto place = placeFor(workspace);
  const QString threadKey = place ? place->environmentId + QLatin1Char(':') + place->threadId : QString();
  if (place) watch(place->environmentId);
  // Another thread, or the same one launching elsewhere: start over.
  const bool moved = threadKey != m_threadKey || !place || !m_place || place->cwd != m_place->cwd;
  if (moved) {
    m_tabs.clear();
    m_attached = false;
  }
  m_threadKey = threadKey;
  m_place = std::move(place);
  syncTabs();
  emit changed();
}

QStringList TerminalController::terminalIds() const {
  const ThreadUi ui = m_ui.value(m_threadKey);
  QSet<QString> ids = ui.local;
  const auto known = m_known.value(m_threadKey);
  for (auto it = known.cbegin(); it != known.cend(); ++it) ids.insert(it.key());
  for (const QString& id : ui.closing) ids.remove(id);
  QStringList sorted(ids.cbegin(), ids.cend());
  std::sort(sorted.begin(), sorted.end(), terminalBefore);
  return sorted;
}

// Brings the tab rows (and their sessions) in line with the thread's terminals.
void TerminalController::syncTabs() {
  if (!m_place) return;
  ThreadUi& ui = m_ui[m_threadKey];
  const QStringList ids = terminalIds();
  // The node closed the last one (here or elsewhere): the drawer hides.
  if (ui.open && m_attached && ids.isEmpty()) ui.open = false;
  if (!ids.contains(ui.active)) ui.active = ids.isEmpty() ? QString() : ids.constLast();
  if (!ui.open && !m_attached) return;
  m_attached = true;
  const auto known = m_known.value(m_threadKey);
  for (int i = int(m_tabs.rows().size()) - 1; i >= 0; --i) {
    if (!ids.contains(m_tabs.rows().at(i).terminalId)) m_tabs.remove(i);
  }
  for (int i = 0; i < ids.size(); ++i) {
    const QString& id = ids.at(i);
    const Summary summary = known.value(id);
    const QString label = terminalLabel(id, summary.label);
    const int index = m_tabs.indexOf(id);
    if (index >= 0) {
      m_tabs.update(index, label, summary.busy);
      continue;
    }
    auto* session = new TerminalSession(m_client, *m_place, id, m_size, this);
    connect(session, &TerminalSession::resized, this, [this](QSize size) { m_size = size; });
    const QString threadKey = m_threadKey;
    connect(session, &TerminalSession::closed, this, [this, threadKey, id] {
      m_ui[threadKey].local.remove(id);
      m_known[threadKey].remove(id);
      if (threadKey == m_threadKey) {
        syncTabs();
        emit changed();
      }
    });
    m_tabs.insert(i, {id, label, summary.busy, session});
  }
}

// Follows an environment's terminals list once a thread there is shown.
void TerminalController::watch(const QString& environmentId) {
  if (m_watched.contains(environmentId)) return;
  const QJsonObject shape{{QStringLiteral("type"), QStringLiteral("terminals")},
                          {QStringLiteral("environment"), environmentId}};
  m_watched.insert(environmentId, m_client->subscribe(shape, [this, environmentId](const QJsonObject& frame) {
    if (frame.value(QLatin1String("t")) != QLatin1String("terminals")) return;
    onTerminals(environmentId, frame.value(QLatin1String("event")).toObject());
  }));
}

void TerminalController::onTerminals(const QString& environmentId, const QJsonObject& event) {
  const QString type = event.value(QLatin1String("type")).toString();
  auto put = [this, &environmentId](const QJsonObject& terminal) {
    const QString key = threadKeyOf(environmentId, terminal.value(QLatin1String("threadId")).toString());
    const QString id = terminal.value(QLatin1String("terminalId")).toString();
    m_known[key].insert(id, {terminal.value(QLatin1String("label")).toString(),
                             terminal.value(QLatin1String("hasRunningSubprocess")).toBool()});
    m_ui[key].local.remove(id);
  };
  if (type == QLatin1String("snapshot")) {
    const QString prefix = environmentId + QLatin1Char(':');
    for (auto it = m_known.begin(); it != m_known.end();) {
      it = it.key().startsWith(prefix) ? m_known.erase(it) : std::next(it);
    }
    for (const QJsonValue& value : event.value(QLatin1String("terminals")).toArray()) put(value.toObject());
  } else if (type == QLatin1String("upsert")) {
    put(event.value(QLatin1String("terminal")).toObject());
  } else if (type == QLatin1String("remove")) {
    const QString key = threadKeyOf(environmentId, event.value(QLatin1String("threadId")).toString());
    const QString id = event.value(QLatin1String("terminalId")).toString();
    m_known[key].remove(id);
    m_ui[key].local.remove(id);
  } else {
    return;
  }
  syncTabs();
  emit changed();
}

// Returns whether the drawer's open state changed.
bool TerminalController::setOpen(bool open) {
  ThreadUi& ui = m_ui[m_threadKey];
  if (ui.open == open) return false;
  ui.open = open;
  // A thread with no terminal yet gets its first one.
  if (open && terminalIds().isEmpty()) ui.local.insert(nextTerminalId());
  syncTabs();
  emit changed();
  return true;
}

// Shows the terminal (opening it here if it is new) and gives it the keyboard.
void TerminalController::openTerminal(const QString& terminalId) {
  ThreadUi& ui = m_ui[m_threadKey];
  if (!terminalIds().contains(terminalId)) ui.local.insert(terminalId);
  ui.active = terminalId;
  ui.open = true;
  syncTabs();
  emit changed();
  emit focusRequested();
}

void TerminalController::closeTerminal(const QString& terminalId) {
  const QString threadKey = m_threadKey;
  ThreadUi& ui = m_ui[threadKey];
  ui.local.remove(terminalId);
  ui.closing.insert(terminalId);
  // Closing the active one activates the last one left.
  if (ui.active == terminalId) ui.active.clear();
  if (terminalIds().isEmpty()) ui.open = false;
  m_client->call(m_place->environmentId, QStringLiteral("terminal.close"),
                 QJsonObject{
                     {QStringLiteral("threadId"), m_place->threadId},
                     {QStringLiteral("terminalId"), terminalId},
                     {QStringLiteral("deleteHistory"), true},
                 },
                 [this, threadKey, terminalId](const QJsonValue&, const std::optional<QString>& error) {
                   m_ui[threadKey].closing.remove(terminalId);
                   if (error) {
                     toast(QStringLiteral("Failed to close the terminal."), *error);
                   } else {
                     m_known[threadKey].remove(terminalId);
                   }
                   if (threadKey == m_threadKey) {
                     syncTabs();
                     emit changed();
                   }
                 });
  syncTabs();
  emit changed();
  if (ui.open) emit focusRequested();
}

// As the page's runProjectScript: in the active terminal, or a new one when
// that one is busy running something.
void TerminalController::runScript(const QString& scriptId) {
  QJsonObject script;
  for (const QJsonValue& value : std::as_const(m_place->scripts)) {
    if (value.toObject().value(QLatin1String("id")).toString() == scriptId) script = value.toObject();
  }
  if (script.isEmpty()) return;
  const QString name = script.value(QLatin1String("name")).toString();
  const QStringList ids = terminalIds();
  const QString active = activeTerminalId();
  QString terminalId = !active.isEmpty() ? active : !ids.isEmpty() ? ids.constFirst() : nextTerminalId();
  if (m_known.value(m_threadKey).value(terminalId).busy) {
    if (ids.size() >= maxTerminals) {
      toast(QStringLiteral("At most %1 terminals per thread.").arg(maxTerminals), QString());
      return;
    }
    terminalId = nextTerminalId();
  }
  openTerminal(terminalId);
  // terminal.open restarts a shell that has ended, so the script always runs.
  QJsonObject input = m_place->launchInput(terminalId);
  if (const TerminalSession* session = this->session(terminalId); session && session->size().isValid()) {
    input.insert(QStringLiteral("cols"), session->size().width());
    input.insert(QStringLiteral("rows"), session->size().height());
  }
  const QString command = script.value(QLatin1String("command")).toString() + QLatin1Char('\r');
  const QString threadKey = m_threadKey;
  const TerminalPlace place = *m_place;
  m_client->call(place.environmentId, QStringLiteral("terminal.open"), input,
                 [this, threadKey, place, terminalId, command, name](const QJsonValue&,
                                                                      const std::optional<QString>& error) {
                   const QString failed = QStringLiteral("Failed to run script \"%1\".").arg(name);
                   if (error) {
                     toast(failed, *error);
                     return;
                   }
                   if (TerminalSession* session = this->session(terminalId); session && threadKey == m_threadKey) {
                     session->write(command);
                     return;
                   }
                   // The user moved on; the script still runs.
                   m_client->call(place.environmentId, QStringLiteral("terminal.write"),
                                  QJsonObject{
                                      {QStringLiteral("threadId"), place.threadId},
                                      {QStringLiteral("terminalId"), terminalId},
                                      {QStringLiteral("data"), command},
                                  },
                                  [this, failed](const QJsonValue&, const std::optional<QString>& error) {
                                    if (error) toast(failed, *error);
                                  });
                 });
}

// The lowest free `term-N`, as packages/shared nextTerminalId; ids still
// closing stay taken until the node lets go of them.
QString TerminalController::nextTerminalId() const {
  QSet<int> used;
  for (const QString& id : terminalIds()) used.insert(terminalNumber(id));
  for (const QString& id : m_ui.value(m_threadKey).closing) used.insert(terminalNumber(id));
  int next = 1;
  while (used.contains(next)) ++next;
  return QStringLiteral("term-%1").arg(next);
}

TerminalSession* TerminalController::session(const QString& terminalId) const {
  const int index = m_tabs.indexOf(terminalId);
  return index >= 0 ? m_tabs.rows().at(index).session : nullptr;
}

void TerminalController::toast(const QString& title, const QString& description) {
  QVariantMap toast{
      {QStringLiteral("toastType"), QStringLiteral("error")},
      {QStringLiteral("title"), title},
  };
  if (!description.isEmpty()) toast.insert(QStringLiteral("description"), description);
  m_bridge->sendToPage(QStringLiteral("toast.show"), toast);
}
