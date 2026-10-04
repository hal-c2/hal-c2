// Where the desktop app keeps its files and listens for later launches
// (src/StoragePaths, src/SingleInstance): the @desktop scenarios of
// features/mc/platform/storage-layout.feature the Qt shell delivers itself.
// The user is "/home/me", with the environment each scenario gives them.

#include <QCryptographicHash>
#include <QDir>
#include <QFileInfo>
#include <QLocalSocket>
#include <QProcessEnvironment>
#include <QTemporaryDir>

#include "Harness.h"
#include "SingleInstance.h"
#include "StoragePaths.h"
#include "World.h"

namespace {

const QString kHome = QStringLiteral("/home/me");

struct Layout {
  QProcessEnvironment env;
  bool windows = false;
  QList<StoragePaths> started;  // one per ambient home the app was started under
};

Layout& layout(World& world) {
  return world.mc.part<Layout>();
}

QString expand(QString path) {
  if (path.startsWith(QLatin1String("~/"))) path = kHome + path.mid(1);
  return path;
}

const Steps steps([] {
  const QString q = kQuoted;

  step(QStringLiteral("a Linux user with no XDG variables and no HAL-C2 home configured"), [](World& world, const Captures&, const Table&) {
    layout(world) = Layout{};
  });
  step(QStringLiteral("a Windows user"), [](World& world, const Captures&, const Table&) { layout(world).windows = true; });
  step(QStringLiteral("HAL_C2_HOME is %1 in the developer's shell").arg(q), [](World& world, const Captures& c, const Table&) {
    layout(world).env.insert(QStringLiteral("HAL_C2_HOME"), c[0]);
  });
  step(QStringLiteral("XDG_RUNTIME_DIR is %1").arg(q), [](World& world, const Captures& c, const Table&) {
    layout(world).env.insert(QStringLiteral("XDG_RUNTIME_DIR"), c[0]);
  });
  step(QStringLiteral("XDG_RUNTIME_DIR is not set"), [](World& world, const Captures&, const Table&) {
    layout(world).env.remove(QStringLiteral("XDG_RUNTIME_DIR"));
  });

  // The home directory.
  step(QStringLiteral("a developer starts the desktop app from a linked git worktree with --home-dir %1").arg(q),
       [](World& world, const Captures& c, const Table&) {
    Layout& state = layout(world);
    // With the developer's own HAL_C2_HOME, and with the worktree's, which the
    // development runner puts in its place (scripts/dev-qt.mjs).
    QProcessEnvironment worktree = state.env;
    worktree.insert(QStringLiteral("HAL_C2_HOME"), QStringLiteral("/code/hal-c2/.claude/worktrees/feature/.hal-c2"));
    for (const QProcessEnvironment& env : {state.env, worktree}) {
      state.started.append(resolveStoragePaths(c[0], env, kHome, StoragePlatform::Unix));
    }
  });
  step(QStringLiteral("the desktop app and the server it hosts keep every kind under %1").arg(q), [](World& world, const Captures& c, const Table&) {
    expect(layout(world).started.size() == 2, QStringLiteral("the app was not started"));
    for (const StoragePaths& paths : std::as_const(layout(world).started)) {
      // `root` is what the hosted server is given as --base-dir (main.cpp).
      expect(paths.root == c[0] && paths.config == c[0] + QStringLiteral("/config") && paths.data == c[0] + QStringLiteral("/data") &&
                 paths.state == c[0] + QStringLiteral("/state") && paths.cache == c[0] + QStringLiteral("/cache"),
             QStringLiteral("the app keeps %1, %2, %3 and %4 and hands the server \"%5\"").arg(paths.config, paths.data, paths.state, paths.cache, paths.root));
    }
  });

  // The control socket.
  step(QStringLiteral("the user starts the desktop app"), [](World& world, const Captures&, const Table&) {
    layout(world).started = {resolveStoragePaths({}, layout(world).env, kHome,
                                                 layout(world).windows ? StoragePlatform::Windows : StoragePlatform::Unix)};
  });
  step(QStringLiteral("its control socket is in %1").arg(q), [](World& world, const Captures& c, const Table&) {
    const Layout& state = layout(world);
    const QString address = SingleInstance::address(state.started.first().state, state.env, false);
    expect(QFileInfo(address).path() == expand(c[0]), QStringLiteral("the socket is %1").arg(address));
    // And an app that listens there is found by a later launch. The same rule, in a directory this test may write.
    QTemporaryDir runtime(QDir::tempPath() + QStringLiteral("/hc-XXXXXX"));
    QProcessEnvironment real = state.env;
    const bool viaRuntime = real.contains(QStringLiteral("XDG_RUNTIME_DIR"));
    const QString stateDir = runtime.filePath(QStringLiteral("state"));
    if (viaRuntime) real.insert(QStringLiteral("XDG_RUNTIME_DIR"), runtime.filePath(QStringLiteral("run")));
    const QString listening = SingleInstance::address(stateDir, real, false);
    expect(QFileInfo(listening).path() == (viaRuntime ? runtime.filePath(QStringLiteral("run/hal-c2")) : stateDir),
           QStringLiteral("the socket would be %1").arg(listening));
    QDir().mkpath(QFileInfo(listening).path());
    QLocalServer server;
    expect(server.listen(listening) && QFileInfo::exists(listening), QStringLiteral("nothing can listen at %1: %2").arg(listening, server.errorString()));
    QLocalSocket later;
    later.connectToServer(listening);
    expect(later.waitForConnected(1000), QStringLiteral("a later launch cannot reach %1").arg(listening));
  });
  step(QStringLiteral("its control channel is the same named pipe as before"), [](World& world, const Captures&, const Table&) {
    const Layout& state = layout(world);
    const QString stateDir = state.started.first().state;
    // The name it has always had: "hal-c2-qt-" and sixteen hex digits of the state directory's SHA-1, whatever the runtime directory.
    const QString before = QStringLiteral("hal-c2-qt-") +
                           QString::fromLatin1(QCryptographicHash::hash(QDir(stateDir).absolutePath().toUtf8(), QCryptographicHash::Sha1).toHex().left(16));
    QProcessEnvironment withRuntime = state.env;
    withRuntime.insert(QStringLiteral("XDG_RUNTIME_DIR"), QStringLiteral("/run/user/1000"));
    expect(SingleInstance::address(stateDir, state.env, true) == before && SingleInstance::address(stateDir, withRuntime, true) == before,
           QStringLiteral("the pipe is %1, it was %2").arg(SingleInstance::address(stateDir, state.env, true), before));
  });
});

}  // namespace
