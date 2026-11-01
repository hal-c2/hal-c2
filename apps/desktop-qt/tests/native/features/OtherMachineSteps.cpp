// A thread whose files are on another machine than the desktop, served by an
// MC there (files/file-viewer-and-editing.feature): no editor or file manager
// starts on that machine, and the user is told the files can't be opened here
// yet. A cluster member's open from a folder here (MachineFilesSteps.cpp). With
// an SSH name the MC advertises, this computer's editor opens them over SSH: the
// operating system's link handler is what they are handed to, and PATH says
// which editors this computer has.

#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonObject>
#include <QTemporaryDir>
#include <QUrl>

#include "FilesWorkspace.h"
#include "Harness.h"
#include "World.h"

namespace {

using namespace filesteps;

// What the MCs had been asked to start before the user acted.
struct Started {
  qsizetype calls = 0;
};

// The links handed to the operating system, for as long as the scenario runs.
class Links : public QObject {
  Q_OBJECT

 public:
  Links() {
    for (const QString& scheme : {QStringLiteral("vscode"), QStringLiteral("zed")}) {
      QDesktopServices::setUrlHandler(scheme, this, "open");
    }
  }
  ~Links() override {
    for (const QString& scheme : {QStringLiteral("vscode"), QStringLiteral("zed")}) {
      QDesktopServices::unsetUrlHandler(scheme);
    }
  }
  QList<QUrl> opened;

