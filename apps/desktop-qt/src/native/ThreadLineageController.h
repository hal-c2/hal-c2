#pragma once

// The open thread's relatives (the web's ThreadRelationshipsControl): the
// thread it was forked from and the forks made of it, from the shell's rows
// (`lineage`, `forkedFrom`), and forking and merging back.
//
// Publishes `lineage`: null for a thread with no relatives, else {threadKey,
// title ("Lineage", or "Lineage · 2 running"), runningCount, parent: {key,
// title, missing} or null (missing: the row is gone, "This related thread is
// unavailable"), forks: [{key, title, running}], canMerge, mergeHint}.
//
// Actions: `lineage.open {key}` opens a relative; `lineage.mergeBack` merges
// the fork's latest finished run back into its parent (`thread.merge_back`)
// and opens the parent; `thread.forkFromRun {runId}` forks the open thread at
// a response's run (`thread.fork` with that run as its source) and opens the
// fork once the shell lists it, saying so when it does not arrive.

#include <QJsonObject>
#include <QTimer>
#include <QUuid>
#include <QVariantMap>

#include <memory>

#include "McClient.h"
#include "NativeController.h"
#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"
#include "ShellStore.h"
#include "SidebarModel.h"
#include "ToastController.h"

class ThreadLineageController : public QObject, public NativeController {
  Q_OBJECT

public:
  ThreadLineageController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent)
      : QObject(parent), m_bridge(bridge), m_client(client), m_store(store) {}

  void activate() override {
    if (m_active) return;
    m_active = true;
    connect(navigation(), &NavigationController::changed, this, &ThreadLineageController::publish);
    connect(m_store, &ShellStore::changed, this, &ThreadLineageController::publish);
    publish();
  }

  bool handle(const QString& action, const QVariant& payload) override {
    if (!m_active) return false;
    const QVariantMap input = payload.toMap();
    if (action == QLatin1String("lineage.open")) {
      const QString key = input.value(QStringLiteral("key")).toString();
      if (m_store->thread(key)) navigation()->open(NavigationController::Route::thread(key));
    } else if (action == QLatin1String("lineage.mergeBack")) {
      mergeBack();
    } else if (action == QLatin1String("thread.forkFromRun")) {
      forkFrom(input.value(QStringLiteral("runId")).toString());
    } else {
      return false;
    }
    return true;
  }

