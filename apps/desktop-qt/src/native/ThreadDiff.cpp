#include "ThreadDiff.h"

#include <QGuiApplication>
#include <QJsonArray>
#include <QRegularExpression>

#include <algorithm>

#include "McClient.h"
#include "TimelineModel.h"

namespace {

const QString kAutomatic = QStringLiteral("automatic");
const QString kGone = QStringLiteral("Diff no longer available. Refresh the comparison.");

// A remote ref's branch: "origin/release" -> "release".
QString remoteBranch(const QJsonObject& ref) {
  const QString name = ref.value(QLatin1String("name")).toString();
  const QString remote = ref.value(QLatin1String("remoteName")).toString();
  if (!remote.isEmpty() && name.startsWith(remote + QLatin1Char('/'))) return name.mid(remote.size() + 1);
  return name;
}

}  // namespace

ThreadDiff::ThreadDiff(McClient* client, Notify notify, QObject* parent)
    : QObject(parent), m_client(client), m_notify(std::move(notify)) {
  connect(&m_model, &DiffModel::fileWanted, this, &ThreadDiff::loadFile);
  // Back from working elsewhere: the checkout may have moved on.
  if (qGuiApp) {
    connect(qGuiApp, &QGuiApplication::applicationStateChanged, this, [this](Qt::ApplicationState state) {
      if (state == Qt::ApplicationActive) follow();
    });
  }
}

ThreadDiff::Facts ThreadDiff::facts() const {
  return {choices(), latestTurn(), latestCheckpoint(), m_selection, shownTurn(), reviewing(), m_status, m_message, m_focus, m_fileTotal, m_baseRef, m_comparedBase,
          m_comparedHead, m_truncated, canRevert(), m_revertTurn, m_reverting};
}

void ThreadDiff::tell(const Facts& before) {
  const Facts now = facts();
  // The latest checkpoint's files can come after it is ready.
  if (now.choices != before.choices || now.latestTurn != before.latestTurn || now.latestCheckpoint != before.latestCheckpoint) emit turnsChanged();
  if (now.selection != before.selection || now.shownTurn != before.shownTurn || now.reviewing != before.reviewing) emit selectionChanged();
  if (now.status != before.status || now.message != before.message) emit statusChanged();
  if (now.focus != before.focus || now.fileTotal != before.fileTotal) emit focusChanged();
  if (now.baseRef != before.baseRef || now.comparedBase != before.comparedBase || now.comparedHead != before.comparedHead ||
      now.truncated != before.truncated) {
    emit reviewChanged();
  }
  // The branch under review is left out of the bases.
  if (now.comparedHead != before.comparedHead) emit basesChanged();
  if (now.canRevert != before.canRevert || now.revertTurn != before.revertTurn || now.reverting != before.reverting) emit revertChanged();
}

void ThreadDiff::setThread(const QString& environmentId, const QString& threadId, TimelineModel* timeline) {
  const bool sameThread = environmentId == m_environment && threadId == m_threadId;
  if (sameThread && timeline == m_timeline) return;
  const Facts before = facts();
  if (!sameThread) {
    if (!m_threadId.isEmpty()) m_choices.insert(m_environment + QLatin1Char(':') + m_threadId, {m_selection, m_baseRef});
    const Choice choice = m_choices.take(environmentId + QLatin1Char(':') + threadId);
    m_environment = environmentId;
    m_threadId = threadId;
    ++m_request;
    m_loaded.clear();
    m_pendingReveal.clear();
    m_patch.clear();
    m_focus.clear();
    m_fileTotal = 0;
    m_model.clear();
    m_comparedBase.clear();
    m_comparedHead.clear();
    m_truncated = false;
    m_revertTurn = 0;
    m_reverting = false;
    m_selection = choice.selection;
    m_baseRef = choice.baseRef;
    m_sourceKey.clear();
    m_lazy = false;
    m_refs = {};
    m_baseQuery.clear();
    ++m_basesRequest;
    m_basesLoading = false;
    emit basesChanged();
    setStatus(QStringLiteral("idle"));
  }
  disconnect(m_checkpointsConnection);
  disconnect(m_workingConnection);
  disconnect(m_workspaceConnection);
  m_timeline = timeline;
  m_mutation = timeline ? timeline->workspaceMutation() : QString();
  if (timeline) {
    m_checkpointsConnection = connect(timeline, &TimelineModel::checkpointsChanged, this, &ThreadDiff::readCheckpoints);
    m_workingConnection = connect(timeline, &TimelineModel::workingChanged, this, &ThreadDiff::revertChanged);
    m_workspaceConnection = connect(timeline, &TimelineModel::workspaceChanged, this, [this] {
      const QString now = m_timeline ? m_timeline->workspaceMutation() : QString();
      if (now == std::exchange(m_mutation, now)) return;
      follow();
    });
  }
  takeCheckpoints();
  tell(before);
}