 public slots:
  void open(const QUrl& url) { opened.append(url); }
};

// This computer's PATH holding only these commands, for as long as the scenario runs.
struct InstalledEditors {
  QTemporaryDir dir;
  QByteArray path = qgetenv("PATH");
  ~InstalledEditors() { qputenv("PATH", path); }
  // A folder per call: the shell looks again when PATH changes.
  QStringList folders;
  void install(const QStringList& commands) {
    const QString folder = dir.filePath(QString::number(folders.size()));
    QDir().mkpath(folder);
    folders.append(folder);
    for (const QString& command : commands) {
      QFile file(folder + QLatin1Char('/') + command);
      expect(file.open(QIODevice::WriteOnly), QStringLiteral("no %1").arg(command));
      file.setPermissions(file.permissions() | QFileDevice::ExeOwner);
    }
    qputenv("PATH", folders.join(QLatin1Char(':')).toLocal8Bit());
  }
};

// The thread on another machine that advertises `targets`, this one having VS Code.
void onAnotherMachine(World& world, const QJsonArray& targets) {
  world.mc.part<Links>();
  world.mc.part<InstalledEditors>().install({QStringLiteral("code")});
  setConfig(world, {{QStringLiteral("availableEditors"), QJsonArray{QStringLiteral("sublime")}},
                    {QStringLiteral("remoteOpenTargets"), targets}});
  world.servedFrom(kOtherMachine);
  openFilesTab(world);
}

QStringList offered(World& world) {
  QStringList ids;
  for (const QVariant& editor : at(world.state(QStringLiteral("workspace")), QStringLiteral("editors")).toList()) {
    ids.append(editor.toMap().value(QStringLiteral("id")).toString());
  }
  return ids;
}

QJsonObject sshName(const QString& host) {
  return {{QStringLiteral("kind"), QStringLiteral("mdns")}, {QStringLiteral("host"), host}};
}

QStringList toastTitles(World& world) {
  QStringList titles;
  for (const QVariant& item : world.state(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList()) {
    titles.append(item.toMap().value(QStringLiteral("title")).toString());
  }
  return titles;
}

const Steps steps([] {
  step(QStringLiteral("the thread's files are on (?:an MC on another machine the client is paired with|an MC reached through an SSH port forward)"),
       [](World& world, const Captures&, const Table&) {
         // This machine's editors are the ones offered, wherever the thread runs.
         setConfig(world, {{QStringLiteral("availableEditors"), QJsonArray{QStringLiteral("vscode"), QStringLiteral("file-manager")}},
                           {QStringLiteral("shellRevealInFileManager"), true}});
         // An MC elsewhere says so by its machine's id, whatever address
         // reaches it: an SSH port forward is a loopback one. It keeps no
         // folder of anyone's on this machine.
         world.servedFrom(kOtherMachine);
         openFilesTab(world);
         world.mc.part<Started>().calls = editorCalls(world).size();
       });

  step(QStringLiteral("the thread's environment is on another machine reachable over SSH as %1").arg(kQuoted),
       [](World& world, const Captures& c, const Table&) { onAnotherMachine(world, {sshName(c[0])}); });
  step(QStringLiteral("the thread's environment is on another machine reachable over SSH"),
       [](World& world, const Captures&, const Table&) { onAnotherMachine(world, {sshName(QStringLiteral("devbox"))}); });
  step(QStringLiteral("the thread's environment is on another machine with no SSH route"),
       [](World& world, const Captures&, const Table&) { onAnotherMachine(world, {}); });
  step(QStringLiteral("the user opens the thread's workspace in %1").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    world.bridge().dispatch(QStringLiteral("workspace.openInEditor"), QVariantMap{{QStringLiteral("editorId"), editorId(c[0])}});
    world.sync();
  });
  step(QStringLiteral("the local %1 opens the workspace on %2 over SSH").arg(kQuoted, kQuoted), [](World& world, const Captures& c, const Table&) {
    const QUrl expected(QStringLiteral("%1://vscode-remote/ssh-remote+%2%3").arg(editorId(c[0]), c[1], workspaceRoot(world)));
    world.waitFor([&] { return world.mc.part<Links>().opened == QList<QUrl>{expected}; },
                  [&] { return QStringLiteral("%1; the links are %2").arg(expected.toString(), show(QVariant::fromValue(world.mc.part<Links>().opened))); });
    expect(editorCalls(world).isEmpty(), QStringLiteral("an MC was asked to start an editor"));
  });
  step(QStringLiteral("this computer has %1 and %2 installed that can open folders over SSH").arg(kQuoted, kQuoted),
       [](World& world, const Captures&, const Table&) {
         world.mc.part<InstalledEditors>().install({QStringLiteral("code"), QStringLiteral("zed")});
       });
  step(QStringLiteral("this computer has %1 installed which cannot").arg(kQuoted), [](World& world, const Captures&, const Table&) {
    world.mc.part<InstalledEditors>().install({QStringLiteral("subl")});
  });
  step(QStringLiteral("the user looks at the editors offered for the thread's workspace"), [](World& world, const Captures&, const Table&) {
    // The MC saying something new has the shell look again, as a new thread does.
    setConfig(world, {{QStringLiteral("remoteOpenTargets"), QJsonArray{sshName(QStringLiteral("devbox.local"))}}});
    world.sync();
  });
  step(QStringLiteral("%1 and %2 are offered").arg(kQuoted, kQuoted), [](World& world, const Captures& c, const Table&) {
    const QStringList expected{editorId(c[0]), editorId(c[1])};
    world.waitFor([&] { return offered(world) == expected; }, [&] { return show(offered(world)); });
  });
  step(QStringLiteral("%1 is not among them").arg(kQuoted), [](World& world, const Captures& c, const Table&) {
    expect(!offered(world).contains(editorId(c[0])), show(offered(world)));
  });
  step(QStringLiteral("the user looks at opening the thread's workspace in an editor"), [](World& world, const Captures&, const Table&) { world.sync(); });
  step(QStringLiteral("opening is unavailable and the user is told no SSH route is known"), [](World& world, const Captures&, const Table&) {
    expect(offered(world).isEmpty(), show(offered(world)));
    world.waitFor([&] { return at(world.state(QStringLiteral("workspace")), QStringLiteral("noSshRoute")).toString().startsWith(QStringLiteral("No SSH route to ")); },
                  [&] { return show(world.state(QStringLiteral("workspace"))); });
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

#include "OtherMachineSteps.moc"
