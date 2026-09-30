#include "SnapShotBackend.h"

#include <QDir>
#include <QFile>
#include <QHash>
#include <QProcess>
#include <QRegularExpression>
#include <QSaveFile>
#include <QStandardPaths>

#ifdef HAL_C2_HAS_DBUS
#include "PortalSnapShot.h"
#endif

namespace {

std::optional<QProcessEnvironment>& environmentOverride() {
  static std::optional<QProcessEnvironment> env;
  return env;
}

SnapShotBackend::PortalFactory& portalFactory() {
  static SnapShotBackend::PortalFactory factory;
  return factory;
}

// X keysym names for the keys a chord may name (linuxCaptureSession.ts).
const QHash<QString, QString>& keyNames() {
  static const QHash<QString, QString> names{
      {QStringLiteral(" "), QStringLiteral("space")},        {QStringLiteral("space"), QStringLiteral("space")},
      {QStringLiteral("escape"), QStringLiteral("Escape")},  {QStringLiteral("esc"), QStringLiteral("Escape")},
      {QStringLiteral("enter"), QStringLiteral("Return")},   {QStringLiteral("tab"), QStringLiteral("Tab")},
      {QStringLiteral("backspace"), QStringLiteral("BackSpace")}, {QStringLiteral("delete"), QStringLiteral("Delete")},
      {QStringLiteral("insert"), QStringLiteral("Insert")},  {QStringLiteral("home"), QStringLiteral("Home")},
      {QStringLiteral("end"), QStringLiteral("End")},        {QStringLiteral("pageup"), QStringLiteral("Page_Up")},
      {QStringLiteral("pagedown"), QStringLiteral("Page_Down")}, {QStringLiteral("arrowup"), QStringLiteral("Up")},
      {QStringLiteral("arrowdown"), QStringLiteral("Down")}, {QStringLiteral("arrowleft"), QStringLiteral("Left")},
      {QStringLiteral("arrowright"), QStringLiteral("Right")}, {QStringLiteral("up"), QStringLiteral("Up")},
      {QStringLiteral("down"), QStringLiteral("Down")},      {QStringLiteral("left"), QStringLiteral("Left")},
      {QStringLiteral("right"), QStringLiteral("Right")},    {QStringLiteral("+"), QStringLiteral("plus")},
      {QStringLiteral("-"), QStringLiteral("minus")},        {QStringLiteral("="), QStringLiteral("equal")},
      {QStringLiteral(","), QStringLiteral("comma")},        {QStringLiteral("."), QStringLiteral("period")},
      {QStringLiteral("/"), QStringLiteral("slash")},        {QStringLiteral(";"), QStringLiteral("semicolon")},
      {QStringLiteral("'"), QStringLiteral("apostrophe")},   {QStringLiteral("["), QStringLiteral("bracketleft")},
      {QStringLiteral("]"), QStringLiteral("bracketright")}, {QStringLiteral("\\"), QStringLiteral("backslash")},
      {QStringLiteral("`"), QStringLiteral("grave")},        {QStringLiteral("!"), QStringLiteral("exclam")},
      {QStringLiteral("@"), QStringLiteral("at")},           {QStringLiteral("#"), QStringLiteral("numbersign")},
      {QStringLiteral("$"), QStringLiteral("dollar")},       {QStringLiteral("%"), QStringLiteral("percent")},
      {QStringLiteral("^"), QStringLiteral("asciicircum")},  {QStringLiteral("&"), QStringLiteral("ampersand")},
      {QStringLiteral("*"), QStringLiteral("asterisk")},     {QStringLiteral("("), QStringLiteral("parenleft")},
      {QStringLiteral(")"), QStringLiteral("parenright")},   {QStringLiteral("_"), QStringLiteral("underscore")},
      {QStringLiteral(":"), QStringLiteral("colon")},        {QStringLiteral("\""), QStringLiteral("quotedbl")},
      {QStringLiteral("{"), QStringLiteral("braceleft")},    {QStringLiteral("}"), QStringLiteral("braceright")},
      {QStringLiteral("|"), QStringLiteral("bar")},          {QStringLiteral("<"), QStringLiteral("less")},
      {QStringLiteral(">"), QStringLiteral("greater")},      {QStringLiteral("?"), QStringLiteral("question")},
      {QStringLiteral("~"), QStringLiteral("asciitilde")},
  };
  return names;
}

}  // namespace

void SnapShotBackend::setEnvironment(const std::optional<QProcessEnvironment>& env) {
  environmentOverride() = env;
}

void SnapShotBackend::setPortalFactory(PortalFactory factory) {
  portalFactory() = std::move(factory);
}