void ThreadDiff::setCheckout(const QString& cwd) {
  if (cwd == m_cwd) return;
  const Facts before = facts();
  m_cwd = cwd;
  // Without a checkout there is nothing to review.
  if (m_cwd.isEmpty() && m_selection <= WorkingTree) m_selection = -1;
  load();
  tell(before);
}

int ThreadDiff::effectiveSelection() const {
  if (m_selection == -1 && m_turns.isEmpty() && !m_cwd.isEmpty()) return WorkingTree;
  return m_selection;
}

void ThreadDiff::setBaseRef(const QString& ref) {
  const QString next = ref.trimmed();
  if (next == m_baseRef) return;
  const Facts before = facts();
  m_baseRef = next;
  load();
  tell(before);
}

void ThreadDiff::setActive(bool active) {
  const Facts before = facts();
  m_active = active;
  load();
  tell(before);
}

void ThreadDiff::readCheckpoints() {
  const Facts before = facts();
  takeCheckpoints();
  tell(before);
}

void ThreadDiff::takeCheckpoints() {
  QMap<int, QJsonObject> turns;
  if (m_timeline) {
    const QHash<QString, QJsonObject> checkpoints = m_timeline->entities(QStringLiteral("checkpoint"));
    const QHash<QString, QJsonObject> runs = m_timeline->entities(QStringLiteral("run"));
    QList<QJsonObject> counted;
    for (const QJsonObject& checkpoint : checkpoints) {
      const QJsonValue ordinal = checkpoint.value(QLatin1String("appRunOrdinal"));
      // The thread's baseline has no turn; one that failed or went missing has no diff.
      if (!ordinal.isDouble() || checkpoint.value(QLatin1String("status")).toString() != QLatin1String("ready")) continue;
      // A checkpoint counts as a diff turn only for a completed run, as the MC
      // counts getTurnDiff's turns; a run the timeline does not hold (a test's
      // fixtures) is not evidence against it.
      const QString runId = checkpoint.value(QLatin1String("runId")).toString();
      const auto run = runs.constFind(runId);
      if (run != runs.constEnd() && run->value(QLatin1String("status")).toString() != QLatin1String("completed")) continue;
      counted.append(checkpoint);
    }
    std::sort(counted.begin(), counted.end(), [](const QJsonObject& left, const QJsonObject& right) {
      return left.value(QLatin1String("appRunOrdinal")).toInt() < right.value(QLatin1String("appRunOrdinal")).toInt();
    });
    for (qsizetype turn = 0; turn < counted.size(); ++turn) turns.insert(int(turn) + 1, counted.at(turn));
  }
  m_turns = turns;
  // A turn that went away (rewound) leaves the picker on the latest one, as
  // does all changes once no turn is left, and the checkout's choices without one.
  if ((m_selection > 0 && !m_turns.contains(m_selection)) || (m_selection == 0 && m_turns.isEmpty()) ||
      (m_selection <= WorkingTree && m_cwd.isEmpty())) {
    m_selection = -1;
  }
  load();
}

