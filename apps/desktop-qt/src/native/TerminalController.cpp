#include "TerminalController.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonValue>
#include <QSaveFile>
#include <QUrl>
#include <QQmlPropertyMap>
#include <QRegularExpression>

#include <algorithm>

#include "NativeShell.h"
#include "McClient.h"
#include "MenuController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "ToastController.h"
#include "WorkspaceController.h"

namespace {

// The drawer reads it as the `Terminals` singleton.
const NativeControllerRegistrar<TerminalController> registrar(QStringLiteral("terminals"), {}, "Terminals");

// TerminalWriteInput's limit.
constexpr qsizetype kMaxWrite = 65536;
// What the transcript keeps for a late Terminal, as the other clients cap their
// buffers (docs/internals/terminal-runtime.md); the MC keeps the full history.
constexpr qsizetype kMaxTranscript = 512 * 1024;

// How many threads' drawers the store remembers.
constexpr qsizetype kStoredThreads = 50;

int terminalNumber(const QString& terminalId) {
  static const QRegularExpression pattern(QStringLiteral("^term(?:inal)?-(\\d+)$"),
                                          QRegularExpression::CaseInsensitiveOption);
  const QRegularExpressionMatch match = pattern.match(terminalId);
  return match.hasMatch() ? match.captured(1).toInt() : -1;
}

// packages/shared terminalLabels: the MC's label, else "Terminal N".
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
  if (!providerInstanceId.isEmpty()) input.insert(QStringLiteral("providerInstanceId"), providerInstanceId);
  return input;
}

// --- TerminalSession -------------------------------------------------------------

