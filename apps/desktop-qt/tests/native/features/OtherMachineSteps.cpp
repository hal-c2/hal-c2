// A thread whose files are on another machine than the desktop
// (files/file-viewer-and-editing.feature): no editor or file manager starts
// on that machine, and the user is told the files can't be opened here yet.

#include <QJsonArray>
#include <QJsonObject>

#include "FilesWorkspace.h"
#include "Harness.h"
#include "NavigationController.h"
#include "World.h"

namespace {

using namespace filesteps;

// What the MCs had been asked to start before the user acted.
struct Started {
  qsizetype calls = 0;
};

const QString kMemberThread = QStringLiteral("t-elsewhere");

// The user looks at a thread of "ops" on the cluster member "env-c".
void lookAtMemberThread(World& world) {
  world.servedFrom(kThisMachine);
  world.mc.join(QStringLiteral("mc-c"), QStringLiteral("env-c"));
  world.mc.sendPeerRow(QStringLiteral("env-c"), QStringLiteral("ops"),
                       {{QStringLiteral("id"), QStringLiteral("ops")},
                        {QStringLiteral("title"), QStringLiteral("ops")},
                        {QStringLiteral("workspaceRoot"), QStringLiteral("/work/ops")},
                        {QStringLiteral("scripts"), QJsonArray()}},
                       QStringLiteral("project"));
  world.mc.sendPeerRow(QStringLiteral("env-c"), kMemberThread,
                       {{QStringLiteral("id"), kMemberThread},
                        {QStringLiteral("title"), QStringLiteral("Deploy")},
                        {QStringLiteral("projectId"), QStringLiteral("ops")},
                        {QStringLiteral("createdAt"), QStringLiteral("2026-09-23T09:00:00Z")},
                        {QStringLiteral("updatedAt"), QStringLiteral("2026-09-23T09:00:00Z")}});
  world.sync();
  const QString key = QStringLiteral("env-c:") + kMemberThread;
  world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
  world.waitFor([&] { return world.state(QStringLiteral("workspace")).toMap().value(QStringLiteral("threadKey")) == key && !workspaceRoot(world).isEmpty(); },
                [&] { return QStringLiteral("the header to show %1; it shows %2").arg(key, show(world.state(QStringLiteral("workspace")))); });
}

QStringList toastTitles(World& world) {
  QStringList titles;
  for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
    titles.append(item.toMap().value(QStringLiteral("title")).toString());
  }
  return titles;
}

const Steps steps([] {
  step(QStringLiteral("the thread's files are on (another MC of the cluster|an MC on another machine the client is paired with|an MC reached through an SSH port forward)"),
       [](World& world, const Captures& c, const Table&) {
         // This machine's editors are the ones offered, wherever the thread runs.
         setConfig(world, {{QStringLiteral("availableEditors"), QJsonArray{QStringLiteral("vscode"), QStringLiteral("file-manager")}},
                           {QStringLiteral("shellRevealInFileManager"), true}});
         if (c[0] == QLatin1String("another MC of the cluster")) {
           lookAtMemberThread(world);
         } else {
           // An MC elsewhere says so by its machine's id, whatever address
           // reaches it: an SSH port forward is a loopback one.
           world.servedFrom(kOtherMachine);
           openFilesTab(world);
         }
         world.mc.part<Started>().calls = editorCalls(world).size();
       });

  step(QStringLiteral("the user reveals %1 in the file manager").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("files.reveal"), QVariantMap{{QStringLiteral("path"), c[0]}});
    world.sync();
  });
  step(QStringLiteral("the user opens %1 in an editor").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("files.openInEditor"), QVariantMap{{QStringLiteral("path"), c[0]}});
    world.sync();
  });
  step(QStringLiteral("the user follows the path %1 in a terminal").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("terminal.followLink"),
                            QVariantMap{{QStringLiteral("kind"), QStringLiteral("path")}, {QStringLiteral("text"), c[0]}, {QStringLiteral("cwd"), QString()}});
    world.sync();
  });

  step(QStringLiteral("nothing is started on that machine"), [](World& world, const Captures&, const Table&) {
    const QList<QJsonObject> calls = editorCalls(world).mid(world.mc.part<Started>().calls);
    expect(calls.isEmpty(), QStringLiteral("the MC was asked %1").arg(show(QVariant::fromValue(calls))));
  });
  step(QStringLiteral("the user is told the files are on another machine and can't be opened here yet"), [](World& world, const Captures&, const Table&) {
    const QString told = QStringLiteral("The files are on another machine and can't be opened here yet.");
    world.waitFor([&] { return toastTitles(world).contains(told); },
                  [&] { return QStringLiteral("\"%1\"; the toasts are %2").arg(told, show(world.state(QStringLiteral("toasts")))); });
  });
});

}  // namespace
