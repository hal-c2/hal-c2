#pragma once

#include <QObject>
#include <QString>
#include <QVariant>

#include <functional>

#include "NativeController.h"

class McClient;
class ShellBridge;
class ShellStore;

// What the user does with the plan the route's thread offers (`turn.plan`,
// ComposerController) besides implementing it there:
//
//   plan.implementInNewThread   a thread beside this one, in the same project
//                               and checkout, whose first message carries out
//                               the plan; the window moves to it. The planning
//                               thread keeps its plan card.
//   plan.copy                   the plan's markdown, to the clipboard.
//   plan.download               a markdown file of it in the Downloads folder.
//   plan.save {path}            the same file at `path` of the thread's
//                               workspace (`projects.writeFile`). An empty
//                               path is refused. It publishes `planSave`
//                               {saving, saved}: `saved` counts the writes
//                               that went through, so the dialog closes on
//                               one and stays open on a failure.
//
// Each says what came of it as a toast.
class PlanController : public QObject, public NativeController {
  Q_OBJECT

public:
  PlanController(ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent = nullptr);

  void activate() override {}
  bool handle(const QString& action, const QVariant& payload) override;

  // Where plan.download writes; the system's Downloads folder unless tests say.
  void setDownloadDirectory(const QString& path) { m_downloads = path; }
  // "tax-line.md" for a plan headed "Tax line".
  static QString fileName(const QString& markdown);
  // The folder the thread's files are written under: its worktree, else its
  // project's root; empty when it has neither.
  static QString workspaceRoot(ShellStore* store, const QString& threadKey);

private:
  void implementInNewThread(const QString& threadKey, const QVariantMap& plan);
  void download(const QVariantMap& plan);
  void save(const QString& threadKey, const QVariantMap& plan, const QString& path);
  void publishSave();

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  QString m_downloads;
  // An implementation thread is being started.
  bool m_starting = false;
  // A save to the workspace is in flight; how many went through.
  bool m_saving = false;
  int m_saved = 0;
};
