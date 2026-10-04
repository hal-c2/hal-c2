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
// ComposerController) besides implementing it there (the web's
// ProposedPlanCard and ChatView's implement-in-new-thread):
//
//   plan.implementInNewThread   a thread beside this one, in the same project
//                               and checkout, whose first message carries out
//                               the plan; the window moves to it. The planning
//                               thread keeps its plan card.
//   plan.copy                   the plan's markdown, to the clipboard.
//   plan.download               a markdown file of it in the Downloads folder.
//   plan.save {path}            the same file at `path` of the thread's
//                               workspace (`projects.writeFile`).
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
  // "tax-line.md" for a plan headed "Tax line" (the web's
  // buildProposedPlanMarkdownFilename).
  static QString fileName(const QString& markdown);

private:
  void implementInNewThread(const QString& threadKey, const QVariantMap& plan);
  void download(const QVariantMap& plan);
  void save(const QString& threadKey, const QVariantMap& plan, const QString& path);

  ShellBridge* m_bridge;
  McClient* m_client;
  ShellStore* m_store;
  QString m_downloads;
  // An implementation thread is being started.
  bool m_starting = false;
};
