#include "CaptureHelper.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QSaveFile>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QTimer>
#include <QUuid>

#include <cstdio>
#include <memory>
#include <optional>

namespace {

const QString kDesktopFile = QStringLiteral("io.github.halc2.HalC2.KdeCapture.desktop");
const QString kMarker = QStringLiteral("X-HalC2-Capture-Helper=true");
constexpr qint64 kMaxPngBytes = 32 * 1024 * 1024;
constexpr qint64 kMaxOutput = 128 * 1024;

struct Seams {
  CaptureHelper::PathsFor paths;
  std::optional<QStringList> tools;
  int timeoutMs = CaptureHelper::kTimeoutMs;
};

Seams& seams() {
  static Seams state;
  return state;
}

// A file that is not there; a regular file's bytes; or why it cannot be read.
struct Read {
  bool exists = false;
  QByteArray bytes;
  QString error;
};

Read regularFile(const QString& path, const QString& linkError) {
  const QFileInfo info(path);
  if (!info.exists() && !info.isSymLink()) return {};
  if (info.isSymLink() || !info.isFile()) return {true, {}, linkError};
  QFile file(path);
  if (!file.open(QIODevice::ReadOnly)) return {true, {}, file.errorString()};
  return {true, file.readAll(), {}};
}

// A directory that is a link or not a directory at all.
bool foreignDirectory(const QString& path) {
  const QFileInfo info(path);
  if (!info.exists() && !info.isSymLink()) return false;
  return info.isSymLink() || !info.isDir();
}

// Exec values are unescaped as strings and then unquoted, so escaped in reverse.
QString execArgument(const QString& value) {
  QString quoted = value;
  quoted.replace(QLatin1Char('\\'), QStringLiteral("\\\\"))
      .replace(QLatin1Char('`'), QStringLiteral("\\`"))
      .replace(QLatin1Char('$'), QStringLiteral("\\$"))
      .replace(QLatin1Char('"'), QStringLiteral("\\\""))
      .replace(QLatin1Char('%'), QStringLiteral("%%"));
  quoted = QLatin1Char('"') + quoted + QLatin1Char('"');
  return quoted.replace(QLatin1Char('\\'), QStringLiteral("\\\\"))
      .replace(QLatin1Char('\n'), QStringLiteral("\\n"))
      .replace(QLatin1Char('\r'), QStringLiteral("\\r"))
      .replace(QLatin1Char('\t'), QStringLiteral("\\t"));
}

// Writes `bytes` beside `target` and renames it over: the file is whole or absent.
QString writeExecutable(const QString& target, const QByteArray& bytes) {
  const QString directory = QFileInfo(target).path();
  QTemporaryDir staging(QDir(directory).filePath(QStringLiteral(".install-XXXXXX")));
  if (!staging.isValid()) return staging.errorString();
  QFile staged(QDir(staging.path()).filePath(QFileInfo(target).fileName()));
  if (!staged.open(QIODevice::WriteOnly | QIODevice::NewOnly) || staged.write(bytes) != bytes.size()) return staged.errorString();
  staged.close();
  staged.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner | QFileDevice::ReadGroup |
                        QFileDevice::ExeGroup | QFileDevice::ReadOther | QFileDevice::ExeOther);
  if (::rename(QFile::encodeName(staged.fileName()).constData(), QFile::encodeName(target).constData()) != 0) {
    return QStringLiteral("Could not install the capture helper.");
  }
  return {};
}

}  // namespace

CaptureHelper::CaptureHelper(Kind kind, const Paths& paths, QObject* parent) : QObject(parent), m_kind(kind), m_paths(paths) {}

CaptureHelper::~CaptureHelper() {
  if (m_process) {
    m_process->disconnect(this);
    m_process->kill();
    m_process->waitForFinished(1000);
  }
}

void CaptureHelper::setPaths(PathsFor paths) {
  seams().paths = std::move(paths);
}

void CaptureHelper::setToolPath(const QStringList& directories) {
  seams().tools = directories;
}

void CaptureHelper::setTimeout(int ms) {
  seams().timeoutMs = ms;
}

QString CaptureHelper::executableName(Kind kind) {
  return kind == Kind::Kde ? QStringLiteral("hal-c2-kde-snap-shot") : QStringLiteral("hal-c2-hyprland-snap-shot");
}