QVariantList ThreadDiff::choices() const {
  QVariantList choices;
  if (!m_turns.isEmpty()) {
    choices.append(QVariantMap{{QStringLiteral("value"), -1}, {QStringLiteral("label"), QStringLiteral("Latest turn")}});
    choices.append(QVariantMap{{QStringLiteral("value"), 0}, {QStringLiteral("label"), QStringLiteral("All changes")}});
    for (auto it = m_turns.constEnd(); it != m_turns.constBegin();) {
      --it;
      choices.append(QVariantMap{{QStringLiteral("value"), it.key()}, {QStringLiteral("label"), QStringLiteral("Turn %1").arg(it.key())}});
    }
  }
  if (!m_cwd.isEmpty()) {
    choices.append(QVariantMap{{QStringLiteral("value"), int(WorkingTree)}, {QStringLiteral("label"), QStringLiteral("Working tree")}});
    choices.append(QVariantMap{{QStringLiteral("value"), int(Branch)}, {QStringLiteral("label"), QStringLiteral("Branch changes")}});
  }
  return choices;
}

void ThreadDiff::select(int selection) {
  if (selection > 0 && !m_turns.contains(selection)) return;
  if (selection < Branch || (selection <= WorkingTree && m_cwd.isEmpty()) || (selection == 0 && m_turns.isEmpty())) selection = -1;
  if (selection == m_selection) return;
  const Facts before = facts();
  m_selection = selection;
  // Another selection is shown whole, even when it is the same diff.
  if (!m_focus.isEmpty()) {
    m_focus.clear();
    if (m_status == QLatin1String("ready")) present();
  }
  load();
  tell(before);
}

void ThreadDiff::selectRun(const QString& runId) {
  for (auto it = m_turns.cbegin(); it != m_turns.cend(); ++it) {
    if (it->value(QLatin1String("runId")).toString() == runId) {
      select(it.key());
      return;
    }
  }
}

int ThreadDiff::shownTurn() const {
  if (m_selection == 0 || reviewing()) return 0;
  return m_selection > 0 ? m_selection : latestTurn();
}

void ThreadDiff::setIgnoreWhitespace(bool ignore) {
  if (ignore == ignoreWhitespace()) return;
  const Facts before = facts();
  m_ignoreWhitespace = ignore;
  emit optionsChanged();
  load();
  tell(before);
}

void ThreadDiff::setDefaultIgnoreWhitespace(bool ignore) {
  if (ignore == m_defaultIgnoreWhitespace) return;
  const bool was = ignoreWhitespace();
  m_defaultIgnoreWhitespace = ignore;
  if (ignoreWhitespace() == was) return;
  const Facts before = facts();
  emit optionsChanged();
  load();
  tell(before);
}

void ThreadDiff::setDefaultWrap(bool wrap) {
  if (wrap == m_defaultWrap) return;
  const bool before = this->wrap();
  m_defaultWrap = wrap;
  if (this->wrap() != before) emit optionsChanged();
}

void ThreadDiff::setWrap(bool wrap) {
  if (wrap == this->wrap()) return;
  m_wrap = wrap;
  emit optionsChanged();
}

void ThreadDiff::setStatus(const QString& status, const QString& message) {
  m_status = status;
  m_message = message;
}

QString ThreadDiff::loadKey() const {
  if (reviewing()) {
    const int selection = effectiveSelection();
    return QStringLiteral("%1:%2 review %3 %4 %5 %6")
        .arg(m_environment, m_threadId)
        .arg(selection)
        .arg(m_cwd, selection == Branch ? m_baseRef : QString())
        .arg(ignoreWhitespace());
  }
  // The checkpoints the diff is between: a rewound turn's number comes back
  // with another checkpoint, and one being written becomes ready later.
  const int to = m_selection == 0 ? latestTurn() : shownTurn();
  const QString from = m_selection == 0 ? QString() : m_turns.value(to - 1).value(QLatin1String("id")).toString();
  return QStringLiteral("%1:%2 %3 %4 %5 %6 %7")
      .arg(m_environment, m_threadId)
      .arg(m_selection == 0 ? QStringLiteral("all") : QStringLiteral("turn"))
      .arg(to)
      .arg(from, m_turns.value(to).value(QLatin1String("id")).toString())
      .arg(ignoreWhitespace());
}

