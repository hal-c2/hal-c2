#include "ShellRuntime.h"

#include <QCryptographicHash>
#include <QDir>
#include <QDirIterator>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImage>
#include <QKeySequence>
#include <QPalette>
#include <QQmlContext>
#include <QQuickWindow>
#include <QQmlError>
#include <QtLogging>
#include <QtQml/qqml.h>
#include <qpa/qwindowsysteminterface.h>

#include "PlatformWindow.h"
#include "ShellBridge.h"
#include "ThemeStore.h"

namespace {

const QStringList kWatchedSuffixes{QStringLiteral("qml"), QStringLiteral("js"),
                                   QStringLiteral("qmldir")};

bool isWatchedSource(const QFileInfo& info) {
  return kWatchedSuffixes.contains(info.suffix()) || info.fileName() == QStringLiteral("qmldir");
}

}  // namespace

void useSoftwareRenderingWithoutDisplay() {
  if (QGuiApplication::platformName() == QLatin1String("offscreen")) {
    QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);
  }
}

ShellRuntime::ShellRuntime(Options options, ShellBridge* bridge, ThemeStore* theme, QObject* parent)
    : QObject(parent), m_options(std::move(options)), m_bridge(bridge), m_theme(theme) {
  // One runtime per window, each with its own engine; an engine's singletons
  // are the bridge and theme it names (halC2Bridge, halC2Theme) for its entire
  // lifetime. Reload replaces only the root objects.
  static const bool registered = [] {
    const auto runtimeOf = [](QQmlEngine* engine) { return qobject_cast<ShellRuntime*>(engine->parent()); };
    const auto owned = [](QObject* object) {
      if (object) QQmlEngine::setObjectOwnership(object, QQmlEngine::CppOwnership);
      return object;
    };
    qmlRegisterSingletonType<ShellBridge>("HalC2.Shell", 1, 0, "Shell", [=](QQmlEngine* engine, QJSEngine*) {
      return static_cast<ShellBridge*>(owned(qvariant_cast<ShellBridge*>(engine->property("halC2Bridge"))));
    });
    qmlRegisterSingletonType<ThemeStore>("HalC2.Shell", 1, 0, "Theme", [=](QQmlEngine* engine, QJSEngine*) {
      return static_cast<ThemeStore*>(owned(qvariant_cast<ThemeStore*>(engine->property("halC2Theme"))));
    });
    qmlRegisterSingletonType<ShellRuntime>("HalC2.Shell", 1, 0, "Runtime", [=](QQmlEngine* engine, QJSEngine*) {
      return static_cast<ShellRuntime*>(owned(runtimeOf(engine)));
    });
    return true;
  }();
  Q_UNUSED(registered);

  applyApplicationAppearance(m_theme->windowLiquidGlass() && !m_theme->followsSystemAppearance(),
                             m_theme->appearance() != QStringLiteral("light"));
  m_engine = new QQmlApplicationEngine(this);
  // Which window's controllers its HalC2.Shell singletons are (NativeShell).
  m_engine->setProperty("halC2Bridge", QVariant::fromValue(static_cast<QObject*>(m_bridge)));
  m_engine->setProperty("halC2Theme", QVariant::fromValue(static_cast<QObject*>(m_theme)));
  connect(m_engine, &QQmlEngine::warnings, this, [](const QList<QQmlError>& warnings) {
    for (const auto& warning : warnings) {
      qWarning().noquote() << "[qml]" << warning.toString();
    }
  });

  m_debounce.setSingleShot(true);
  m_debounce.setInterval(120);
  connect(&m_debounce, &QTimer::timeout, this, [this] {
    rebuildWatchList();
    const QString next = sourceFingerprint();
    if (next == m_fingerprint) {
      return;
    }
    reload();
  });
  connect(&m_watcher, &QFileSystemWatcher::directoryChanged, &m_debounce,
          qOverload<>(&QTimer::start));
  connect(&m_watcher, &QFileSystemWatcher::fileChanged, &m_debounce, qOverload<>(&QTimer::start));
  connect(m_theme, &ThemeStore::themeChanged, this, &ShellRuntime::applyWindowTheme);
}

