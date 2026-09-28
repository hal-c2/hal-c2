#pragma once

#include <QDateTime>
#include <QHash>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QVariant>

#include <functional>

#include "NativeController.h"

class NodeClient;
class ShellBridge;
class ShellStore;

// The composer's turn RPCs once the shell has its own node connection: stop
// goes straight to the node, and so does a plain send (text only, one model)
// the page has marked `nativeSend`. Anything richer, such as attachments,
// slash commands, drafts or plan follow-ups, stays with the page's pipeline.
class ComposerController : public QObject, public NativeController {
  Q_OBJECT

public:
  ComposerController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override { m_active = true; }
  bool isActive() const { return m_active; }
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }

  bool handle(const QString& action, const QVariant& payload) override;

private:
  struct Send {
    QString environmentId;
    QList<QJsonObject> commands;
    QString prompt;
    std::function<void(const QString&)> setText;
  };

  bool interrupt();
  bool submit(const QVariantMap& payload);
  void sendNext(const QString& target);
  // The thread the window shows (the shell's route), or empty.
  QString openThread() const;
  void toast(const QString& title, const QString& description);

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  bool m_active = false;
  // Each thread's sends, the one in flight first: a thread sends one at a
  // time, in the order the user sent them.
  QHash<QString, QList<Send>> m_queues;
};