void ThreadDiff::reload() {
  const Facts before = facts();
  m_loaded.clear();
  load();
  tell(before);
}

void ThreadDiff::follow() {
  if (!reviewing()) return;
  const Facts before = facts();
  // A hidden tab loads when it is shown again.
  m_loaded.clear();
  m_quiet = m_status == QLatin1String("ready");
  load();
  m_quiet = false;
  tell(before);
}

void ThreadDiff::load() {
  if (!m_active || m_threadId.isEmpty()) return;
  if (!m_timeline) {
    // What is shown is asked for again once the timeline comes.
    ++m_request;
    m_loaded.clear();
    setStatus(QStringLiteral("loading"), QStringLiteral("Loading checkpoint diff..."));
    return;
  }
  if (reviewing()) {
    loadReview(effectiveSelection());
    return;
  }
  if (m_turns.isEmpty()) {
    ++m_request;
    m_loaded.clear();
    m_patch.clear();
    m_lazy = false;
    m_sourceKey.clear();
    m_fileTotal = 0;
    m_model.clear();
    setStatus(QStringLiteral("empty"), QStringLiteral("No completed turns yet."));
    return;
  }
  const QString key = loadKey();
  if (key == m_loaded) return;
  m_loaded = key;
  const int request = ++m_request;
  const int turn = shownTurn();
  QJsonObject payload{{QStringLiteral("threadId"), m_threadId}, {QStringLiteral("ignoreWhitespace"), ignoreWhitespace()}};
  QString method;
  if (m_selection == 0) {
    method = QStringLiteral("orchestration.getFullThreadDiff");
    payload.insert(QStringLiteral("toTurnCount"), latestTurn());
  } else {
    method = QStringLiteral("orchestration.getTurnDiff");
    payload.insert(QStringLiteral("fromTurnCount"), turn - 1);
    payload.insert(QStringLiteral("toTurnCount"), turn);
  }
  setStatus(QStringLiteral("loading"), QStringLiteral("Loading checkpoint diff..."));
  m_client->call(this, m_environment, method, payload, [this, request](const QJsonValue& result, const std::optional<QString>& error) {
    if (request != m_request) return;
    const Facts before = facts();
    if (error) {
      // Asking again (reload, another turn) tries once more.
      m_loaded.clear();
      m_patch.clear();
      m_lazy = false;
      m_sourceKey.clear();
      m_fileTotal = 0;
      m_model.clear();
      setStatus(QStringLiteral("error"), error->isEmpty() ? QStringLiteral("Could not load the diff.") : *error);
      tell(before);
      return;
    }
    const QString diff = result.toObject().value(QLatin1String("diff")).toString();
    m_patch = diff;
    m_lazy = false;
    m_sourceKey.clear();
    present();
    if (m_model.fileCount() == 0) {
      // Something came back, but no file of it can be shown.
      setStatus(QStringLiteral("empty"), diff.trimmed().isEmpty() ? QStringLiteral("No net changes in this selection.")
                                                                  : QStringLiteral("No patch available for this selection."));
    } else {
      setStatus(QStringLiteral("ready"));
    }
    tell(before);
    if (!m_pendingReveal.isEmpty()) revealFile(std::exchange(m_pendingReveal, QString()));
  });
}