ShellRuntime::~ShellRuntime() {
  delete m_engine;
}

QString ShellRuntime::userShellPath() const {
  return QDir(m_options.configDir).filePath(QStringLiteral("shell.qml"));
}

QString ShellRuntime::appVersion() const {
  return QStringLiteral(HAL_C2_APP_VERSION);
}

QStringList ShellRuntime::sourceDirs() const {
  QStringList dirs;
  for (const QString& dir : {m_options.clientQmlSourceDir, m_options.qmlSourceDir}) {
    if (!dir.isEmpty()) dirs << dir;
  }
  return dirs;
}

QUrl ShellRuntime::defaultShellUrl() const {
  for (const QString& dir : sourceDirs()) {
    const QString onDisk = QDir(dir).filePath(m_options.defaultShell);
    if (QFileInfo::exists(onDisk)) {
      return QUrl::fromLocalFile(onDisk);
    }
  }
  return QUrl(QStringLiteral("qrc:/qt/qml/") + m_options.defaultShell);
}

void ShellRuntime::start() {
  rebuildWatchList();
  reload();
}

void ShellRuntime::reload() {
  const auto previous = m_engine->rootObjects();
  const bool previousUsingUserShell = m_usingUserShell;
  // Old roots keep their own QML types until the replacement loads. Only
  // C++ singleton state crosses generations; QML-created objects never do.
  m_engine->clearComponentCache();
  m_lastError.clear();
  m_usingUserShell = false;

  QString error;
  const QString userShell = userShellPath();
  bool loaded = false;
  if (QFileInfo::exists(userShell)) {
    loaded = loadGeneration(QUrl::fromLocalFile(userShell), &error);
    m_usingUserShell = loaded;
    if (!loaded) {
      m_lastError = error;
      qWarning().noquote() << "[shell] user shell failed, falling back to default:\n" << error;
    }
  }
  if (!loaded) {
    QString defaultError;
    loaded = loadGeneration(defaultShellUrl(), &defaultError);
    if (!loaded) {
      m_lastError = m_lastError.isEmpty() ? defaultError : m_lastError + QLatin1Char('\n') + defaultError;
      qCritical().noquote() << "[shell] default shell failed:\n" << defaultError;
    }
  }

  if (!loaded) {
    // Neither shell loaded: keep the previous generation on screen so the
    // app never loses its window; the overlay shows lastError until the next
    // source change retries.
    m_usingUserShell = previousUsingUserShell;
    m_fingerprint = sourceFingerprint();
    emit generationChanged();
    return;
  }
  // The new window exists before the old one goes, so the app never hits
  // "last window closed" mid-reload.
  for (QObject* root : previous) {
    root->deleteLater();
  }
  if (QQuickWindow* window = rootWindow()) {
    connect(window, &QQuickWindow::closing, this, &ShellRuntime::closed, Qt::UniqueConnection);
    connect(window, &QWindow::activeChanged, this, [this, window] {
      if (window->isActive()) emit activated();
    });
  }
  applyWindowTheme();
  m_fingerprint = sourceFingerprint();
  ++m_generation;
  qInfo().noquote() << "[shell] generation" << m_generation << "loaded from"
                    << (m_usingUserShell ? userShellPath() : defaultShellUrl().toString());
  emit generationChanged();
}

