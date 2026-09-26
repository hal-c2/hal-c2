#pragma once

#include <QProcessEnvironment>
#include <QString>

// Where the Qt shell keeps its files, resolved the way packages/shared/src/xdgDirs.ts
// resolves them for the server and the Electron app:
//   1. `--home-dir` is one root for everything (<root>/config, data, state, cache);
//   2. otherwise HAL_C2_HOME, unless it is relative or names an old home
//      (~/.hal-c2, ~/.t3), which only the migration reads;
//   3. otherwise the XDG variables (only absolute values count) with the platform
//      defaults. Linux and macOS share ~/.config, ~/.local/share, ~/.local/state and
//      ~/.cache; Windows uses %APPDATA%\hal-c2\config and %LOCALAPPDATA%\hal-c2\<kind>.
// QStandardPaths is not used: it sends macOS to ~/Library and Windows config to
// %LOCALAPPDATA%, which would part the shell from the server it hosts.
struct StoragePaths {
  // The explicit root, or empty when the shell follows XDG. Only an explicit root
  // is handed to the hosted server as `--base-dir`.
  QString root;
  QString config;
  QString data;
  QString state;
  QString cache;
};

enum class StoragePlatform { Unix, Windows };

StoragePaths resolveStoragePaths(const QString& homeDirOverride,
                                 const QProcessEnvironment& env,
                                 const QString& userHome,
                                 StoragePlatform platform);

// The running process's storage: its environment, home and platform.
StoragePaths resolveStoragePaths(const QString& homeDirOverride);
