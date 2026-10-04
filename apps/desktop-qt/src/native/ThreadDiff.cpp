#include "ThreadDiff.h"

#include <QJsonArray>
#include <QRegularExpression>

#include "McClient.h"
#include "TimelineModel.h"

ThreadDiff::ThreadDiff(McClient* client, Notify notify, QObject* parent)
    : QObject(parent), m_client(client), m_notify(std::move(notify)) {}

void ThreadDiff::setThread(const QString& environmentId, const QString& threadId, TimelineModel* timeline) {
  const bool sameThread = environmentId == m_environment && threadId == m_threadId;
  if (sameThread && timeline == m_timeline) return;
  if (!sameThread) {
    m_environment = environmentId;
    m_threadId = threadId;
    ++m_request;
    m_loaded.clear();
    m_pendingReveal.clear();
    m_patch.clear();
    m_focus.clear();
    m_fileTotal = 0;
    emit focusChanged();
    m_model.clear();
    m_revertTurn = 0;
    m_reverting = false;
    emit revertChanged();
    if (m_selection != -1) {
      m_selection = -1;
      emit selectionChanged();
    }
    setStatus(QStringLiteral("idle"));
  }
  disconnect(m_checkpointsConnection);
  disconnect(m_workingConnection);
  m_timeline = timeline;
  if (timeline) {
    m_checkpointsConnection = connect(timeline, &TimelineModel::checkpointsChanged, this, &ThreadDiff::readCheckpoints);
    m_workingConnection = connect(timeline, &TimelineModel::workingChanged, this, &ThreadDiff::revertChanged);
  }
  readCheckpoints();
}

void ThreadDiff::setCheckout(const QString& cwd) {
  if (cwd == m_cwd) return;
  m_cwd = cwd;
  emit turnsChanged();
  emit selectionChanged();
  load();
}

int ThreadDiff::effectiveSelection() const {
  if (m_selection == -1 && m_turns.isEmpty() && !m_cwd.isEmpty()) return WorkingTree;
  return m_selection;
}

void ThreadDiff::setBaseRef(const QString& ref) {
  const QString next = ref.trimmed();
  if (next == m_baseRef) return;
  m_baseRef = next;
  emit reviewChanged();
  load();
}

void ThreadDiff::setActive(bool active) {
  m_active = active;
  load();
}

void ThreadDiff::readCheckpoints() {
  QMap<int, QJsonObject> turns;
  if (m_timeline) {
    const QHash<QString, QJsonObject> checkpoints = m_timeline->entities(QStringLiteral("checkpoint"));
    for (const QJsonObject& checkpoint : checkpoints) {
      const QJsonValue ordinal = checkpoint.value(QLatin1String("appRunOrdinal"));
      // The thread's baseline has no turn; one that failed or went missing has no diff.
      if (!ordinal.isDouble() || checkpoint.value(QLatin1String("status")).toString() != QLatin1String("ready")) continue;
      turns.insert(ordinal.toInt(), checkpoint);
    }
  }
  if (turns != m_turns) {
    m_turns = turns;
    emit turnsChanged();
    // A first turn takes the working tree's place as what opens.
    emit selectionChanged();
    emit revertChanged();
    // A turn that went away (rewound) leaves the picker on the latest one.
    if (m_selection > 0 && !m_turns.contains(m_selection)) {
      m_selection = -1;
      emit selectionChanged();
    }
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
  if (selection < Branch || (selection <= WorkingTree && m_cwd.isEmpty())) selection = -1;
  if (selection == m_selection) return;
  m_selection = selection;
  // Another selection is shown whole.
  m_focus.clear();
  emit selectionChanged();
  emit focusChanged();
  load();
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
  m_ignoreWhitespace = ignore;
  emit optionsChanged();
  load();
}

void ThreadDiff::setDefaultIgnoreWhitespace(bool ignore) {
  if (ignore == m_defaultIgnoreWhitespace) return;
  const bool before = ignoreWhitespace();
  m_defaultIgnoreWhitespace = ignore;
  if (ignoreWhitespace() == before) return;
  emit optionsChanged();
  load();
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
  if (status == m_status && message == m_message) return;
  m_status = status;
  m_message = message;
  emit statusChanged();
}

QString ThreadDiff::loadKey() const {
  if (reviewing()) {
    return QStringLiteral("%1:%2 review %3 %4 %5 %6").arg(m_environment, m_threadId).arg(effectiveSelection()).arg(m_cwd, m_baseRef).arg(m_ignoreWhitespace);
  }
  return QStringLiteral("%1:%2 %3 %4 %5")
      .arg(m_environment, m_threadId)
      .arg(m_selection == 0 ? QStringLiteral("all") : QStringLiteral("turn"))
      .arg(m_selection == 0 ? latestTurn() : shownTurn())
      .arg(ignoreWhitespace());
}

void ThreadDiff::reload() {
  m_loaded.clear();
  load();
}

void ThreadDiff::load() {
  if (!m_active || m_threadId.isEmpty()) return;
  if (!m_timeline) {
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
    if (error) {
      // Asking again (reload, another turn) tries once more.
      m_loaded.clear();
      m_patch.clear();
      m_model.clear();
      setStatus(QStringLiteral("error"), error->isEmpty() ? QStringLiteral("Could not load the diff.") : *error);
      return;
    }
    m_patch = result.toObject().value(QLatin1String("diff")).toString();
    present();
    if (m_model.fileCount() == 0) {
      setStatus(QStringLiteral("empty"), QStringLiteral("No net changes in this selection."));
    } else {
      setStatus(QStringLiteral("ready"));
    }
    if (!m_pendingReveal.isEmpty()) revealFile(std::exchange(m_pendingReveal, QString()));
  });
}

