#include "ThreadDiff.h"

#include <QJsonArray>

#include "NodeClient.h"
#include "TimelineModel.h"

ThreadDiff::ThreadDiff(NodeClient* client, Notify notify, QObject* parent)
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
  if (m_turns.isEmpty()) return {};
  QVariantList choices{
      QVariantMap{{QStringLiteral("value"), -1}, {QStringLiteral("label"), QStringLiteral("Latest turn")}},
      QVariantMap{{QStringLiteral("value"), 0}, {QStringLiteral("label"), QStringLiteral("All changes")}},
  };
  for (auto it = m_turns.constEnd(); it != m_turns.constBegin();) {
    --it;
    choices.append(QVariantMap{{QStringLiteral("value"), it.key()}, {QStringLiteral("label"), QStringLiteral("Turn %1").arg(it.key())}});
  }
  return choices;
}

void ThreadDiff::select(int selection) {
  if (selection > 0 && !m_turns.contains(selection)) return;
  if (selection < -1) selection = -1;
  if (selection == m_selection) return;
  m_selection = selection;
  emit selectionChanged();
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
  if (m_selection == 0) return 0;
  return m_selection > 0 ? m_selection : latestTurn();
}

void ThreadDiff::setIgnoreWhitespace(bool ignore) {
  if (ignore == m_ignoreWhitespace) return;
  m_ignoreWhitespace = ignore;
  emit optionsChanged();
  load();
}

void ThreadDiff::setWrap(bool wrap) {
  if (wrap == m_wrap) return;
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
  return QStringLiteral("%1:%2 %3 %4 %5")
      .arg(m_environment, m_threadId)
      .arg(m_selection == 0 ? QStringLiteral("all") : QStringLiteral("turn"))
      .arg(m_selection == 0 ? latestTurn() : shownTurn())
      .arg(m_ignoreWhitespace);
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
  if (m_turns.isEmpty()) {
    ++m_request;
    m_loaded.clear();
    m_model.clear();
    setStatus(QStringLiteral("empty"), QStringLiteral("No completed turns yet."));
    return;
  }
  const QString key = loadKey();
  if (key == m_loaded) return;
  m_loaded = key;
  const int request = ++m_request;
  const int turn = shownTurn();
  QJsonObject payload{{QStringLiteral("threadId"), m_threadId}, {QStringLiteral("ignoreWhitespace"), m_ignoreWhitespace}};
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
      m_model.clear();
      setStatus(QStringLiteral("error"), error->isEmpty() ? QStringLiteral("Could not load the diff.") : *error);
      return;
    }
    m_model.setPatch(result.toObject().value(QLatin1String("diff")).toString());
    if (m_model.fileCount() == 0) {
      setStatus(QStringLiteral("empty"), QStringLiteral("No net changes in this selection."));
    } else {
      setStatus(QStringLiteral("ready"));
    }
    if (!m_pendingReveal.isEmpty()) revealFile(std::exchange(m_pendingReveal, QString()));
  });
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