// A package carries the helper in share/hal-c2/<kde|hyprland>-capture beside
// bin/hal-c2-qt; a development build finds it where cargo builds it
// (mise run desktop:helpers).
CaptureHelper::Paths CaptureHelper::defaultPaths(Kind kind) {
  if (seams().paths) return seams().paths(kind);
  const QString folder = kind == Kind::Kde ? QStringLiteral("kde-capture") : QStringLiteral("hyprland-capture");
  const QString crate = kind == Kind::Kde ? QStringLiteral("kde-snap-shot") : QStringLiteral("hyprland-snap-shot");
  const QDir app(QCoreApplication::applicationDirPath());
  QString bundle = app.filePath(QStringLiteral("../share/hal-c2/%1/%2").arg(folder, executableName(kind)));
#ifdef HAL_C2_SOURCE_ROOT
  if (!QFileInfo::exists(bundle)) {
    bundle = QDir(QStringLiteral(HAL_C2_SOURCE_ROOT)).filePath(QStringLiteral("native/%1/target/release/%2").arg(crate, executableName(kind)));
  }
#else
  Q_UNUSED(crate);
#endif
  return {QDir::cleanPath(bundle), QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation)};
}

QString CaptureHelper::executable() const {
  const QString folder = m_kind == Kind::Kde ? QStringLiteral("kde-capture") : QStringLiteral("hyprland-capture");
  return QDir(m_paths.dataHome).filePath(QStringLiteral("hal-c2/%1/%2").arg(folder, executableName(m_kind)));
}

QString CaptureHelper::entryPath() const {
  return QDir(m_paths.dataHome).filePath(QStringLiteral("applications/") + kDesktopFile);
}

QString CaptureHelper::entryText() const {
  return QStringList{
      QStringLiteral("[Desktop Entry]"),
      QStringLiteral("Type=Application"),
      QStringLiteral("Name=HAL-C2 SnapShots"),
      QStringLiteral("NoDisplay=true"),
      QStringLiteral("Exec=%1 check").arg(execArgument(executable())),
      // KService reads this custom property as a KConfig list, not an XDG ';' list.
      QStringLiteral("X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2"),
      kMarker,
      QString(),
  }.join(QLatin1Char('\n'));
}

QString CaptureHelper::missing() const {
  return m_kind == Kind::Kde ? tr("The capture helper is missing from this build. Update or reinstall HAL-C2.")
                             : tr("The Hyprland capture helper is missing from this build. Update or reinstall HAL-C2.");
}

CaptureHelper::State CaptureHelper::files() const {
  const QString linkError = m_kind == Kind::Kde
                                ? tr("Capture helper files must be regular files. Remove the conflicting link before trying again.")
                                : tr("The capture helper must be a regular file, not a link.");
  const Read installed = regularFile(executable(), linkError);
  if (!installed.error.isEmpty()) return {QStringLiteral("error"), installed.error};
  Read entry;
  if (m_kind == Kind::Kde) {
    entry = regularFile(entryPath(), linkError);
    if (!entry.error.isEmpty()) return {QStringLiteral("error"), entry.error};
  }
  if (!installed.exists || (m_kind == Kind::Kde && !entry.exists)) {
    return {QStringLiteral("not-installed"), m_kind == Kind::Kde
                                                 ? tr("Install the bundled helper to capture the window you're using without a picker.")
                                                 : tr("Install the bundled helper to capture the window you're using.")};
  }
  const Read bundle = regularFile(m_paths.bundle, linkError);
  if (!bundle.error.isEmpty()) return {QStringLiteral("error"), bundle.error};
  if (!bundle.exists || m_paths.bundle.isEmpty()) return {QStringLiteral("error"), missing()};
  if (installed.bytes != bundle.bytes || (m_kind == Kind::Kde && QString::fromUtf8(entry.bytes) != entryText())) {
    return {QStringLiteral("update-required"), tr("Update the bundled capture helper to continue.")};
  }
  return {QStringLiteral("ready"), {}};
}

void CaptureHelper::setState(const State& state) {
  m_state = state;
  emit changed();
}

QString CaptureHelper::runError(const QString& program, const QByteArray& stderr) const {
  if (program == QLatin1String("kbuildsycoca6")) {
    return tr("KDE couldn't register the capture helper. Make sure KDE's service tools (kbuildsycoca6) are installed, then reinstall the helper.");
  }
  const QString said = QString::fromUtf8(stderr).trimmed();
  if (m_kind == Kind::Kde && said.contains(QLatin1String("NoAuthorized"))) {
    return tr("KDE hasn't granted capture access. Reinstall the capture helper in setup, then try again.");
  }
  if (!said.isEmpty()) return said;
  return m_kind == Kind::Kde ? tr("The KDE capture helper did not respond. Reopen capture setup and check access.")
                             : tr("Hyprland capture did not respond. Check capture setup and try again.");
}