// review.getDiffPreview answers with both sources; the one selected is shown.
void ThreadDiff::loadReview(int selection) {
  const QString key = loadKey();
  if (key == m_loaded) return;
  m_loaded = key;
  const int request = ++m_request;
  QJsonObject payload{{QStringLiteral("cwd"), m_cwd}, {QStringLiteral("ignoreWhitespace"), ignoreWhitespace()}};
  if (selection == Branch && !m_baseRef.isEmpty()) payload.insert(QStringLiteral("baseRef"), m_baseRef);
  if (!m_quiet) setStatus(QStringLiteral("loading"), QStringLiteral("Loading changes..."));
  m_client->call(this, m_environment, QStringLiteral("review.getDiffPreview"), payload,
                 [this, request, selection](const QJsonValue& result, const std::optional<QString>& error) {
    if (request != m_request) return;
    const Facts before = facts();
    if (error) {
      m_loaded.clear();
      m_patch.clear();
      m_sourceKey.clear();
      m_lazy = false;
      m_fileTotal = 0;
      m_model.clear();
      setStatus(QStringLiteral("error"), error->isEmpty() ? QStringLiteral("Could not load the diff.") : *error);
      tell(before);
      return;
    }
    const QString kind = selection == Branch ? QStringLiteral("branch-range") : QStringLiteral("working-tree");
    QJsonObject source;
    bool found = false;
    for (const QJsonValue& value : result.toObject().value(QLatin1String("sources")).toArray()) {
      if (value.toObject().value(QLatin1String("kind")).toString() == kind) {
        source = value.toObject();
        found = true;
      }
    }
    m_comparedBase = source.value(QLatin1String("baseRef")).toString();
    m_comparedHead = source.value(QLatin1String("headRef")).toString();
    m_truncated = source.value(QLatin1String("truncated")).toBool();
    const QJsonArray files = source.value(QLatin1String("files")).toArray();
    // The same answer again leaves what the user opened as it is.
    const QString hash = source.value(QLatin1String("diffHash")).toString();
    const QString sourceKey = found && !hash.isEmpty() ? QStringLiteral("%1 %2 %3").arg(kind, hash).arg(m_truncated) : QString();
    // A file focused or let go meanwhile changes what is shown of it.
    if (sourceKey.isEmpty() || sourceKey != m_sourceKey || m_focus != m_presented) {
      m_sourceKey = sourceKey;
      // Cut short with every file counted: each file's changes come when it is opened.
      m_lazy = m_truncated && !files.isEmpty();
      m_lazyKind = kind;
      m_patch = m_lazy ? QString() : DiffModel::withoutTruncatedMarker(source.value(QLatin1String("diff")).toString());
      if (m_lazy) {
        ++m_listing;
        m_model.setFiles(files);
        m_fileTotal = m_model.fileCount();
      }
      present();
    }
    if (m_model.fileCount() > 0) {
      setStatus(QStringLiteral("ready"));
    } else if (!found) {
      setStatus(QStringLiteral("empty"), QStringLiteral("No patch available for this selection."));
    } else if (selection == Branch && m_comparedBase.isEmpty()) {
      setStatus(QStringLiteral("empty"), QStringLiteral("This branch has no base to compare against."));
    } else if (!source.value(QLatin1String("diff")).toString().trimmed().isEmpty()) {
      // Something came back, but no file of it can be shown.
      setStatus(QStringLiteral("empty"), QStringLiteral("No patch available for this selection."));
    } else if (selection == Branch) {
      setStatus(QStringLiteral("empty"), QStringLiteral("No changes against %1.").arg(m_comparedBase));
    } else {
      setStatus(QStringLiteral("empty"), QStringLiteral("No uncommitted changes."));
    }
    tell(before);
    if (!m_pendingReveal.isEmpty()) revealFile(std::exchange(m_pendingReveal, QString()));
  });
}

