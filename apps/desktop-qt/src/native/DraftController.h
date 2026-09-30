#pragma once

#include <QList>
#include <QObject>
#include <QString>
#include <QVariant>

#include <optional>

#include "NativeController.h"
#include "SidebarModel.h"

class NodeClient;
class ShellBridge;
class ShellStore;

// The shell's drafts: a new thread the user has opened but not sent yet, one
// per project folder, kept on this machine only (setStorePath) and listed at
// the top of the sidebar once they hold something (SidebarController). Every window's controller keeps the same drafts
// (NativeShell::common), so a window that closes leaves them to the others. Each draft carries the thread id its first send
// creates, so when that thread's row reaches the shell (or promote() is
// called) the draft is done and the window moves on to the thread.
//
// `thread.new {projectKey?}` opens the project's draft (the given logical
// project, else the scoped one, else the one the window shows, else the first),
// `draft.menu {draftId, x, y}` offers to delete it and `draft.delete {draftId}`
// does.
//
// The draft's text is `text`: ComposerController saves the composer's edits
// on a draft route here, and reopens the draft with it.
//
// It registers the palette's two ways to start a thread: chat.new ("New
// thread in <project>", listed while the window shows a project) and the
// thread.newIn menu ("New thread in...", the window's project first).
//
// A window with no thread lands on a draft, as the web's index route does:
// on `home`, once the node's snapshot is in, it opens the draft of the most
// recently active project (sidebar::mostRecentProject), the same draft every
// other window landing there opens. With no project it stays home, which
// offers to add one. A draft that cannot be kept publishes `landing`
// {failed: true} until `landing.retry` or the window goes elsewhere.
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
  // Opens the project's draft, creating it the first time; returns its id, or
  // nothing when a new draft could not be kept (its store is not writable).
  QString start(const QString& environmentId, const QString& projectId);
  // Opens the draft of the logical project `group` (see startIn below).
  void startIn(const sidebar::ProjectGroup& group);
  // On `home`, opens the most recent project's draft (see above).
  void land();
  // Deletes the draft; every window that shows it leaves it.
  void remove(const QString& id);
  // The draft's first turn was sent as the thread `threadKey`: the draft is
  // done and every window that showed it shows the thread instead.
  void promote(const QString& threadKey);
  // The same for the draft `id`, whose thread may be on another environment
  // ("Run on"). Takes its own copy of the id: the draft it may name is erased.
  void promote(QString id, const QString& threadKey);
  void setText(const QString& id, const QString& text);
  // Gives the draft a new thread id and clears its text: its old thread was
  // started in the background and the draft stays for another prompt.
  void renew(const QString& id);

signals:
  void changed();

private:
  bool startNew(const QVariantMap& payload);
  // The thread or draft the window shows: its environment and project.
  std::optional<std::pair<QString, QString>> shownProject() const;
  // The logical project a new thread starts in without being told.
  const sidebar::ProjectGroup* defaultGroup() const;
  void present();
  void openMenu(const QString& id, double x, double y);
  // Drops drafts whose thread now exists or whose project is gone.
  void reconcile();
  bool save() const;
  void setLandingFailed(bool failed);
  // Every window's controller, this one's included.
  QList<DraftController*> everyWindow() const;
  void changedEverywhere();

  // What every window's controller keeps.
  struct Kept {
    QList<Draft> drafts;
    QString path;
  };

  ShellBridge* m_bridge;
  ShellStore* m_store;
  Kept& m_kept;
  QList<Draft>& m_drafts;
  bool m_active = false;
  bool m_landingFailed = false;
};