void CaptureHelper::run(const QString& program, const QStringList& arguments, Done done) {
  QString path = program;
  if (!program.contains(QLatin1Char('/'))) {
    path = seams().tools ? QStandardPaths::findExecutable(program, *seams().tools) : QStandardPaths::findExecutable(program);
  }
  if (path.isEmpty()) {
    done(runError(program, {}), {});
    return;
  }
  auto* process = new QProcess(this);
  m_process = process;
  auto* timeout = new QTimer(process);
  timeout->setSingleShot(true);
  auto finish = [this, process, program, done](bool ok) {
    if (m_process != process) return;
    m_process = nullptr;
    process->disconnect(this);
    const QByteArray out = process->readAllStandardOutput().left(kMaxOutput);
    const QByteArray err = process->readAllStandardError().left(kMaxOutput);
    process->deleteLater();
    done(ok ? QString() : runError(program, err), out);
  };
  connect(timeout, &QTimer::timeout, this, [process, finish] {
    process->kill();
    process->waitForFinished(1000);
    finish(false);
  });
  connect(process, &QProcess::finished, this, [process, finish](int code, QProcess::ExitStatus status) {
    finish(status == QProcess::NormalExit && code == 0 && process->error() != QProcess::Crashed);
  });
  connect(process, &QProcess::errorOccurred, this, [finish](QProcess::ProcessError error) {
    if (error == QProcess::FailedToStart) finish(false);
  });
  timeout->start(seams().timeoutMs);
  process->start(path, arguments);
}

void CaptureHelper::check() {
  if (m_busy) return;
  const State found = files();
  if (found.status != QLatin1String("ready")) {
    setState(found);
    return;
  }
  m_busy = true;
  emit changed();
  run(executable(), {QStringLiteral("check")}, [this](const QString& error, const QByteArray& out) {
    m_busy = false;
    if (!error.isEmpty()) {
      setState({QStringLiteral("error"), error});
      return;
    }
    const QJsonObject answer = QJsonDocument::fromJson(out).object();
    setState({QStringLiteral("ready"),
              m_kind == Kind::Kde ? tr("KDE capture access is ready. Next, choose your shortcut.")
                                  : tr("Helper ready. Hyprland may ask for screen-sharing permission on your first capture."),
              answer.value(QLatin1String("feedbackAvailable")).toBool()});
  });
}

QString CaptureHelper::install(const QByteArray& bundle) {
  const QString target = executable();
  if (!QDir().mkpath(QFileInfo(target).path())) return tr("Could not create the capture helper directory.");
  if (const QString error = writeExecutable(target, bundle); !error.isEmpty()) return error;
  if (m_kind != Kind::Kde) return {};
  const QString entry = entryPath();
  if (!QDir().mkpath(QFileInfo(entry).path())) return tr("Could not create the applications directory.");
  const QString staged = QStringLiteral("%1.%2.tmp").arg(entry, QUuid::createUuid().toString(QUuid::WithoutBraces));
  QFile file(staged);
  const QByteArray text = entryText().toUtf8();
  if (!file.open(QIODevice::WriteOnly | QIODevice::NewOnly) || file.write(text) != text.size()) {
    file.remove();
    return file.errorString();
  }
  file.close();
  file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ReadGroup | QFileDevice::ReadOther);
  if (::rename(QFile::encodeName(staged).constData(), QFile::encodeName(entry).constData()) != 0) {
    QFile::remove(staged);
    return tr("Could not install the capture helper's desktop entry.");
  }
  return {};
}

// KService must see the new desktop entry before KWin checks the executable;
// an AppImage's search paths and locale differ from Plasma's, so the cache is
// also rebuilt in the session's own environment, where failing is fine.
void CaptureHelper::refreshServices(std::function<void(const QString& error)> done) {
  run(QStringLiteral("kbuildsycoca6"), {QStringLiteral("--noincremental")}, [this, done](const QString& error, const QByteArray&) {
    if (!error.isEmpty()) {
      done(error);
      return;
    }
    run(QStringLiteral("systemd-run"),
        {QStringLiteral("--user"), QStringLiteral("--quiet"), QStringLiteral("--wait"), QStringLiteral("--collect"), QStringLiteral("--pipe"),
         QStringLiteral("--service-type=exec"), QStringLiteral("kbuildsycoca6"), QStringLiteral("--noincremental")},
        [done](const QString&, const QByteArray&) { done({}); });
  });
}