// One file of a review cut short: its own patch, from the source it was listed by.
void ThreadDiff::loadFile(int file) {
  if (!m_lazy || file < 0 || file >= m_model.fileCount()) return;
  const QString path = m_model.path(file);
  const QString previous = m_model.previousPath(file);
  const int listing = m_listing;
  m_model.setFileState(file, QStringLiteral("loading"));
  QJsonObject payload{{QStringLiteral("cwd"), m_cwd},
                      {QStringLiteral("ignoreWhitespace"), ignoreWhitespace()},
                      {QStringLiteral("file"), QJsonObject{{QStringLiteral("path"), path},
                                                           {QStringLiteral("previousPath"), previous.isEmpty() ? QJsonValue() : QJsonValue(previous)},
                                                           {QStringLiteral("sourceKind"), m_lazyKind}}}};
  if (m_lazyKind == QLatin1String("branch-range") && !m_baseRef.isEmpty()) payload.insert(QStringLiteral("baseRef"), m_baseRef);
  m_client->call(this, m_environment, QStringLiteral("review.getDiffPreview"), payload,
                 [this, listing, path](const QJsonValue& result, const std::optional<QString>& error) {
    // Another diff is shown meanwhile; the same one asked for again keeps waiting for it.
    if (listing != m_listing || !m_lazy) return;
    const int file = m_model.fileOf(path);
    if (file < 0) return;
    if (error) {
      m_model.setFileState(file, QStringLiteral("error"), error->isEmpty() ? QStringLiteral("Could not load the diff.") : *error);
      return;
    }
    for (const QJsonValue& value : result.toObject().value(QLatin1String("sources")).toArray()) {
      const QJsonObject source = value.toObject();
      if (source.value(QLatin1String("kind")).toString() != m_lazyKind) continue;
      const bool partial = source.value(QLatin1String("truncated")).toBool();
      if (!m_model.setFilePatch(file, DiffModel::withoutTruncatedMarker(source.value(QLatin1String("diff")).toString()), partial)) {
        m_model.setFileState(file, QStringLiteral("missing"), QStringLiteral("No patch available for this file."));
      }
      return;
    }
    // The checkout no longer has what was listed.
    m_model.setFileState(file, QStringLiteral("gone"), kGone);
  });
}

void ThreadDiff::retryFile(const QString& path) {
  loadFile(m_model.fileOf(path));
}

QVariantList ThreadDiff::baseChoices() const {
  QList<QJsonObject> locals;
  QList<QJsonObject> remotes;
  for (const QJsonValue& value : m_refs) {
    const QJsonObject ref = value.toObject();
    if (ref.value(QLatin1String("isRemote")).toBool()) {
      remotes.append(ref);
    } else if (ref.value(QLatin1String("name")).toString() != m_comparedHead) {
      locals.append(ref);
    }
  }
  struct Entry {
    QString id;
    QString label;
    QString local;
    QString remote;
  };
  QList<Entry> entries;
  QList<bool> used(remotes.size(), false);
  // Each local branch with its remote one, origin's first.
  for (const QJsonObject& local : std::as_const(locals)) {
    const QString name = local.value(QLatin1String("name")).toString();
    qsizetype match = -1;
    for (qsizetype i = 0; i < remotes.size(); ++i) {
      if (used.at(i) || remoteBranch(remotes.at(i)) != name) continue;
      if (match < 0 || remotes.at(i).value(QLatin1String("remoteName")) == QLatin1String("origin")) match = i;
    }
    QString remote;
    if (match >= 0) {
      used[match] = true;
      remote = remotes.at(match).value(QLatin1String("name")).toString();
    }
    entries.append({QStringLiteral("local:") + name, name, name, remote});
  }
  for (qsizetype i = 0; i < remotes.size(); ++i) {
    if (used.at(i)) continue;
    const QString name = remotes.at(i).value(QLatin1String("name")).toString();
    entries.append({QStringLiteral("remote:") + name, name, QString(), name});
  }
  const QString query = m_baseQuery.trimmed().toLower();
  QVariantList out;
  if (query.isEmpty()) {
    out.append(QVariantMap{{QStringLiteral("id"), kAutomatic}, {QStringLiteral("label"), QStringLiteral("Automatic")},
                           {QStringLiteral("ref"), QString()}, {QStringLiteral("remoteOnly"), false}});
  }
  for (const Entry& entry : std::as_const(entries)) {
    if (!query.isEmpty() && !entry.label.toLower().contains(query) && !entry.local.toLower().contains(query) && !entry.remote.toLower().contains(query)) {
      continue;
    }
    out.append(QVariantMap{{QStringLiteral("id"), entry.id}, {QStringLiteral("label"), entry.label},
                           {QStringLiteral("ref"), entry.local.isEmpty() ? entry.remote : entry.local}, {QStringLiteral("remoteOnly"), entry.local.isEmpty()}});
  }
  return out;
}

