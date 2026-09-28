#pragma once

#include <QDateTime>
#include <QObject>
#include <QVariant>

#include <functional>

class NodeClient;
class ShellBridge;
class ShellStore;

// The composer's turn RPCs once the shell has its own node connection: stop
// goes straight to the node, and so does a plain send (text only, one model)
// the page has marked `nativeSend`. Anything richer, such as attachments,
// slash commands, drafts or plan follow-ups, stays with the page's pipeline.
class ComposerController : public QObject {
  Q_OBJECT

public:
  ComposerController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() { m_active = true; }
  void setClock(std::function<QDateTime()> now) { m_now = std::move(now); }

  // The ShellBridge interceptor: true when the action was handled here.
  bool handle(const QString& action, const QVariant& payload);

private:
  bool interrupt();
  bool submit(const QVariantMap& payload);
  void toast(const QString& title, const QString& description);

  ShellBridge* m_bridge;
  NodeClient* m_client;
  ShellStore* m_store;
  std::function<QDateTime()> m_now = [] { return QDateTime::currentDateTimeUtc(); };
  bool m_active = false;
  bool m_sending = false;
};