void CaptureHelper::perform(const QString& action) {
  if (action != installAction() && action != removeAction()) return;
  if (m_busy) {
    emit performed(tr("Capture setup is still busy. Try again in a moment."));
    return;
  }
  const bool removing = action == removeAction();
  const QString linkError = m_kind == Kind::Kde
                                ? tr("Capture helper files must be regular files. Remove the conflicting link before trying again.")
                                : tr("The capture helper must be a regular file, not a link.");
  const auto refuse = [this](const QString& error) {
    emit performed(error);
    check();
  };
  Read entry;
  if (m_kind == Kind::Kde) {
    entry = regularFile(entryPath(), linkError);
    if (!entry.error.isEmpty()) return refuse(entry.error);
    if (entry.exists && !QString::fromUtf8(entry.bytes).split(QLatin1Char('\n')).contains(kMarker)) {
      return refuse(tr("Another desktop entry uses the capture helper's name. Rename it before continuing."));
    }
  }
  if (foreignDirectory(QFileInfo(executable()).path())) {
    return refuse(m_kind == Kind::Kde ? tr("The capture helper directory is not a regular directory.")
                                      : tr("The capture helper directory must not be a link."));
  }
  if (const Read installed = regularFile(executable(), linkError); !installed.error.isEmpty()) return refuse(installed.error);

  QString error;
  if (removing) {
    if (entry.exists) QFile::remove(entryPath());
    QFile::remove(executable());
  } else {
    const Read bundle = m_paths.bundle.isEmpty() ? Read{} : regularFile(m_paths.bundle, linkError);
    if (!bundle.error.isEmpty()) return refuse(bundle.error);
    if (!bundle.exists) return refuse(missing());
    error = install(bundle.bytes);
  }
  if (!error.isEmpty() || m_kind != Kind::Kde) return refuse(error);
  m_busy = true;
  emit changed();
  refreshServices([this, refuse](const QString& error) {
    m_busy = false;
    refuse(error);
  });
}

void CaptureHelper::capture() {
  if (m_busy) return;
  const State found = files();
  if (found.status != QLatin1String("ready")) {
    setState(found);
    emit failed(tr("%1 Open Settings → SnapShots to continue setup.").arg(found.message));
    return;
  }
  m_busy = true;
  emit changed();
  run(executable(), {QStringLiteral("check")}, [this](const QString& error, const QByteArray&) {
    if (!error.isEmpty()) {
      m_busy = false;
      setState({QStringLiteral("error"), error});
      emit failed(tr("%1 Open Settings → SnapShots to continue setup.").arg(error));
      return;
    }
    auto directory = std::make_shared<QTemporaryDir>(QDir(QDir::tempPath()).filePath(QStringLiteral("hal-c2-capture-XXXXXX")));
    if (!directory->isValid()) {
      m_busy = false;
      emit changed();
      emit failed(tr("Couldn't make a place for the capture."));
      return;
    }
    run(executable(), {QStringLiteral("capture"), directory->path()}, [this, directory](const QString& error, const QByteArray& out) {
      m_busy = false;
      emit changed();
      if (!error.isEmpty()) {
        emit failed(error);
        return;
      }
      const QJsonObject window = QJsonDocument::fromJson(out).object().value(QLatin1String("window")).toObject();
      QFile file(QDir(directory->path()).filePath(QStringLiteral("capture.png")));
      static const QByteArray header("\x89PNG\r\n\x1a\n", 8);
      QImage image;
      if (!file.open(QIODevice::ReadOnly) || file.size() > kMaxPngBytes || !file.peek(8).startsWith(header) ||
          !image.loadFromData(file.readAll(), "PNG") || image.isNull()) {
        emit failed(tr("Invalid screenshot file."));
        return;
      }
      if (image.width() > 2560 || image.height() > 1600) {
        image = image.scaled(2560, 1600, Qt::KeepAspectRatio, Qt::SmoothTransformation);
      }
      const QString app = window.value(QLatin1String("appName")).toString();
      emit captured(image, app.isEmpty() ? QStringLiteral("Window") : app, window.value(QLatin1String("title")).toString());
    });
  });
}