void ThreadDiff::setBaseQuery(const QString& query) {
  if (query == m_baseQuery) return;
  m_baseQuery = query;
  emit basesChanged();
}

void ThreadDiff::loadBases() {
  if (m_cwd.isEmpty() || m_threadId.isEmpty()) return;
  const int request = ++m_basesRequest;
  m_basesLoading = true;
  emit basesChanged();
  // Every ref at once, filtered here: "origin/release" finds the local "release".
  m_client->call(this, m_environment, QStringLiteral("vcs.listRefs"),
                 QJsonObject{{QStringLiteral("cwd"), m_cwd}, {QStringLiteral("limit"), 500}, {QStringLiteral("includeMatchingRemoteRefs"), true}},
                 [this, request](const QJsonValue& result, const std::optional<QString>& error) {
                   if (request != m_basesRequest) return;
                   m_basesLoading = false;
                   if (!error) m_refs = result.toObject().value(QLatin1String("refs")).toArray();
                   emit basesChanged();
                 });
}

void ThreadDiff::chooseBase(const QString& id) {
  for (const QVariant& choice : baseChoices()) {
    if (choice.toMap().value(QStringLiteral("id")).toString() != id) continue;
    setBaseRef(choice.toMap().value(QStringLiteral("ref")).toString());
    return;
  }
}

void ThreadDiff::chooseTypedBase(const QString& text) {
  const QString typed = text.trimmed();
  if (typed.isEmpty() || typed.compare(QLatin1String("Automatic"), Qt::CaseInsensitive) == 0) {
    setBaseRef(QString());
    return;
  }
  for (const QVariant& choice : baseChoices()) {
    if (choice.toMap().value(QStringLiteral("label")).toString() == typed) {
      setBaseRef(choice.toMap().value(QStringLiteral("ref")).toString());
      return;
    }
  }
  setBaseRef(typed);
}

void ThreadDiff::present() {
  // A review cut short lists every file and shows none alone.
  if (m_lazy) {
    m_focus.clear();
    m_presented.clear();
    return;
  }
  m_model.setPatch(m_patch);
  m_fileTotal = m_model.fileCount();
  if (!m_focus.isEmpty()) {
    // The focused file's part of the patch: from its header to the next one.
    static const QRegularExpression header(QStringLiteral("^diff --git "), QRegularExpression::MultilineOption);
    const int file = m_model.fileOf(m_focus);
    QList<qsizetype> starts;
    for (auto it = header.globalMatch(m_patch); it.hasNext();) starts.append(it.next().capturedStart());
    if (file >= 0 && file < starts.size()) {
      const qsizetype end = file + 1 < starts.size() ? starts.at(file + 1) : m_patch.size();
      m_model.setPatch(m_patch.mid(starts.at(file), end - starts.at(file)));
      m_model.setExpanded(0, true);
    } else {
      m_focus.clear();
    }
  }
  m_presented = m_focus;
}

void ThreadDiff::focusFile(const QString& path) {
  if (path == m_focus) return;
  const Facts before = facts();
  m_focus = path;
  if (m_status == QLatin1String("ready")) present();
  tell(before);
}

