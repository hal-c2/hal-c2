#include "DesktopUpdateSystem.h"

#include <QCoreApplication>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QPointer>
#include <QProcess>
#include <QStandardPaths>

#include <cstdio>

namespace {

constexpr int kFeedTimeoutMs = 30'000;
constexpr int kDownloadStallMs = 60'000;

// Waits for this process to end, then puts the new app in place and starts it.
// The swap waits because the running app is the file being replaced (macOS)
// and SingleInstance would hand a second copy's launch back to this one.
const char* const kRelaunch =
    "pid=\"$1\"; target=\"$2\"; staged=\"$3\"; open_with=\"$4\"\n"
    "while kill -0 \"$pid\" 2>/dev/null; do sleep 0.2; done\n"
    "if [ -n \"$staged\" ]; then rm -rf \"$target\" && mv \"$staged\" \"$target\" || exit 1; fi\n"
    "if [ -n \"$open_with\" ]; then exec \"$open_with\" \"$target\"; else exec \"$target\"; fi\n";

class SystemBackend : public DesktopUpdater::Backend {
public:
  void fetch(const DesktopUpdater::Environment& environment, Releases done) override {
    QNetworkRequest request{QUrl(environment.feedUrl)};
    request.setRawHeader("Accept", "application/vnd.github+json");
    request.setTransferTimeout(kFeedTimeoutMs);
    QNetworkReply* reply = m_network.get(request);
    QObject::connect(reply, &QNetworkReply::finished, reply, [reply, environment, done] {
      reply->deleteLater();
      if (reply->error() != QNetworkReply::NoError) {
        done({}, reply->errorString());
        return;
      }
      // The Apple Silicon build for a Mac running the Intel one.
      done(desktopUpdate::parseFeed(reply->readAll(), environment.platform, environment.hostArch), std::nullopt);
    });
  }

  void download(const desktopUpdate::Release& release, std::function<void(int)> progress, Done done) override {
    const QString dir = stagingDir(release.version);
    QDir(dir).removeRecursively();
    if (!QDir().mkpath(dir)) {
      done(QStringLiteral("Could not create %1.").arg(dir));
      return;
    }
    const QString path = QDir(dir).filePath(release.asset.fileName() + QStringLiteral(".part"));
    auto file = std::make_shared<QFile>(path);
    if (!file->open(QIODevice::WriteOnly)) {
      done(file->errorString());
      return;
    }
    QNetworkRequest request(release.asset);
    request.setTransferTimeout(kDownloadStallMs);
    QNetworkReply* reply = m_network.get(request);
    // Hashed as it arrives: a whole AppImage at the end would freeze the window.
    auto hash = std::make_shared<QCryptographicHash>(QCryptographicHash::Sha256);
    const auto take = [reply, file, hash] {
      const QByteArray bytes = reply->readAll();
      file->write(bytes);
      hash->addData(bytes);
    };
    QObject::connect(reply, &QNetworkReply::readyRead, reply, take);
    QObject::connect(reply, &QNetworkReply::downloadProgress, reply, [progress, release](qint64 received, qint64 total) {
      if (total <= 0) total = release.size;
      if (total > 0) progress(int(std::min<qint64>(100, received * 100 / total)));
    });
    QObject::connect(reply, &QNetworkReply::finished, reply, [this, reply, file, hash, take, path, release, done] {
      reply->deleteLater();
      take();
      file->close();
      if (reply->error() != QNetworkReply::NoError) {
        QFile::remove(path);
        done(reply->errorString());
        return;
      }
      if (release.size > 0 && file->size() != release.size) {
        QFile::remove(path);
        done(QStringLiteral("The download of %1 was incomplete.").arg(release.version));
        return;
      }
      if (!desktopUpdate::matchesDigest(*hash, release.sha256)) {
        QFile::remove(path);
        done(QStringLiteral("The download of %1 does not match its published digest.").arg(release.version));
        return;
      }
      const QString staged = path.chopped(5);
      QFile::remove(staged);
      if (!QFile::rename(path, staged)) {
        done(QStringLiteral("Could not stage the update."));
        return;
      }
      m_staged.insert(release.version, staged);
      done(std::nullopt);
    });
  }

  bool staged(const QString& version) const override {
    return m_staged.contains(version) && QFileInfo::exists(m_staged.value(version));
  }

