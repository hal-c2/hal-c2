#pragma once

#include <QList>
#include <QObject>
#include <QString>
#include <QVariant>

#include <optional>

#include "NativeController.h"

class NodeClient;
class ShellBridge;
class ShellStore;

// The shell's drafts: a new thread the user has opened but not sent yet, one
// per project folder, kept on this machine only (setStorePath) and listed at
// the top of the sidebar. Each draft carries the thread id its first send
// creates, so when that thread's row reaches the shell (or promote() is
// called) the draft is done and the window moves on to the thread.
//
// `thread.new {projectKey?}` opens the project's draft (the given logical
// project, else the scoped one, else the one the window shows, else the first),
// `draft.menu {draftId, x, y}` offers to delete it and `draft.delete {draftId}`
// does. The page follows a draft route with the draft's environmentId,
// projectId and threadId, and reports a draft it opened itself the same way
// (`route.open`), which adopts it.
//
// The draft's text is `text`: ComposerController saves the composer's edits
// on a draft route here, and reopens the draft with it.
class DraftController : public QObject, public NativeController {
  Q_OBJECT

public:
  struct Draft {
    QString id;
    QString environmentId;
    QString projectId;
    QString threadId;
    QString createdAt;
    QString text;

    QString threadKey() const { return environmentId + QLatin1Char(':') + threadId; }
  };

  DraftController(ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // Where the drafts are kept; loads them from there.
  void setStorePath(const QString& path);

  const QList<Draft>& drafts() const { return m_drafts; }
  std::optional<Draft> draft(const QString& id) const;
  // Opens the project's draft, creating it the first time; returns its id.
  QString start(const QString& environmentId, const QString& projectId);
  // Deletes the draft; the window leaves it if it was open.
  void remove(const QString& id);
  // The draft's first turn was sent as the thread `threadKey`: the draft is
  // done and the window shows the thread instead.
  void promote(const QString& threadKey);
  // The same for the draft `id`, whose thread may be on another environment
  // ("Run on").
  void promote(const QString& id, const QString& threadKey);
  void setText(const QString& id, const QString& text);

signals:
  void changed();

private:
  bool startNew(const QVariantMap& payload);
  void openMenu(const QString& id, double x, double y);
  // Drops drafts whose thread now exists or whose project is gone.
  void reconcile();
  void save() const;

  ShellBridge* m_bridge;
  ShellStore* m_store;
  QList<Draft> m_drafts;
  QString m_storePath;
  bool m_active = false;
};