bool ShellRuntime::loadGeneration(const QUrl& rootUrl, QString* errorOut) {
  auto* engine = m_engine;
  const auto previousRootCount = engine->rootObjects().size();
  for (const QString& dir : sourceDirs()) {
    engine->addImportPath(dir);
  }
  const QString userImports = QDir(m_options.configDir).filePath(QStringLiteral("qml"));
  if (QDir(userImports).exists()) {
    engine->addImportPath(userImports);
  }

  // Temporary diagnostic connections must not outlive the captured locals.
  QStringList messages;
  const auto warningsDuringLoad =
      connect(engine, &QQmlEngine::warnings, this, [&messages](const QList<QQmlError>& warnings) {
        for (const auto& warning : warnings) {
          messages << warning.toString();
        }
      });
  bool failed = false;
  const auto creationFailed = connect(engine, &QQmlApplicationEngine::objectCreationFailed, this,
                                      [&failed](const QUrl&) { failed = true; });

  // A file saved in place keeps its URL, and Qt 6.9 answers a URL the previous
  // generation still uses with its old compile, clearComponentCache() or not. A
  // URL of its own per generation compiles the file as it is now.
  QUrl url = rootUrl;
  if (url.isLocalFile()) {
    url.setQuery(QStringLiteral("generation=%1").arg(m_generation + 1));
  }
  engine->load(url);
  disconnect(warningsDuringLoad);
  disconnect(creationFailed);
  for (auto& message : messages) {
    message.replace(url.toString(), rootUrl.toString());
  }
  const auto roots = engine->rootObjects();
  bool hasWindow = false;
  for (auto index = previousRootCount; index < roots.size(); ++index) {
    hasWindow |= qobject_cast<QQuickWindow*>(roots.at(index)) != nullptr;
  }
  if (failed || !hasWindow) {
    for (auto index = previousRootCount; index < roots.size(); ++index) {
      delete roots.at(index);
    }
    if (!failed && roots.size() > previousRootCount) {
      messages << QStringLiteral("Shell root must be a QQuickWindow: %1").arg(rootUrl.toString());
    }
    if (errorOut != nullptr) {
      *errorOut = messages.isEmpty()
                      ? QStringLiteral("Failed to load %1").arg(rootUrl.toString())
                      : messages.join(QLatin1Char('\n'));
    }
    return false;
  }
  return true;
}

void ShellRuntime::rebuildWatchList() {
  QStringList directories;
  const auto collect = [&directories](const QString& root) {
    if (root.isEmpty() || !QDir(root).exists()) {
      return;
    }
    directories << root;
    QDirIterator it(root, QDir::Dirs | QDir::NoDotAndDotDot, QDirIterator::Subdirectories);
    while (it.hasNext()) {
      directories << it.next();
    }
  };
  collect(m_options.configDir);
  for (const QString& dir : sourceDirs()) collect(dir);

  const QStringList watched = m_watcher.directories();
  QStringList added;
  for (const auto& dir : directories) {
    if (!watched.contains(dir)) {
      added << dir;
    }
  }
  if (!added.isEmpty()) {
    m_watcher.addPaths(added);
  }
  const QString userShell = userShellPath();
  if (QFileInfo::exists(userShell) && !m_watcher.files().contains(userShell)) {
    m_watcher.addPath(userShell);
  }
}

QString ShellRuntime::sourceFingerprint() const {
  QCryptographicHash hash(QCryptographicHash::Sha1);
  for (const auto& dir : m_watcher.directories()) {
    QDirIterator it(dir, QDir::Files);
    while (it.hasNext()) {
      const QFileInfo info(it.next());
      if (!isWatchedSource(info)) {
        continue;
      }
      hash.addData(info.absoluteFilePath().toUtf8());
      hash.addData(QByteArray::number(info.lastModified().toMSecsSinceEpoch()));
      hash.addData(QByteArray::number(info.size()));
    }
  }
  return QString::fromLatin1(hash.result().toHex());
}

void ShellRuntime::show() {
  if (QQuickWindow* window = rootWindow()) {
    window->show();
    window->raise();
    window->requestActivate();
  }
}