// review.getDiffPreview answers with both sources; the one selected is shown.
void ThreadDiff::loadReview(int selection) {
  const QString key = loadKey();
  if (key == m_loaded) return;
  m_loaded = key;
  const int request = ++m_request;
  QJsonObject payload{{QStringLiteral("cwd"), m_cwd}, {QStringLiteral("ignoreWhitespace"), m_ignoreWhitespace}};
  if (selection == Branch && !m_baseRef.isEmpty()) payload.insert(QStringLiteral("baseRef"), m_baseRef);
  setStatus(QStringLiteral("loading"), QStringLiteral("Loading changes..."));
  m_client->call(this, m_environment, QStringLiteral("review.getDiffPreview"), payload,
                 [this, request, selection](const QJsonValue& result, const std::optional<QString>& error) {
    if (request != m_request) return;
    if (error) {
      m_loaded.clear();
      m_patch.clear();
      m_model.clear();
      setStatus(QStringLiteral("error"), error->isEmpty() ? QStringLiteral("Could not load the diff.") : *error);
      return;
    }
    const QString kind = selection == Branch ? QStringLiteral("branch-range") : QStringLiteral("working-tree");
    QJsonObject source;
    for (const QJsonValue& value : result.toObject().value(QLatin1String("sources")).toArray()) {
      if (value.toObject().value(QLatin1String("kind")).toString() == kind) source = value.toObject();
    }
    m_comparedBase = source.value(QLatin1String("baseRef")).toString();
    m_comparedHead = source.value(QLatin1String("headRef")).toString();
    m_truncated = source.value(QLatin1String("truncated")).toBool();
    emit reviewChanged();
    m_patch = source.value(QLatin1String("diff")).toString();
    present();
    if (m_model.fileCount() > 0) {
      setStatus(QStringLiteral("ready"));
    } else if (selection == Branch) {
      setStatus(QStringLiteral("empty"), m_comparedBase.isEmpty() ? QStringLiteral("This branch has no base to compare against.")
                                                                 : QStringLiteral("No changes against %1.").arg(m_comparedBase));
    } else {
      setStatus(QStringLiteral("empty"), QStringLiteral("No uncommitted changes."));
    }
    if (!m_pendingReveal.isEmpty()) revealFile(std::exchange(m_pendingReveal, QString()));
  });
}

void ThreadDiff::present() {
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
  emit focusChanged();
}

void ThreadDiff::focusFile(const QString& path) {
  if (path == m_focus) return;
  m_focus = path;
  if (m_status == QLatin1String("ready")) present();
  emit focusChanged();
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
  m_revertTurn = turn;
  emit revertChanged();
}

void ThreadDiff::cancelRevert() {
  if (m_revertTurn == 0) return;
  m_revertTurn = 0;
  emit revertChanged();
}

void ThreadDiff::confirmRevert(bool restoreFiles) {
  const int turn = std::exchange(m_revertTurn, 0);
  if (turn == 0 || !m_turns.contains(turn) || !canRevert()) {
    emit revertChanged();
    return;
  }
  const QJsonObject checkpoint = m_turns.value(turn);
  m_reverting = true;
  emit revertChanged();
  const QString threadId = m_threadId;
  m_client->dispatchCommand(this, m_environment,
                            {{QStringLiteral("type"), QStringLiteral("checkpoint.rollback")},
                             {QStringLiteral("threadId"), threadId},
                             {QStringLiteral("checkpointId"), checkpoint.value(QLatin1String("id"))},
                             {QStringLiteral("scopeId"), checkpoint.value(QLatin1String("scopeId"))},
                             {QStringLiteral("restoreFiles"), restoreFiles}},
                            [this, turn, threadId](const QJsonValue&, const std::optional<QString>& error) {
                              if (threadId == m_threadId) {
                                m_reverting = false;
                                emit revertChanged();
                              }
                              if (error) {
                                m_notify(QStringLiteral("error"), QStringLiteral("Could not revert to turn %1").arg(turn),
                                         error->isEmpty() ? QStringLiteral("An error occurred.") : *error);
                                return;
                              }
                              m_notify(QStringLiteral("success"), QStringLiteral("Reverted to turn %1.").arg(turn), {});
                            });
}
