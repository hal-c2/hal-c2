#include "StoragePaths.h"

#include <QDir>
#include <QRegularExpression>

namespace {

const QString kAppDir = QStringLiteral("hal-c2");

bool isAbsoluteFor(const QString& path, StoragePlatform platform) {
  if (platform == StoragePlatform::Windows) {
    static const QRegularExpression drive(QStringLiteral("^([A-Za-z]:[\\\\/]|[\\\\/]{2})"));
    return drive.match(path).hasMatch();
  }
  return path.startsWith(QLatin1Char('/'));
}

// A trimmed absolute path, or empty: the XDG spec says relative values are ignored.
QString absoluteEnv(const QProcessEnvironment& env, const QString& name,
                    StoragePlatform platform) {
  const QString value = env.value(name).trimmed();
  return isAbsoluteFor(value, platform) ? QDir::cleanPath(value) : QString();
}

QString join(const QString& base, const QString& child) {
  return QDir::cleanPath(base + QLatin1Char('/') + child);
}

QString comparable(const QString& path, StoragePlatform platform) {
  const QString cleaned = QDir::cleanPath(QDir::fromNativeSeparators(path));
  return platform == StoragePlatform::Windows ? cleaned.toLower() : cleaned;
}

bool isLegacyHome(const QString& dir, const QString& userHome, StoragePlatform platform) {
  const QString candidate = comparable(dir, platform);
  for (const QString& name : {QStringLiteral(".hal-c2"), QStringLiteral(".t3")}) {
    if (comparable(join(userHome, name), platform) == candidate) {
      return true;
    }
  }
  return false;
}

StoragePaths under(const QString& root) {
  return {root, join(root, QStringLiteral("config")), join(root, QStringLiteral("data")),
          join(root, QStringLiteral("state")), join(root, QStringLiteral("cache"))};
}

}  // namespace

StoragePaths resolveStoragePaths(const QString& homeDirOverride,
                                 const QProcessEnvironment& env,
                                 const QString& userHome,
                                 StoragePlatform platform) {
  if (!homeDirOverride.trimmed().isEmpty()) {
    return under(QDir(homeDirOverride.trimmed()).absolutePath());
  }
  const QString fromEnv = absoluteEnv(env, QStringLiteral("HAL_C2_HOME"), platform);
  if (!fromEnv.isEmpty() && !isLegacyHome(fromEnv, userHome, platform)) {
    return under(fromEnv);
  }

  const auto base = [&](const char* variable, const QString& fallback) {
    const QString value = absoluteEnv(env, QString::fromLatin1(variable), platform);
    return value.isEmpty() ? fallback : value;
  };
  if (platform == StoragePlatform::Windows) {
    // Data, state and cache share %LOCALAPPDATA%, so each kind gets its own folder
    // there. An XDG variable is already a base for one kind and gets no nesting.
    const QString appData =
        base("APPDATA", join(userHome, QStringLiteral("AppData/Roaming")));
    const QString localAppData =
        base("LOCALAPPDATA", join(userHome, QStringLiteral("AppData/Local")));
    const auto kind = [&](const char* variable, const QString& fallback, const QString& name) {
      const QString configured = absoluteEnv(env, QString::fromLatin1(variable), platform);
      return configured.isEmpty() ? join(join(fallback, kAppDir), name)
                                  : join(configured, kAppDir);
    };
    return {QString(), kind("XDG_CONFIG_HOME", appData, QStringLiteral("config")),
            kind("XDG_DATA_HOME", localAppData, QStringLiteral("data")),
            kind("XDG_STATE_HOME", localAppData, QStringLiteral("state")),
            kind("XDG_CACHE_HOME", localAppData, QStringLiteral("cache"))};
  }
  const auto kind = [&](const char* variable, const QString& fallback) {
    return join(base(variable, join(userHome, fallback)), kAppDir);
  };
  return {QString(), kind("XDG_CONFIG_HOME", QStringLiteral(".config")),
          kind("XDG_DATA_HOME", QStringLiteral(".local/share")),
          kind("XDG_STATE_HOME", QStringLiteral(".local/state")),
          kind("XDG_CACHE_HOME", QStringLiteral(".cache"))};
}

StoragePaths resolveStoragePaths(const QString& homeDirOverride) {
#ifdef Q_OS_WIN
  constexpr StoragePlatform platform = StoragePlatform::Windows;
#else
  constexpr StoragePlatform platform = StoragePlatform::Unix;
#endif
  return resolveStoragePaths(homeDirOverride, QProcessEnvironment::systemEnvironment(),
                             QDir::homePath(), platform);
}