QQuickWindow* ShellRuntime::rootWindow() const {
  if (m_engine == nullptr) {
    return nullptr;
  }
  const auto roots = m_engine->rootObjects();
  for (auto root = roots.crbegin(); root != roots.crend(); ++root) {
    if (auto* window = qobject_cast<QQuickWindow*>(*root)) {
      return window;
    }
  }
  return nullptr;
}

void ShellRuntime::applyWindowTheme() {
  applyApplicationAppearance(m_theme->windowLiquidGlass() && !m_theme->followsSystemAppearance(),
                             m_theme->appearance() != QStringLiteral("light"));
  if (auto* window = rootWindow()) {
    applyWindowBlur(window, m_theme->windowTransparent() && m_theme->windowBlur(),
                    m_theme->appearance() != QStringLiteral("light"), m_theme->windowLiquidGlass());
  }
  // Markdown takes its links' colour from the application's palette as it is
  // parsed (the timeline's TextEdit has no linkColor of its own).
  QPalette palette = QGuiApplication::palette();
  // Likewise the attached ToolTip, which is the stock Basic one: the web's
  // `bg-popover` (solid, whatever the glass opacity) and its text colour.
  QColor tipBase = m_theme->color(QStringLiteral("surfaceOverlay"), palette.color(QPalette::ToolTipBase));
  tipBase.setAlpha(255);
  const QColor tipText = m_theme->color(QStringLiteral("text"), palette.color(QPalette::ToolTipText));
  if (palette.color(QPalette::Link) != m_theme->link() || palette.color(QPalette::ToolTipBase) != tipBase ||
      palette.color(QPalette::ToolTipText) != tipText) {
    palette.setColor(QPalette::Link, m_theme->link());
    palette.setColor(QPalette::ToolTipBase, tipBase);
    palette.setColor(QPalette::ToolTipText, tipText);
    QGuiApplication::setPalette(palette);
  }
}

bool ShellRuntime::captureWindow(const QString& path) {
  QQuickWindow* window = rootWindow();
  if (window == nullptr) {
    return false;
  }
  const QImage image = window->grabWindow();
  if (image.isNull() || !image.save(path)) {
    qWarning().noquote() << "[shell] screenshot failed:" << path;
    return false;
  }
  qInfo().noquote() << "[shell] screenshot written:" << path;
  return true;
}

bool ShellRuntime::pressKey(const QString& chord) {
  const QKeySequence sequence(chord, QKeySequence::PortableText);
  if (sequence.count() != 1) {
    qWarning().noquote() << "[shell] not a single key chord:" << chord;
    return false;
  }
  QQuickWindow* window = rootWindow();
  if (window == nullptr) {
    return false;
  }
  const QKeyCombination combination = sequence[0];
  const Qt::KeyboardModifiers modifiers = combination.keyboardModifiers();
  const int key = combination.key();
  // Printable keys carry their text like a real press would; chords with
  // Ctrl/Alt/Meta produce none.
  QString text;
  if ((modifiers & ~Qt::ShiftModifier) == Qt::NoModifier && key >= Qt::Key_Space &&
      key <= Qt::Key_ydiaeresis) {
    const QChar character(key);
    text = modifiers.testFlag(Qt::ShiftModifier) ? character.toUpper() : character.toLower();
  }
#if defined(Q_OS_MACOS)
  // Elsewhere a key press tries the shortcuts itself. On macOS that is the
  // Cocoa plugin's doing, which a scripted press does not pass through.
  if (QWindowSystemInterface::handleShortcutEvent(window, 0, key, modifiers, 0, 0, 0, text)) return true;
#endif
  using Delivery = QWindowSystemInterface::SynchronousDelivery;
  QWindowSystemInterface::handleKeyEvent<Delivery>(window, QEvent::KeyPress, key, modifiers, text);
  QWindowSystemInterface::handleKeyEvent<Delivery>(window, QEvent::KeyRelease, key, modifiers,
                                                   text);
  return true;
}