  void install(const DesktopUpdater::Environment& environment, const QString& version, Done done) override {
    if (!staged(version)) {
      done(QStringLiteral("The downloaded update is gone."));
      return;
    }
    const QString file = m_staged.value(version);
    if (environment.platform == QLatin1String("linux")) {
      installAppImage(environment.appImage, file, std::move(done));
    } else if (environment.platform == QLatin1String("macos")) {
      installBundle(file, std::move(done));
    } else {
      done(QStringLiteral("This platform cannot install updates."));
    }
  }

private:
  static QString stagingDir(const QString& version) {
    return QDir(QStandardPaths::writableLocation(QStandardPaths::CacheLocation)).filePath(QStringLiteral("updates/") + version);
  }

  static bool relaunch(const QString& target, const QString& staged, const QString& openWith) {
    return QProcess::startDetached(QStringLiteral("/bin/sh"),
                                   {QStringLiteral("-c"), QString::fromLatin1(kRelaunch), QStringLiteral("hal-c2-update"),
                                    QString::number(QCoreApplication::applicationPid()), target, staged, openWith});
  }

  // The new AppImage beside the old one, then renamed over it: the running
  // copy keeps its open file.
  static void installAppImage(const QString& appImage, const QString& staged, Done done) {
    if (appImage.isEmpty()) {
      done(QStringLiteral("The app is not running from an AppImage."));
      return;
    }
    const QString next = appImage + QStringLiteral(".update");
    QFile::remove(next);
    if (!QFile::copy(staged, next)) {
      done(QStringLiteral("Could not write %1.").arg(next));
      return;
    }
    QFile::setPermissions(next, QFile::permissions(appImage) | QFileDevice::ExeOwner | QFileDevice::ExeUser);
    if (std::rename(QFile::encodeName(next).constData(), QFile::encodeName(appImage).constData()) != 0) {
      QFile::remove(next);
      done(QStringLiteral("Could not replace %1.").arg(appImage));
      return;
    }
    if (!relaunch(appImage, {}, {})) {
      done(QStringLiteral("Could not start the updated app."));
      return;
    }
    done(std::nullopt);
  }

  // Unzips the new bundle beside the staged zip; the helper swaps it in once
  // this process is gone.
  static void installBundle(const QString& zip, Done done) {
    QString bundle = QCoreApplication::applicationDirPath();
    const qsizetype end = bundle.indexOf(QLatin1String(".app/"));
    if (end < 0) {
      done(QStringLiteral("The app is not running from its bundle."));
      return;
    }
    bundle = bundle.left(end + 4);
    const QString unpacked = QFileInfo(zip).dir().filePath(QStringLiteral("unpacked"));
    QDir(unpacked).removeRecursively();
    auto* ditto = new QProcess();
    QObject::connect(ditto, &QProcess::finished, ditto, [ditto, unpacked, bundle, done](int code, QProcess::ExitStatus status) {
      ditto->deleteLater();
      if (status != QProcess::NormalExit || code != 0) {
        done(QStringLiteral("Could not unpack the update."));
        return;
      }
      QDirIterator apps(unpacked, {QStringLiteral("*.app")}, QDir::Dirs);
      if (!apps.hasNext()) {
        done(QStringLiteral("The update holds no app."));
        return;
      }
      if (!relaunch(bundle, apps.next(), QStringLiteral("/usr/bin/open"))) {
        done(QStringLiteral("Could not start the updated app."));
        return;
      }
      done(std::nullopt);
    });
    QObject::connect(ditto, &QProcess::errorOccurred, ditto, [ditto, done](QProcess::ProcessError error) {
      if (error != QProcess::FailedToStart) return;
      ditto->deleteLater();
      done(QStringLiteral("Could not unpack the update."));
    });
    ditto->start(QStringLiteral("/usr/bin/ditto"), {QStringLiteral("-x"), QStringLiteral("-k"), zip, unpacked});
  }

  QNetworkAccessManager m_network;
  QHash<QString, QString> m_staged;
};

}  // namespace

DesktopUpdatePlatform& desktopUpdatePlatform() {
  static DesktopUpdatePlatform platform;
  return platform;
}

std::shared_ptr<DesktopUpdater::Backend> desktopUpdateSystemBackend() {
  return std::make_shared<SystemBackend>();
}
