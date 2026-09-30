#include "ThemeStore.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QRegularExpression>
#include <QStyleHints>

namespace {

// Role names are camelCase in the file, as APP_THEME_VARIABLES in
// apps/web/src/themePalette.ts names them.
bool isRoleName(const QString& name) {
  static const QRegularExpression pattern(QStringLiteral("^[a-z][a-zA-Z0-9]*$"));
  return pattern.match(name).hasMatch();
}

// Keep values to what a colour token can be.
bool isSafeColorValue(const QString& value) {
  static const QRegularExpression pattern(QStringLiteral("^[a-zA-Z0-9#(),.%/ -]+$"));
  return !value.isEmpty() && value.size() < 128 && pattern.match(value).hasMatch();
}

void mergeColors(QVariantMap& into, const QJsonObject& colors) {
  for (auto it = colors.begin(); it != colors.end(); ++it) {
    if (isRoleName(it.key()) && it.value().isString() && isSafeColorValue(it.value().toString())) {
      into.insert(it.key(), it.value().toString());
    }
  }
}

}  // namespace

ThemeStore::ThemeStore(const QString& configDir, QObject* parent)
    : QObject(parent),
      m_configDir(configDir),
      m_path(QDir(configDir).filePath(QStringLiteral("theme.json"))) {
  m_debounce.setSingleShot(true);
  m_debounce.setInterval(80);
  connect(&m_debounce, &QTimer::timeout, this, &ThemeStore::reload);
  connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, [this] {
    watch();
    scheduleReload();
  });
  connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, [this] {
    watch();
    scheduleReload();
  });
  applyDefaults();
  watch();
  reload();
}

void ThemeStore::watch() {
  if (QDir(m_configDir).exists() && !m_watcher.directories().contains(m_configDir)) {
    m_watcher.addPath(m_configDir);
  }
  if (QFileInfo::exists(m_path) && !m_watcher.files().contains(m_path)) {
    m_watcher.addPath(m_path);
  }
}

void ThemeStore::scheduleReload() {
  m_debounce.start();
}

void ThemeStore::applyDefaults() {
  m_loaded = false;
  m_id.clear();
  m_name.clear();
  m_appearance.clear();
  m_fileColors = {};
  m_variants = {};
  m_followsSystemAppearance = false;
  m_colors.clear();
  m_radius.clear();
  m_fontUi.clear();
  m_fontMono.clear();
  m_windowOpacity = 1.0;
  m_windowTransparent = false;
  m_windowBlur = false;
  m_windowLiquidGlass = false;
  m_frameless = true;
  m_lastError.clear();
}

void ThemeStore::reload() {
  QFile file(m_path);
  if (!file.exists()) {
    if (m_loaded || !m_lastContent.isEmpty() || !m_lastError.isEmpty()) {
      m_lastContent.clear();
      applyDefaults();
      emit themeChanged();
    }
    return;
  }
  if (!file.open(QIODevice::ReadOnly)) {
    m_lastError = QStringLiteral("Cannot read %1").arg(m_path);
    emit themeChanged();
    return;
  }
  const QByteArray content = file.readAll();
  if (content == m_lastContent && m_loaded && m_lastError.isEmpty()) {
    return;
  }
  m_lastContent = content;

  QJsonParseError parseError;
  const QJsonDocument doc = QJsonDocument::fromJson(content, &parseError);
  if (parseError.error != QJsonParseError::NoError || !doc.isObject()) {
    // Keep the previous good theme; a half-written file must not flash defaults.
    m_lastError = QStringLiteral("theme.json: %1").arg(parseError.errorString());
    emit themeChanged();
    return;
  }

  applyDefaults();
  const QJsonObject root = doc.object();
  m_loaded = true;
  m_id = root.value(QStringLiteral("id")).toString(QStringLiteral("shell"));
  m_name = root.value(QStringLiteral("name")).toString(m_id);
  m_appearance = root.value(QStringLiteral("appearance")).toString() == QStringLiteral("light")
                     ? QStringLiteral("light")
                     : QStringLiteral("dark");

  m_fileColors = root.value(QStringLiteral("colors")).toObject();
  m_variants = root.value(QStringLiteral("variants")).toObject();
  // Shell-only extras over the base theme's radius and fonts.
  m_radius = root.value(QStringLiteral("radius")).toString();
  const QJsonObject fonts = root.value(QStringLiteral("fonts")).toObject();
  m_fontUi = fonts.value(QStringLiteral("ui")).toString();
  m_fontMono = fonts.value(QStringLiteral("mono")).toString();

  const QJsonObject window = root.value(QStringLiteral("window")).toObject();
  m_followsSystemAppearance = window.value(QStringLiteral("followSystemAppearance")).toBool(false);
  resolveColors();
  m_windowOpacity = qBound(0.1, window.value(QStringLiteral("opacity")).toDouble(1.0), 1.0);
  m_windowTransparent = window.value(QStringLiteral("transparent")).toBool(false);
  m_windowBlur = window.value(QStringLiteral("blur")).toBool(false);
  m_windowLiquidGlass = window.value(QStringLiteral("liquidGlass")).toBool(false);
  m_frameless = window.value(QStringLiteral("frameless")).toBool(true);

  emit themeChanged();
}