TerminalSession::TerminalSession(McClient* client, const TerminalPlace& place, const QString& terminalId,
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
  m_subscription = client->subscribe(this, 
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
    // The MC refused the attach and forgot the shape.
    m_client->unsubscribe(m_subscription);
    m_subscription = 0;
    note(frame.value(QLatin1String("reason")).toString());
    emit failed(frame.value(QLatin1String("reason")).toString());
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
      emit attached();
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
    emit exited();
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
  m_client->call(this, m_environmentId, QStringLiteral("terminal.write"),
                 QJsonObject{
                     {QStringLiteral("threadId"), m_threadId},
                     {QStringLiteral("terminalId"), m_terminalId},
                     {QStringLiteral("data"), chunk},
                 },
                 [self = QPointer(this)](const QJsonValue&, const std::optional<QString>& error) {
                   if (!self) return;
                   self->m_writing = false;
                   if (error) {
                     // Typing into an ended shell, or no MC: what was typed is gone.
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
  m_client->call(this, m_environmentId, QStringLiteral("terminal.resize"),
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
    case GroupRole:
      return row.group;
    case PanelRole:
      return row.panel;
    case SlotRole:
      return row.slot;
    case SpanRole:
      return row.span;
    case VerticalRole:
      return row.vertical;
    case CurrentRole:
      return row.current;
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
      {GroupRole, "group"},
      {PanelRole, "panel"},
      {SlotRole, "slot"},
      {SpanRole, "span"},
      {VerticalRole, "vertical"},
      {CurrentRole, "current"},
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

bool TerminalTabs::Row::sameLayout(const Row& other) const {
  return label == other.label && busy == other.busy && group == other.group && panel == other.panel &&
         slot == other.slot && span == other.span && vertical == other.vertical && current == other.current;
}

void TerminalTabs::update(int index, const Row& next) {
  Row& row = m_rows[index];
  if (row.sameLayout(next)) return;
  TerminalSession* session = row.session;
  row = next;
  row.session = session;
  const QModelIndex changed = this->index(index);
  emit dataChanged(changed, changed);
}

QHash<QString, TerminalSession*> TerminalTabs::take() {
  QHash<QString, TerminalSession*> sessions;
  if (m_rows.isEmpty()) return sessions;
  beginResetModel();
  for (const Row& row : std::as_const(m_rows)) {
    if (row.session) sessions.insert(row.terminalId, row.session);
  }
  m_rows.clear();
  endResetModel();
  emit countChanged();
  return sessions;
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

TerminalController::TerminalController(ShellBridge* bridge, McClient* client, ShellStore* store,
                                       QObject* parent)
    : QObject(parent), m_bridge(bridge), m_client(client), m_store(store), m_tabs(this) {
  connect(store, &ShellStore::changed, this, &TerminalController::refresh);
  connect(this, &TerminalController::changed, this, &TerminalController::save);
}

void TerminalController::activate() {
  if (m_active) return;
  m_active = true;
  // Built after this one ("terminals" < "workspace"), so found here.
  if (auto* workspace = NativeShell::of(this)->controller<WorkspaceController>()) {
    connect(workspace, &WorkspaceController::placeChanged, this, &TerminalController::refresh);
  }
  refresh();
}

bool TerminalController::isOpen() const {
  if (!m_place) return false;
  const ThreadUi ui = m_ui.value(m_threadKey);
  return ui.open && !ui.restored;
}

void TerminalController::setStorePath(const QString& path) {
  m_storePath = path;
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly)) return;
  m_saved = file.readAll();
  const QJsonObject stored = QJsonDocument::fromJson(m_saved).object();
  m_height = std::max(minimumHeight, stored.value(QLatin1String("height")).toInt(m_height));
  for (const QJsonValue& value : stored.value(QLatin1String("threads")).toArray()) {
    const QJsonObject thread = value.toObject();
    const QString threadKey = thread.value(QLatin1String("threadKey")).toString();
    if (threadKey.isEmpty()) continue;
    ThreadUi& ui = m_ui[threadKey];
    ui.open = thread.value(QLatin1String("open")).toBool();
    ui.active = thread.value(QLatin1String("active")).toString();
    ui.restored = true;
    m_recent.removeOne(threadKey);
    m_recent.append(threadKey);
  }
  emit changed();
}

void TerminalController::save() {
  if (m_storePath.isEmpty()) return;
  if (!m_threadKey.isEmpty() && m_ui.contains(m_threadKey)) {
    m_recent.removeOne(m_threadKey);
    m_recent.append(m_threadKey);
  }
  QJsonArray threads;
  for (qsizetype at = m_recent.size() - 1; at >= 0 && threads.size() < kStoredThreads; --at) {
    const ThreadUi ui = m_ui.value(m_recent.at(at));
    if (!ui.open && ui.active.isEmpty()) continue;
    threads.prepend(QJsonObject{{QStringLiteral("threadKey"), m_recent.at(at)},
                                {QStringLiteral("open"), ui.open},
                                {QStringLiteral("active"), ui.active}});
  }
  const QByteArray json =
      QJsonDocument(QJsonObject{{QStringLiteral("height"), m_height}, {QStringLiteral("threads"), threads}}).toJson(QJsonDocument::Compact);
  if (json == m_saved) return;
  QDir().mkpath(QFileInfo(m_storePath).absolutePath());
  QSaveFile file(m_storePath);
  if (!file.open(QIODevice::WriteOnly)) return;
  file.write(json);
  if (file.commit()) m_saved = json;
}

QString TerminalController::activeTerminalId() const {
  return m_place ? m_ui.value(m_threadKey).active : QString();
}

QString TerminalController::activeGroup() const {
  if (!m_place) return {};
  const ThreadUi ui = m_ui.value(m_threadKey);
  if (ui.active.isEmpty()) return {};
  const Group* group = groupOf(ui, ui.active);
  return group ? group->id : ui.active;
}

QVariantMap TerminalController::groupSizes() const {
  QVariantMap sizes;
  if (!m_place) return sizes;
  for (const Group& group : m_ui.value(m_threadKey).groups) sizes.insert(group.id, group.terminals.size());
  return sizes;
}

TerminalController::Group* TerminalController::groupOf(ThreadUi& ui, const QString& terminalId) {
  for (Group& group : ui.groups) {
    if (group.terminals.contains(terminalId)) return &group;
  }
  return nullptr;
}

const TerminalController::Group* TerminalController::groupOf(const ThreadUi& ui, const QString& terminalId) {
  for (const Group& group : ui.groups) {
    if (group.terminals.contains(terminalId)) return &group;
  }
  return nullptr;
}

QStringList TerminalController::drawerIds(const ThreadUi& ui, const QStringList& ids) const {
  QStringList drawer;
  for (const QString& id : ids) {
    const Group* group = groupOf(ui, id);
    if (!group || !group->panel) drawer.append(id);
  }
  return drawer;
}

QStringList TerminalController::panelGroups(const QString& threadKey) const {
  QStringList groups;
  for (const Group& group : m_ui.value(threadKey).groups) {
    if (group.panel) groups.append(group.id);
  }
  return groups;
}

bool TerminalController::handle(const QString& action, const QVariant& payload) {
  if (!m_active) return false;
  const QVariantMap args = payload.toMap();
  if (action == QLatin1String("terminal.toggle")) {
    if (m_place && setOpen(!isOpen()) && isOpen()) emit focusRequested(activeTerminalId());
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
  if (action == QLatin1String("terminal.split") || action == QLatin1String("terminal.splitVertical")) {
    split(args.value(QStringLiteral("terminalId")).toString(), action == QLatin1String("terminal.splitVertical"));
    return true;
  }
  if (action == QLatin1String("terminal.select")) {
    const QString terminalId = args.value(QStringLiteral("terminalId")).toString();
    if (m_place && terminalIds().contains(terminalId)) openTerminal(terminalId);
    return true;
  }
  if (action == QLatin1String("terminal.followLink")) {
    followLink(args.value(QStringLiteral("kind")).toString(), args.value(QStringLiteral("text")).toString(),
               args.value(QStringLiteral("cwd")).toString());
    return true;
  }
  if (action == QLatin1String("terminal.close")) {
    if (!m_place) return true;
    // A keybinding's is the focused terminal's, the drawer's or a panel tab's.
    const QStringList ids = terminalIds();
    const QString fallback = ids.contains(m_focused) ? m_focused : activeTerminalId();
    const QString terminalId = args.value(QStringLiteral("terminalId"), fallback).toString();
    if (!ids.contains(terminalId)) return true;
    const QString threadKey = m_threadKey;
    confirmClose({terminalId}, [this, threadKey, terminalId] {
      if (threadKey == m_threadKey && terminalIds().contains(terminalId)) closeTerminal(terminalId);
    });
    return true;
  }
  return false;
}

// Where the route's thread (a draft too) runs its terminals: its project root,
// worktree and scripts, on an environment the MC reaches.
std::optional<TerminalPlace> TerminalController::placeOfWorkspace() const {
  auto* workspace = NativeShell::of(this)->controller<WorkspaceController>();
  if (!workspace || !workspace->place()) return std::nullopt;
  const WorkspaceController::Place& at = *workspace->place();
  if (at.root.isEmpty() || at.threadId.isEmpty() || !m_store->reaches(at.environmentId)) return std::nullopt;
  TerminalPlace place;
  place.environmentId = at.environmentId;
  place.threadId = at.threadId;
  place.worktreePath = at.worktreePath;
  place.cwd = at.cwd();
  // packages/shared projectScriptRuntimeEnv; T3CODE_ is what older scripts read.
  place.env = {
      {QStringLiteral("HAL_C2_PROJECT_ROOT"), at.root},
      {QStringLiteral("T3CODE_PROJECT_ROOT"), at.root},
  };
  if (!place.worktreePath.isEmpty()) {
    place.env.insert(QStringLiteral("HAL_C2_WORKTREE_PATH"), place.worktreePath);
    place.env.insert(QStringLiteral("T3CODE_WORKTREE_PATH"), place.worktreePath);
  }
  place.scripts = at.scripts;
  return place;
}

void TerminalController::refresh() {
  if (!m_active) return;
  auto place = placeOfWorkspace();
  const QString threadKey = place ? place->environmentId + QLatin1Char(':') + place->threadId : QString();
  if (place) watch(place->environmentId);
  // Another thread, or the same one launching elsewhere: start over.
  const bool moved = threadKey != m_threadKey || !place || !m_place || place->cwd != m_place->cwd;
  if (moved) {
    // Leaving a thread keeps its terminals attached; a thread that now runs
    // somewhere else starts over.
    if (threadKey != m_threadKey && m_place && m_attached) {
      park(m_threadKey, m_place->cwd);
    } else {
      m_tabs.clear();
    }
    m_attached = false;
    m_focused.clear();
    if (place && m_parked.contains(threadKey)) {
      if (m_parked.value(threadKey).cwd == place->cwd) {
        m_attached = true;
      } else {
        dropParked(threadKey);
      }
    }
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
  if (ui.restored) return;
  const QStringList ids = terminalIds();
  // A group loses the terminals that ended, and goes with the last one.
  for (auto it = ui.groups.begin(); it != ui.groups.end();) {
    it->terminals.removeIf([&ids](const QString& id) { return !ids.contains(id); });
    if (!it->terminals.contains(it->active)) it->active = it->terminals.isEmpty() ? QString() : it->terminals.constLast();
    it = it->terminals.isEmpty() ? ui.groups.erase(it) : std::next(it);
  }
  const QStringList drawer = drawerIds(ui, ids);
  // The MC closed the last one (here or elsewhere): the drawer hides.
  if (ui.open && m_attached && drawer.isEmpty()) ui.open = false;
  if (!drawer.contains(ui.active)) ui.active = drawer.isEmpty() ? QString() : drawer.constLast();
  const bool panel = drawer.size() < ids.size();
  if (!ui.open && !m_attached && !panel) return;
  m_attached = true;
  const auto known = m_known.value(m_threadKey);
  for (int i = int(m_tabs.rows().size()) - 1; i >= 0; --i) {
    if (!ids.contains(m_tabs.rows().at(i).terminalId)) m_tabs.remove(i);
  }
  for (int i = 0; i < ids.size(); ++i) {
    const QString& id = ids.at(i);
    const Summary summary = known.value(id);
    const QString label = terminalLabel(id, summary.label);
    TerminalTabs::Row row{id, label, summary.busy, nullptr, id};
    if (const Group* group = groupOf(ui, id)) {
      row.group = group->id;
      row.panel = group->panel;
      row.slot = int(group->terminals.indexOf(id));
      row.span = int(group->terminals.size());
      row.vertical = group->vertical;
      row.current = group->panel ? group->active == id : ui.active == id;
    } else {
      row.current = ui.active == id;
    }
    const int index = m_tabs.indexOf(id);
    if (index >= 0) {
      m_tabs.update(index, row);
      continue;
    }
    // Still attached from the user's last visit.
    if (TerminalSession* parked = m_parked[m_threadKey].sessions.take(id)) {
      row.session = parked;
      m_tabs.insert(i, row);
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
    // A shell that ended on its own takes its terminal with it, unasked
    // (the web's auto-exit cleanup).
    connect(session, &TerminalSession::exited, this, [this, threadKey, id] {
      if (threadKey == m_threadKey && terminalIds().contains(id)) closeTerminal(id);
    });
    row.session = session;
    m_tabs.insert(i, row);
  }
  // What the visit left that the thread no longer has.
  dropParked(m_threadKey);
}

void TerminalController::park(const QString& threadKey, const QString& cwd) {
  dropParked(threadKey);
  const QHash<QString, TerminalSession*> sessions = m_tabs.take();
  if (sessions.isEmpty()) return;
  m_parked.insert(threadKey, {cwd, sessions});
  m_parkedOrder.append(threadKey);
  while (m_parkedOrder.size() > maxParkedThreads) dropParked(m_parkedOrder.constFirst());
}

void TerminalController::dropParked(const QString& threadKey) {
  m_parkedOrder.removeOne(threadKey);
  const Parked parked = m_parked.take(threadKey);
  for (TerminalSession* session : parked.sessions) session->deleteLater();
}

// Follows an environment's terminals list once a thread there is shown.
void TerminalController::watch(const QString& environmentId) {
  if (m_watched.contains(environmentId)) return;
  const QJsonObject shape{{QStringLiteral("type"), QStringLiteral("terminals")},
                          {QStringLiteral("environment"), environmentId}};
  m_watched.insert(environmentId, m_client->subscribe(this, shape, [this, environmentId](const QJsonObject& frame) {
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
    // What the store remembered holds as far as the MC still runs it.
    for (auto it = m_ui.begin(); it != m_ui.end(); ++it) {
      if (!it->restored || !it.key().startsWith(prefix)) continue;
      it->restored = false;
      if (m_known.value(it.key()).isEmpty()) it->open = false;
    }
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
  if (std::exchange(ui.restored, false)) ui.open = false;
  if (ui.open == open) return false;
  ui.open = open;
  // A drawer with no terminal yet gets its first one.
  if (open && drawerIds(ui, terminalIds()).isEmpty()) ui.local.insert(nextTerminalId());
  syncTabs();
  emit changed();
  return true;
}

// Shows the terminal (opening it here if it is new) and gives it the keyboard.
// A terminal of a panel tab becomes the tab's active one instead.
void TerminalController::openTerminal(const QString& terminalId) {
  ThreadUi& ui = m_ui[m_threadKey];
  ui.restored = false;
  if (!terminalIds().contains(terminalId)) ui.local.insert(terminalId);
  if (Group* group = groupOf(ui, terminalId); group && group->panel) {
    group->active = terminalId;
  } else {
    ui.active = terminalId;
    ui.open = true;
  }
  syncTabs();
  emit changed();
  emit focusRequested(terminalId);
}

void TerminalController::focusTerminal(const QString& terminalId) {
  if (!m_place || !terminalIds().contains(terminalId)) return;
  m_focused = terminalId;
  ThreadUi& ui = m_ui[m_threadKey];
  Group* group = groupOf(ui, terminalId);
  QString& active = group && group->panel ? group->active : ui.active;
  if (active == terminalId) return;
  active = terminalId;
  syncTabs();
  emit changed();
}

// A terminal beside (or under) `terminalId` in its group, as the web's
// splitTerminal: the group takes the new direction.
void TerminalController::split(const QString& terminalId, bool vertical) {
  if (!m_place) return;
  ThreadUi& ui = m_ui[m_threadKey];
  ui.restored = false;
  const QStringList ids = terminalIds();
  QString target = ids.contains(terminalId) ? terminalId : ids.contains(m_focused) ? m_focused : ui.active;
  if (target.isEmpty() || !terminalIds().contains(target)) {
    // A hidden drawer with no terminal yet gets its first one, then the split.
    if (!ids.isEmpty()) return;
    target = nextTerminalId();
    ui.local.insert(target);
    ui.active = target;
  }
  Group* group = groupOf(ui, target);
  if (group && group->terminals.size() >= maxPerGroup) {
    toast(QStringLiteral("At most %1 terminals per group.").arg(maxPerGroup), QString());
    return;
  }
  if (ids.size() >= maxTerminals) {
    toast(QStringLiteral("At most %1 terminals per thread.").arg(maxTerminals), QString());
    return;
  }
  const QString id = nextTerminalId();
  if (!group) {
    ui.groups.append({QStringLiteral("group-%1").arg(++m_groupCount), {target}, vertical, false, target});
    group = &ui.groups.last();
  }
  ui.local.insert(id);
  group->terminals.insert(group->terminals.indexOf(target) + 1, id);
  group->vertical = vertical;
  group->active = id;
  if (!group->panel) {
    ui.active = id;
    ui.open = true;
  }
  syncTabs();
  emit changed();
  emit focusRequested(id);
}

QString TerminalController::addPanelGroup() {
  if (!m_active || !m_place) return {};
  if (terminalIds().size() >= maxTerminals) {
    toast(QStringLiteral("At most %1 terminals per thread.").arg(maxTerminals), QString());
    return {};
  }
  ThreadUi& ui = m_ui[m_threadKey];
  ui.restored = false;
  const QString id = nextTerminalId();
  const QString group = QStringLiteral("group-%1").arg(++m_groupCount);
  ui.local.insert(id);
  ui.groups.append({group, {id}, false, true, id});
  syncTabs();
  emit changed();
  emit focusRequested(id);
  return group;
}

void TerminalController::closeGroup(const QString& group) {
  if (!m_place) return;
  for (const Group& each : std::as_const(m_ui[m_threadKey].groups)) {
    if (each.id != group) continue;
    const QStringList terminals = each.terminals;
    for (const QString& id : terminals) closeTerminal(id);
    return;
  }
}

QStringList TerminalController::groupTerminals(const QString& group) const {
  for (const Group& each : m_ui.value(m_threadKey).groups) {
    if (each.id == group) return each.terminals;
  }
  return {};
}

void TerminalController::confirmClose(const QStringList& ids, std::function<void()> accepted) {
  auto* menu = NativeShell::of(this)->controller<MenuController>();
  if (ids.isEmpty() || !menu) {
    accepted();
    return;
  }
  const auto known = m_known.value(m_threadKey);
  QStringList labels;
  for (const QString& id : ids) labels.append(QStringLiteral("\"%1\"").arg(terminalLabel(id, known.value(id).label)));
  if (ids.size() == 1) {
    menu->confirm(QStringLiteral("Close terminal %1?").arg(labels.constFirst()),
                  QStringLiteral("This stops the running process and clears its history."), QStringLiteral("Close terminal"), true,
                  std::move(accepted));
    return;
  }
  menu->confirm(QStringLiteral("Close %1 terminals?").arg(ids.size()),
                QStringLiteral("This stops their running processes and clears their histories: %1.").arg(labels.join(QStringLiteral(", "))),
                QStringLiteral("Close terminals"), true, std::move(accepted));
}

void TerminalController::closeTerminal(const QString& terminalId) {
  const QString threadKey = m_threadKey;
  ThreadUi& ui = m_ui[threadKey];
  ui.local.remove(terminalId);
  ui.closing.insert(terminalId);
  // Closing the active one activates the last one left in its group, else
  // the drawer's last one.
  QString next;
  bool panel = false;
  if (Group* group = groupOf(ui, terminalId)) {
    group->terminals.removeOne(terminalId);
    if (group->active == terminalId) group->active = group->terminals.isEmpty() ? QString() : group->terminals.constLast();
    next = group->active;
    panel = group->panel;
    if (!panel && ui.active == terminalId) ui.active = next;
    // syncTabs drops it once empty.
  } else if (ui.active == terminalId) {
    ui.active.clear();
  }
  if (drawerIds(ui, terminalIds()).isEmpty()) ui.open = false;
  const TerminalPlace place = *m_place;
  m_client->call(this, place.environmentId, QStringLiteral("terminal.close"),
                 QJsonObject{
                     {QStringLiteral("threadId"), place.threadId},
                     {QStringLiteral("terminalId"), terminalId},
                     {QStringLiteral("deleteHistory"), true},
                 },
                 [this, threadKey, place, terminalId](const QJsonValue&, const std::optional<QString>& error) {
                   m_ui[threadKey].closing.remove(terminalId);
                   m_known[threadKey].remove(terminalId);
                   if (error) {
                     // The MC no longer has the session to close: ask the
                     // shell itself to leave, as the web's closeTerminal does.
                     m_client->call(this, place.environmentId, QStringLiteral("terminal.write"),
                                    QJsonObject{
                                        {QStringLiteral("threadId"), place.threadId},
                                        {QStringLiteral("terminalId"), terminalId},
                                        {QStringLiteral("data"), QStringLiteral("exit\n")},
                                    },
                                    [](const QJsonValue&, const std::optional<QString>&) {});
                   }
                   if (threadKey == m_threadKey) {
                     syncTabs();
                     emit changed();
                   }
                 });
  syncTabs();
  emit changed();
  if (panel && !next.isEmpty()) {
    emit focusRequested(next);
  } else if (!panel && m_ui[threadKey].open) {
    emit focusRequested(activeTerminalId());
  }
}

// A link the user followed in a terminal, as the web's handleLinkActivate: a
// web address goes to the browser (the desktop draws no pages itself), a file
// path to the editor, resolved against the folder the shell reported (OSC 7)
// or the one the terminal started in.
void TerminalController::followLink(const QString& kind, const QString& text, const QString& reportedCwd) {
  if (!m_place || text.isEmpty()) return;
  if (kind == QLatin1String("url")) {
    const QUrl url(text);
    if (url.isValid() && (url.scheme() == QLatin1String("http") || url.scheme() == QLatin1String("https"))) m_bridge->openExternal(url);
    return;
  }
  static const QRegularExpression position(QStringLiteral("^(.*?)((?::\\d+){0,2})$"));
  const QRegularExpressionMatch match = position.match(text);
  QString path = match.captured(1);
  QString cwd = reportedCwd.startsWith(QLatin1String("file://")) ? QUrl(reportedCwd).path() : reportedCwd;
  if (cwd.isEmpty()) cwd = m_place->cwd;
  static const QRegularExpression home(QStringLiteral("^(/Users/[^/]+|/home/[^/]+)"));
  if (path.startsWith(QLatin1String("~/"))) {
    // The home the folder sits in, as the web's inferHomeFromCwd.
    const QRegularExpressionMatch found = home.match(cwd);
    if (found.hasMatch()) path = found.captured(1) + path.mid(1);
  } else if (!path.startsWith(QLatin1Char('/'))) {
    path = QDir::cleanPath(cwd + QLatin1Char('/') + path);
  }
  auto* workspace = NativeShell::of(this)->controller<WorkspaceController>();
  if (!workspace || !workspace->openPath(path + match.captured(2))) {
    toast(QStringLiteral("Unable to open path"), QStringLiteral("This environment has no editor to open %1 in.").arg(path));
  }
}

bool TerminalController::runScript(const QString& scriptId) {
  if (!m_active || !m_place) return false;
  QJsonObject script;
  for (const QJsonValue& value : std::as_const(m_place->scripts)) {
    if (value.toObject().value(QLatin1String("id")).toString() == scriptId) script = value.toObject();
  }
  if (script.isEmpty()) return false;
  const QString name = script.value(QLatin1String("name")).toString();
  const QStringList ids = terminalIds();
  const QString active = activeTerminalId();
  QString terminalId = !active.isEmpty() ? active : !ids.isEmpty() ? ids.constFirst() : nextTerminalId();
  if (m_known.value(m_threadKey).value(terminalId).busy) {
    if (ids.size() >= maxTerminals) {
      toast(QStringLiteral("At most %1 terminals per thread.").arg(maxTerminals), QString());
      return true;
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
  m_client->call(this, place.environmentId, QStringLiteral("terminal.open"), input,
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
                   m_client->call(this, place.environmentId, QStringLiteral("terminal.write"),
                                  QJsonObject{
                                      {QStringLiteral("threadId"), place.threadId},
                                      {QStringLiteral("terminalId"), terminalId},
                                      {QStringLiteral("data"), command},
                                  },
                                  [this, failed](const QJsonValue&, const std::optional<QString>& error) {
                                    if (error) toast(failed, *error);
                                  });
                 });
  return true;
}

// The lowest free `term-N`, as packages/shared nextTerminalId; ids still
// closing stay taken until the MC lets go of them.
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
  NativeShell::of(this)->controller<ToastController>()->show(QStringLiteral("error"), title, description);
}