bool ThreadDiff::comment(const QString& path, const QString& side, int first, int last, const QString& note) {
  const QString text = note.trimmed();
  if (text.isEmpty() || m_status != QLatin1String("ready")) return false;
  if (last < first) std::swap(first, last);
  QVariantMap comment = m_model.excerpt(m_model.fileOf(path), side, first, last);
  if (comment.isEmpty()) return false;
  // What is being reviewed, as the picker names it.
  QString section;
  for (const QVariant& choice : choices()) {
    if (choice.toMap().value(QStringLiteral("value")).toInt() == effectiveSelection()) section = choice.toMap().value(QStringLiteral("label")).toString();
  }
  comment.insert(QStringLiteral("sectionTitle"), section.isEmpty() ? QStringLiteral("Diff") : section);
  comment.insert(QStringLiteral("sectionId"), QStringLiteral("diff:%1").arg(effectiveSelection()));
  comment.insert(QStringLiteral("filePath"), path);
  comment.insert(QStringLiteral("lineStart"), first);
  comment.insert(QStringLiteral("lineEnd"), last);
  comment.insert(QStringLiteral("text"), text);
  emit commentRequested(comment);
  return true;
}

void ThreadDiff::showAllFiles() {
  focusFile({});
}

void ThreadDiff::revealFile(const QString& path) {
  if (path.isEmpty()) return;
  if (m_status != QLatin1String("ready")) {
    m_pendingReveal = path;
    return;
  }
  const int file = m_model.fileOf(path);
  if (file < 0) return;
  m_model.setExpanded(file, true);
  emit revealRow(m_model.rowOfFile(file));
}

bool ThreadDiff::canRevert() const {
  return !m_turns.isEmpty() && !m_reverting && !(m_timeline && m_timeline->working());
}

void ThreadDiff::requestRevert(int turn) {
  if (turn <= 0) turn = shownTurn() > 0 ? shownTurn() : latestTurn();
  if (!canRevert() || !m_turns.contains(turn)) return;
  const Facts before = facts();
  m_revertTurn = turn;
  tell(before);
}

void ThreadDiff::cancelRevert() {
  if (m_revertTurn == 0) return;
  const Facts before = facts();
  m_revertTurn = 0;
  tell(before);
}

void ThreadDiff::confirmRevert(bool restoreFiles) {
  const Facts before = facts();
  const int turn = std::exchange(m_revertTurn, 0);
  if (turn == 0 || !m_turns.contains(turn) || !canRevert()) {
    tell(before);
    return;
  }
  const QJsonObject checkpoint = m_turns.value(turn);
  m_reverting = true;
  tell(before);
  const QString threadId = m_threadId;
  m_client->dispatchCommand(this, m_environment,
                            {{QStringLiteral("type"), QStringLiteral("checkpoint.rollback")},
                             {QStringLiteral("threadId"), threadId},
                             {QStringLiteral("checkpointId"), checkpoint.value(QLatin1String("id"))},
                             {QStringLiteral("scopeId"), checkpoint.value(QLatin1String("scopeId"))},
                             {QStringLiteral("restoreFiles"), restoreFiles}},
                            [this, turn, threadId](const QJsonValue&, const std::optional<QString>& error) {
                              if (threadId == m_threadId) {
                                const Facts before = facts();
                                m_reverting = false;
                                tell(before);
                              }
                              if (error) {
                                m_notify(QStringLiteral("error"), QStringLiteral("Could not revert to turn %1").arg(turn),
                                         error->isEmpty() ? QStringLiteral("An error occurred.") : *error);
                                return;
                              }
                              m_notify(QStringLiteral("success"), QStringLiteral("Reverted to turn %1.").arg(turn), {});
                            });
}

QString ThreadDiff::workspacePath(const QString& path) const {
  if (m_folder.isEmpty()) return path;
  const QString prefix = m_folder + QLatin1Char('/');
  return path.startsWith(prefix) ? path.mid(prefix.size()) : QString();
}