void ThemeStore::resolveColors() {
  // Following, the file's variants track the app's appearance: the system's
  // unless the user pinned one (ThemeController).
  if (m_followsSystemAppearance) {
    const bool dark = m_baseAppearance.isEmpty()
                          ? QGuiApplication::styleHints()->colorScheme() == Qt::ColorScheme::Dark
                          : m_baseAppearance == QStringLiteral("dark");
    m_appearance = dark ? QStringLiteral("dark") : QStringLiteral("light");
  }
  m_colors.clear();
  mergeColors(m_colors, m_fileColors);
  mergeColors(m_colors, m_variants.value(m_appearance).toObject());
}

namespace {

// CSS hex colours put alpha last (#rrggbbaa); Qt puts it first (#aarrggbb).
QColor parseCssColor(const QString& value) {
  const QString trimmed = value.trimmed();
  if (trimmed.startsWith(QLatin1Char('#'))) {
    if (trimmed.size() == 9) {
      return QColor(QStringLiteral("#") + trimmed.mid(7, 2) + trimmed.mid(1, 6));
    }
    if (trimmed.size() == 5) {
      const QString r = trimmed.mid(1, 1), g = trimmed.mid(2, 1), b = trimmed.mid(3, 1),
                    a = trimmed.mid(4, 1);
      return QColor(QStringLiteral("#") + a + a + r + r + g + g + b + b);
    }
  }
  return QColor(trimmed);
}

}  // namespace

QColor ThemeStore::color(const QString& role, const QColor& fallback) const {
  for (const QVariantMap* source : {&m_colors, &m_baseColors}) {
    const auto value = source->value(role).toString();
    if (value.isEmpty()) {
      continue;
    }
    const QColor parsed = parseCssColor(value);
    if (parsed.isValid()) {
      return parsed;
    }
  }
  return fallback;
}

namespace {

// The node's theme carries CSS font-family lists; QML wants one family and falls
// back on its own, so take the first installed non-generic entry, or the
// first non-generic one when nothing in the list is installed.
QString firstFontFamily(const QString& list) {
  static const QStringList generic{QStringLiteral("system-ui"), QStringLiteral("sans-serif"),
                                   QStringLiteral("serif"),     QStringLiteral("monospace"),
                                   QStringLiteral("ui-sans-serif"), QStringLiteral("ui-monospace"),
                                   QStringLiteral("-apple-system"), QStringLiteral("BlinkMacSystemFont")};
  QStringList candidates;
  for (QString family : list.split(QLatin1Char(','))) {
    family = family.trimmed();
    if (family.startsWith(QLatin1Char('"')) || family.startsWith(QLatin1Char('\''))) {
      family = family.mid(1);
    }
    if (family.endsWith(QLatin1Char('"')) || family.endsWith(QLatin1Char('\''))) {
      family.chop(1);
    }
    if (!family.isEmpty() && !generic.contains(family)) {
      candidates.append(family);
    }
  }
  for (const QString& family : candidates) {
    if (QFontDatabase::hasFamily(family)) {
      return family;
    }
  }
  return candidates.value(0);
}

}  // namespace

qreal ThemeStore::radius() const {
  if (!m_radius.isEmpty()) {
    // Accept "8", "8px" or "0.5rem" (16px root).
    QString value = m_radius.trimmed();
    if (value.endsWith(QStringLiteral("rem"))) {
      return value.chopped(3).toDouble() * 16.0;
    }
    if (value.endsWith(QStringLiteral("px"))) {
      value.chop(2);
    }
    bool ok = false;
    const qreal parsed = value.toDouble(&ok);
    if (ok) {
      return parsed;
    }
  }
  return m_baseRadius;
}

QString ThemeStore::fontUi() const {
  return m_fontUi.isEmpty() ? firstFontFamily(m_baseFontUi) : firstFontFamily(m_fontUi);
}

QString ThemeStore::fontMono() const {
  return m_fontMono.isEmpty() ? firstFontFamily(m_baseFontMono) : firstFontFamily(m_fontMono);
}

void ThemeStore::applyBaseTheme(const QVariant& theme) {
  const QVariantMap map = theme.toMap();
  if (map.isEmpty() || map == m_baseTheme) {
    return;
  }
  m_baseTheme = map;
  m_baseColors = map.value(QStringLiteral("colors")).toMap();
  m_baseAppearance = map.value(QStringLiteral("appearance")).toString();
  m_baseRadius = map.value(QStringLiteral("radius"), 8).toDouble();
  m_baseFontUi = map.value(QStringLiteral("fontUi")).toString();
  m_baseFontMono = map.value(QStringLiteral("fontMono")).toString();
  if (m_loaded) resolveColors();
  emit themeChanged();
}