SnapShotBackend::Platform SnapShotBackend::detect(const QProcessEnvironment& env, bool onLinux) {
  if (!onLinux) return {false, {}, QStringLiteral("SnapShots are not supported on this platform.")};
  const QString type = env.value(QStringLiteral("XDG_SESSION_TYPE")).toLower();
  const bool wayland = type == QLatin1String("x11") ? false
                       : type == QLatin1String("wayland") ? true
                                                          : !env.value(QStringLiteral("WAYLAND_DISPLAY")).isEmpty();
  if (!wayland) return {false, {}, QStringLiteral("SnapShots require a Wayland session. X11 capture is not supported.")};
  Platform platform{true, {}, {}};
  // A sandbox's desktop is the portal's business.
  if (!env.contains(QStringLiteral("FLATPAK_ID")) && !env.contains(QStringLiteral("SNAP"))) {
    for (const QString& name : env.value(QStringLiteral("XDG_CURRENT_DESKTOP")).split(QLatin1Char(':'), Qt::SkipEmptyParts)) {
      const QString desktop = name.toLower();
      if (desktop == QLatin1String("gnome") || desktop == QLatin1String("kde") || desktop == QLatin1String("hyprland") ||
          desktop == QLatin1String("niri")) {
        platform.desktop = desktop;
        break;
      }
    }
  }
  return platform;
}

SnapShotBackend* SnapShotBackend::create(QObject* parent) {
#ifdef Q_OS_LINUX
  const bool onLinux = true;
#else
  const bool onLinux = false;
#endif
  const Platform platform = detect(environmentOverride().value_or(QProcessEnvironment::systemEnvironment()), onLinux);
  if (!platform.portal) return new UnavailableSnapShot(platform.message, parent);
  if (portalFactory()) return portalFactory()(platform, parent);
#ifdef HAL_C2_HAS_DBUS
  return new PortalSnapShot(platform, parent);
#else
  return new UnavailableSnapShot(QStringLiteral("SnapShots are not supported on this platform."), parent);
#endif
}

QString SnapShotBackend::portalTrigger(const QJsonObject& shortcut, QString* error) {
  if (shortcut.contains(QLatin1String("kind"))) {
    if (error) {
      *error = QStringLiteral(
          "Modifier-pair shortcuts aren't available in this Wayland session. Choose another shortcut or use Take snapshot from the "
          "command palette.");
    }
    return {};
  }
  static const QRegularExpression plain(QStringLiteral("^[a-z0-9]$"));
  static const QRegularExpression function(QStringLiteral("^f([1-9]|1\\d|2[0-4])$"));
  const QString key = shortcut.value(QLatin1String("key")).toString().toLower();
  QString keysym = keyNames().value(key);
  if (keysym.isEmpty() && (plain.match(key).hasMatch() || function.match(key).hasMatch())) keysym = key.toUpper();
  if (keysym.isEmpty()) {
    if (error) *error = QStringLiteral("This key isn't supported as a Wayland capture shortcut. Choose another key.");
    return {};
  }
  const auto on = [&](const char* name) { return shortcut.value(QLatin1String(name)).toBool(); };
  QStringList parts;
  if (on("ctrlKey") || on("modKey")) parts.append(QStringLiteral("CTRL"));
  if (on("altKey")) parts.append(QStringLiteral("ALT"));
  if (on("shiftKey")) parts.append(QStringLiteral("SHIFT"));
  if (on("metaKey")) parts.append(QStringLiteral("LOGO"));
  parts.append(keysym);
  if (error) error->clear();
  return parts.join(QLatin1Char('+'));
}

// No audio module: the desktop's own player, from a copy of the sound in the
// cache (the players read files).
void SnapShotBackend::play(const QString& sound) {
  const QString name = sound == QLatin1String("camera-shutter") ? QStringLiteral("snap-shot-click.oga")
                                                                : QStringLiteral("snap-shot-whoosh.oga");
  const QString dir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
  const QString path = QDir(dir).filePath(name);
  if (!QFile::exists(path)) {
    QFile source(QStringLiteral(":/hal-c2/sounds/") + name);
    QDir().mkpath(dir);
    QSaveFile target(path);
    if (!source.open(QIODevice::ReadOnly) || !target.open(QIODevice::WriteOnly)) return;
    target.write(source.readAll());
    if (!target.commit()) return;
  }
  for (const auto& [player, arguments] : {std::pair{QStringLiteral("pw-play"), QStringList{path}},
                                          std::pair{QStringLiteral("paplay"), QStringList{path}},
                                          std::pair{QStringLiteral("canberra-gtk-play"), QStringList{QStringLiteral("-f"), path}}}) {
    const QString found = QStandardPaths::findExecutable(player);
    if (found.isEmpty()) continue;
    QProcess::startDetached(found, arguments);
    return;
  }
}
