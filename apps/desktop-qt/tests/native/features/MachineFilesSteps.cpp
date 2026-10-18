// Another machine's files opened from the folder the MC on this machine keeps
// for it (files/files-on-another-machine.feature): the shell asks its MC where a
// cluster member's file is here (`files.localPath`), and starts the editor or
// file manager through that MC, never the member's.

#include <QJsonArray>
#include <QJsonObject>

#include "FilesWorkspace.h"
#include "Harness.h"
#include "NavigationController.h"
#include "World.h"

namespace {

using namespace filesteps;

// What the MC on this machine answers `files.localPath` with.
struct MachineFolders {
  // Where the MC mounts its members' folders.
  QString root = QStringLiteral("/home/user/.local/state/hal-c2/elixir/machines");
  // An MC from before files.localPath answers null.
  bool answers = false;
  // Without FUSE the MC says so instead of a path.
  bool canShow = true;
  // The editor calls made before the user acted.
  qsizetype callsBefore = 0;
};

const QString kThread = QStringLiteral("t-cart");

const FakeMc::Extension extension([](FakeMc& mc) {
  mc.onRpc(QStringLiteral("files.localPath"), [&mc](const FakeMc::Rpc& rpc) {
    const MachineFolders& folders = mc.part<MachineFolders>();
    if (!folders.answers) {
      mc.reply(rpc, QJsonValue::Null);
      return;
    }
    const QString environment = rpc.payload.value(QLatin1String("environmentId")).toString();
    const QString path = rpc.payload.value(QLatin1String("path")).toString();
    if (!mc.members.contains(environment)) {
      mc.reply(rpc, QJsonObject{{QStringLiteral("reason"), QStringLiteral("not_a_member")},
                                {QStringLiteral("message"), QStringLiteral("The file is on a machine that is not in this machine's cluster.")}});
      return;
    }
    const QString label = mc.peerLabels.value(environment, environment);
    if (!folders.canShow) {
      mc.reply(rpc, QJsonObject{{QStringLiteral("reason"), QStringLiteral("no_fuse")},
                                {QStringLiteral("machine"), label},
                                {QStringLiteral("message"), QStringLiteral("The file is on \"%1\". To open it here, install FUSE 3 (fuse3).").arg(label)}});
      return;
    }
    mc.reply(rpc, QJsonObject{{QStringLiteral("path"), folders.root + QLatin1Char('/') + label + path}});
  });
});

// Every `shell.openInEditor` since the user acted, with the MC it went to.
QList<FakeMc::Rpc> startedSinceActing(World& world) {
  world.sync();
  QList<FakeMc::Rpc> started;
  for (const FakeMc::Rpc& rpc : std::as_const(world.mc.calls)) {
    if (rpc.method == QLatin1String("shell.openInEditor")) started.append(rpc);
  }
  return started.mid(world.mc.part<MachineFolders>().callsBefore);
}

QString describe(const QList<FakeMc::Rpc>& calls) {
  QStringList told;
  for (const FakeMc::Rpc& rpc : calls) told.append(QStringLiteral("%1 on \"%2\"").arg(show(rpc.payload.toVariantMap()), rpc.environment));
  return told.isEmpty() ? QStringLiteral("nothing") : told.join(QStringLiteral(", "));
}

QStringList toastTitles(World& world) {
  QStringList titles;
  for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
    titles.append(item.toMap().value(QStringLiteral("title")).toString());
  }
  return titles;
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("the client is connected to the MC on the user's machine"), [](World& world, const Captures&, const Table&) {
    world.mc.part<MachineFolders>().answers = true;
    world.connect();
    world.servedFrom(kThisMachine);
    // This machine's editors and file manager.
    setConfig(world, {{QStringLiteral("availableEditors"), QJsonArray{QStringLiteral("vscode"), QStringLiteral("file-manager")}},
                      {QStringLiteral("shellRevealInFileManager"), true}});
  });
  step(QStringLiteral("that MC is in a cluster with %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.join(c[0]);
    world.sync();
  });
  step(QStringLiteral("%1 has the project %1 at %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.sendPeerRow(c[0], c[1],
                         {{QStringLiteral("id"), c[1]},
                          {QStringLiteral("title"), c[1]},
                          {QStringLiteral("workspaceRoot"), c[2]},
                          {QStringLiteral("scripts"), QJsonArray()}},
                         QStringLiteral("project"));
    world.sync();
  });
  step(QStringLiteral("this machine has no way to show another machine's folder"), [](World& world, const Captures&, const Table&) {
    world.mc.part<MachineFolders>().canShow = false;
  });

  step(QStringLiteral("a thread of %1 runs on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    world.mc.sendPeerRow(c[1], kThread,
                         {{QStringLiteral("id"), kThread},
                          {QStringLiteral("title"), QStringLiteral("Cart")},
                          {QStringLiteral("projectId"), c[0]},
                          {QStringLiteral("createdAt"), QStringLiteral("2026-10-16T09:00:00Z")},
                          {QStringLiteral("updatedAt"), QStringLiteral("2026-10-16T09:00:00Z")}});
    world.sync();
    const QString key = c[1] + QLatin1Char(':') + kThread;
    world.native().controller<NavigationController>()->open(NavigationController::Route::thread(key));
    world.waitFor([&] { return world.state(QStringLiteral("workspace")).toMap().value(QStringLiteral("threadKey")) == key && !workspaceRoot(world).isEmpty(); },
                  [&] { return QStringLiteral("the header to show %1; it shows %2").arg(key, show(world.state(QStringLiteral("workspace")))); });
    openFilesTab(world);
    world.mc.part<MachineFolders>().callsBefore = editorCalls(world).size();
  });

  step(QStringLiteral("(\"VS Code\"|the file manager|the editor) on this machine opens %1 from the folder kept for %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
         const MachineFolders& folders = world.mc.part<MachineFolders>();
         const QString local = folders.root + QLatin1Char('/') + c[2] + workspaceRoot(world) + QLatin1Char('/') + c[1];
         const bool reveal = c[0] == QLatin1String("the file manager");
         QJsonObject wanted{{QStringLiteral("cwd"), local}, {QStringLiteral("editor"), reveal ? QStringLiteral("file-manager") : QStringLiteral("vscode")}};
         if (reveal) wanted.insert(QStringLiteral("reveal"), true);
         QList<FakeMc::Rpc> started;
         world.waitFor([&] { return !(started = startedSinceActing(world)).isEmpty(); }, [&] { return QStringLiteral("%1 to open %2").arg(c[0], local); });
         // Through the MC on this machine, which the shell is connected to.
         const QString shellMc = world.mc.environmentId;
         expect(started.size() == 1 && started.first().payload == wanted &&
                    (started.first().environment.isEmpty() || started.first().environment == shellMc),
                QStringLiteral("%1 was wanted on \"%2\"; the MC was asked %3").arg(show(wanted.toVariantMap()), shellMc, describe(started)));
       });

  step(QStringLiteral("nothing is started on %1").arg(q), [](World& world, const Captures& c, const Table&) {
    QList<FakeMc::Rpc> elsewhere;
    for (const FakeMc::Rpc& rpc : startedSinceActing(world)) {
      if (rpc.environment == c[0]) elsewhere.append(rpc);
    }
    expect(elsewhere.isEmpty(), QStringLiteral("the MC was asked %1").arg(describe(elsewhere)));
  });

  step(QStringLiteral("the user is told the file is on %1 and what to install to open it here").arg(q), [](World& world, const Captures& c, const Table&) {
    const QString told = QStringLiteral("The file is on \"%1\". To open it here, install FUSE 3 (fuse3).").arg(c[0]);
    world.waitFor([&] { return toastTitles(world).contains(told); },
                  [&] { return QStringLiteral("\"%1\"; the toasts are %2").arg(told, show(world.state(QStringLiteral("toasts")))); });
    expect(startedSinceActing(world).isEmpty(), QStringLiteral("the MC was asked %1").arg(describe(startedSinceActing(world))));
  });
});

}  // namespace