private:
  NavigationController* navigation() const { return NativeShell::of(this)->controller<NavigationController>(); }
  ToastController* toasts() const { return NativeShell::of(this)->controller<ToastController>(); }

  static QString environmentOf(const QString& key) { return key.left(key.indexOf(QLatin1Char(':'))); }

  // The thread a fork came from: where it was forked (`forkedFrom`), else its lineage's parent.
  static QString parentId(const QJsonObject& row) {
    const QJsonObject lineage = row.value(QLatin1String("lineage")).toObject();
    if (lineage.value(QLatin1String("relationshipToParent")).toString() != QLatin1String("fork")) return {};
    const QString forkedFrom = row.value(QLatin1String("forkedFrom")).toObject().value(QLatin1String("threadId")).toString();
    return forkedFrom.isEmpty() ? lineage.value(QLatin1String("parentThreadId")).toString() : forkedFrom;
  }

  static bool running(const sidebar::Thread& thread) { return sidebar::status(thread) == QLatin1String("working"); }

  void mergeBack() {
    const QString key = navigation()->threadKey();
    const auto thread = m_store->thread(key);
    const QString parent = parentId(m_store->threadRow(key));
    if (!thread || parent.isEmpty() || !thread->latestRun || thread->latestRun->status != QLatin1String("completed")) return;
    const QString parentKey = thread->environmentId + QLatin1Char(':') + parent;
    m_client->dispatchCommand(this, thread->environmentId,
                              {{QStringLiteral("type"), QStringLiteral("thread.merge_back")},
                               {QStringLiteral("createdBy"), QStringLiteral("user")},
                               {QStringLiteral("creationSource"), QStringLiteral("web")},
                               {QStringLiteral("sourceThreadId"), thread->id},
                               {QStringLiteral("targetThreadId"), parent},
                               {QStringLiteral("sourcePoint"), QJsonObject{{QStringLiteral("type"), QStringLiteral("run")}, {QStringLiteral("runId"), thread->latestRun->runId}}}},
                              [this, parentKey](const QJsonValue&, const std::optional<QString>& error) {
                                if (error) {
                                  toasts()->error(QStringLiteral("Failed to merge back"), *error);
                                } else {
                                  navigation()->open(NavigationController::Route::thread(parentKey));
                                }
                              });
  }

  void forkFrom(const QString& runId) {
    const QString key = navigation()->threadKey();
    const auto thread = m_store->thread(key);
    if (!thread || runId.isEmpty() || !m_store->threadOnline(key)) return;
    const QString target = QUuid::createUuid().toString(QUuid::WithoutBraces);
    const QString targetKey = thread->environmentId + QLatin1Char(':') + target;
    m_client->dispatchCommand(this, thread->environmentId,
                              {{QStringLiteral("type"), QStringLiteral("thread.fork")},
                               {QStringLiteral("createdBy"), QStringLiteral("user")},
                               {QStringLiteral("creationSource"), QStringLiteral("web")},
                               {QStringLiteral("sourceThreadId"), thread->id},
                               {QStringLiteral("targetThreadId"), target},
                               {QStringLiteral("sourcePoint"), QJsonObject{{QStringLiteral("type"), QStringLiteral("run")}, {QStringLiteral("runId"), runId}}},
                               {QStringLiteral("title"), thread->title + QStringLiteral(" fork")}},
                              [this, targetKey](const QJsonValue&, const std::optional<QString>& error) {
                                if (error) {
                                  toasts()->error(QStringLiteral("Failed to fork this response."), *error);
                                  return;
                                }
                                openWhenListed(targetKey);
                              });
  }

  // The fork's row follows the command's answer; one that never comes is said.
  void openWhenListed(const QString& key) {
    if (m_store->thread(key)) {
      navigation()->open(NavigationController::Route::thread(key));
      return;
    }
    auto waiting = std::make_shared<QMetaObject::Connection>();
    auto* timeout = new QTimer(this);
    timeout->setSingleShot(true);
    *waiting = connect(m_store, &ShellStore::changed, this, [this, key, waiting, timeout] {
      if (!m_store->thread(key)) return;
      disconnect(*waiting);
      timeout->deleteLater();
      navigation()->open(NavigationController::Route::thread(key));
    });
    connect(timeout, &QTimer::timeout, this, [this, waiting, timeout] {
      disconnect(*waiting);
      timeout->deleteLater();
      toasts()->error(QStringLiteral("The fork was created, but it did not reach this client"),
                      QStringLiteral("Reconnect and try opening it from the thread list."));
    });
    timeout->start(m_arrivalTimeoutMs);
  }

  void publish() {
    if (!m_active) return;
    const QString key = navigation()->threadKey();
    const auto thread = key.isEmpty() ? std::nullopt : m_store->thread(key);
    if (!thread) {
      m_bridge->publish(QStringLiteral("lineage"), QVariant::fromValue(nullptr));
      return;
    }
    const QJsonObject row = m_store->threadRow(key);
    const QString parent = parentId(row);
    QVariant parentState = QVariant::fromValue(nullptr);
    QString parentTitle;
    int runningCount = 0;
    if (!parent.isEmpty()) {
      const QString parentKey = thread->environmentId + QLatin1Char(':') + parent;
      const auto parentThread = m_store->thread(parentKey);
      parentTitle = parentThread ? parentThread->title : QString();
      if (parentThread && running(*parentThread)) ++runningCount;
      parentState = QVariantMap{{QStringLiteral("key"), parentKey},
                                {QStringLiteral("title"), parentThread ? parentThread->title : QStringLiteral("This related thread is unavailable")},
                                {QStringLiteral("missing"), !parentThread.has_value()}};
    }
    QVariantList forks;
    for (const sidebar::Thread& other : m_store->threads()) {
      if (other.environmentId != thread->environmentId || other.archivedAt) continue;
      if (parentId(m_store->threadRow(other.key())) != thread->id) continue;
      if (running(other)) ++runningCount;
      forks.append(QVariantMap{{QStringLiteral("key"), other.key()}, {QStringLiteral("title"), other.title}, {QStringLiteral("running"), running(other)}});
    }
    if (parent.isEmpty() && forks.isEmpty()) {
      m_bridge->publish(QStringLiteral("lineage"), QVariant::fromValue(nullptr));
      return;
    }
    const bool finished = thread->latestRun && thread->latestRun->status == QLatin1String("completed");
    const bool canMerge = !parent.isEmpty() && !parentTitle.isEmpty() && finished;
    m_bridge->publish(QStringLiteral("lineage"),
                      QVariantMap{{QStringLiteral("threadKey"), key},
                                  {QStringLiteral("title"), runningCount > 0 ? QStringLiteral("Lineage · %1 running").arg(runningCount) : QStringLiteral("Lineage")},
                                  {QStringLiteral("runningCount"), runningCount},
                                  {QStringLiteral("parent"), parentState},
                                  {QStringLiteral("forks"), forks},
                                  {QStringLiteral("canMerge"), canMerge},
                                  {QStringLiteral("mergeHint"), parent.isEmpty() ? QString()
                                                                : !finished      ? QStringLiteral("Complete a run in this fork before merging it back")
                                                                : parentTitle.isEmpty() ? QStringLiteral("Merge this conversation back into its source")
                                                                                        : QStringLiteral("Merge this conversation back into %1").arg(parentTitle)}});
  }

public:
  // How long a fork's row may take to arrive; tests shorten it.
  void setArrivalTimeout(int ms) { m_arrivalTimeoutMs = ms; }

private:
  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  bool m_active = false;
  int m_arrivalTimeoutMs = 5000;
};
