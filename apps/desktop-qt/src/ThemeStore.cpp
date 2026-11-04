#include "ThemeStore.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFontDatabase>
#include <QFontInfo>
#include <QGuiApplication>
#include <QHash>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QSet>
#include <QStyleHints>

namespace {

// Role names are camelCase in the file.
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

// The font the application started with: the system's.
const QFont& systemFont() {
  static const QFont font = QGuiApplication::font();
  return font;
}

// Everything that writes text under `object`: Text, TextInput, TextEdit and
// the controls (a Label is a Text, a TextField a TextInput). Reached through
// the items drawn and through their owners, so a closed popup's are found too.
void collectText(QObject* object, QSet<QObject*>& seen, QList<QPointer<QQuickItem>>& found) {
  if (!object || seen.contains(object)) return;
  seen.insert(object);
  auto* item = qobject_cast<QQuickItem*>(object);
  if (item) {
    for (const char* type : {"QQuickText", "QQuickTextInput", "QQuickTextEdit", "QQuickControl"}) {
      if (item->inherits(type)) {
        found.append(item);
        break;
      }
    }
    for (QQuickItem* child : item->childItems()) collectText(child, seen, found);
  }
  for (QObject* child : object->children()) collectText(child, seen, found);
}

}  // namespace

ThemeStore::~ThemeStore() {
  // The font is the application's, not this store's: leave it as it was found.
  if (!m_interfaceFont.isEmpty() && qobject_cast<QGuiApplication*>(QCoreApplication::instance())) QGuiApplication::setFont(systemFont());
}

void ThemeStore::applyInterfaceFont() {
  if (!qobject_cast<QGuiApplication*>(QCoreApplication::instance())) return;
  systemFont();
  const QString family = fontUi();
  if (family == m_interfaceFont) return;
  m_interfaceFont = family;
  QFont font = systemFont();
  if (!family.isEmpty()) font.setFamilies({family});
  QGuiApplication::setFont(font);
  // Text made from here on starts in the new font. What is already drawn
  // took a copy of the old one: give each its family, unless it names its own
  // (code, the terminal, a brick bound to the theme). The mask is kept, so
  // the family stays inherited and the next change reaches it as well.
  QSet<QObject*> seen;
  QList<QPointer<QQuickItem>> written;
  for (QWindow* window : QGuiApplication::allWindows()) collectText(window, seen, written);
  for (const QPointer<QQuickItem>& item : std::as_const(written)) {
    if (!item) continue;
    QFont own = item->property("font").value<QFont>();
    const uint mask = own.resolveMask();
    if (mask & (QFont::FamilyResolved | QFont::FamiliesResolved)) continue;
    own.setFamilies(font.families());
    own.setResolveMask(mask);
    item->setProperty("font", own);
  }
}

ThemeStore::ThemeStore(const QString& configDir, QObject* parent)
    : QObject(parent),
      m_configDir(configDir),
      m_path(QDir(configDir).filePath(QStringLiteral("theme.json"))) {
  m_debounce.setSingleShot(true);
  m_debounce.setInterval(80);
  connect(&m_debounce, &QTimer::timeout, this, &ThemeStore::reload);
  connect(this, &ThemeStore::themeChanged, this, &ThemeStore::applyInterfaceFont);
  connect(this, &ThemeStore::themeChanged, this, &ThemeStore::applyType);
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
  applyType();
}

void ThemeTypeStep::set(int size, int lineHeight, int weight) {
  if (size == m_size && lineHeight == m_lineHeight && weight == m_weight) return;
  m_size = size;
  m_lineHeight = lineHeight;
  m_weight = weight;
  emit changed();
}

void ThemeTypeRamp::apply(qreal scale, bool monospace) {
  // Sans sizes and line heights; a monospace face gets two more pixels of
  // leading on every step and a smaller display, since its glyphs run wide.
  const int leading = monospace ? 2 : 0;
  const auto step = [&](ThemeTypeStep& target, int size, int lineHeight, int weight) {
    target.set(qRound(size * scale), qRound(lineHeight * scale) + leading, weight);
  };
  step(m_caption, 11, 16, 500);
  step(m_meta, 12, 16, 400);
  step(m_body, 13, 18, 400);
  step(m_prose, 14, 22, 400);
  step(m_title, 16, 22, 600);
  if (monospace) m_display.set(qRound(22 * scale), qRound(28 * scale), 600);
  else step(m_display, 24, 30, 600);
}

void ThemeStore::applyType() {
  bool monospace = false;
  if (qobject_cast<QGuiApplication*>(QCoreApplication::instance())) {
    const QString family = fontUi();
    if (!family.isEmpty()) {
      QFont font;
      font.setFamilies({family});
      monospace = QFontInfo(font).fixedPitch();
    }
  }
  m_type.apply(fontScale(), monospace);
  if (monospace != m_monospace) {
    m_monospace = monospace;
    emit themeChanged();
  }
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

namespace {

QColor mix(const QColor& from, const QColor& to, qreal amount) {
  return QColor::fromRgbF(from.redF() + (to.redF() - from.redF()) * amount, from.greenF() + (to.greenF() - from.greenF()) * amount,
                          from.blueF() + (to.blueF() - from.blueF()) * amount, from.alphaF() + (to.alphaF() - from.alphaF()) * amount);
}

// Roles under two names: a newer one and the one themes already set.
const QHash<QString, QString>& renames() {
  static const QHash<QString, QString> pairs{
      {QStringLiteral("ink"), QStringLiteral("text")},           {QStringLiteral("text"), QStringLiteral("ink")},
      {QStringLiteral("inkTertiary"), QStringLiteral("textMuted")}, {QStringLiteral("textMuted"), QStringLiteral("inkTertiary")},
      {QStringLiteral("destructive"), QStringLiteral("error")},  {QStringLiteral("error"), QStringLiteral("destructive")},
      {QStringLiteral("popover"), QStringLiteral("surfaceOverlay")}, {QStringLiteral("surfaceOverlay"), QStringLiteral("popover")},
  };
  return pairs;
}

// A role derived from others when a palette leaves it out: a mix of two
// roles, or a copy of one (b empty).
struct Derivation {
  const char* a;
  const char* b;
  qreal amount;
};

const QHash<QString, Derivation>& derivations() {
  static const QHash<QString, Derivation> table{
      {QStringLiteral("inkSecondary"), {"ink", "inkTertiary", 0.5}},
      {QStringLiteral("borderStrong"), {"border", "ink", 0.12}},
      {QStringLiteral("inset"), {"codeBackground", nullptr, 0}},
      {QStringLiteral("inputSurface"), {"surface", nullptr, 0}},
      {QStringLiteral("accentText"), {"accent", nullptr, 0}},
      {QStringLiteral("diffAddedSurface"), {"canvas", "diffAdded", 0.14}},
      {QStringLiteral("diffRemovedSurface"), {"canvas", "diffRemoved", 0.14}},
  };
  return table;
}

// A role a palette names, under either of its names.
QColor named(const QVariantMap& palette, const QString& role) {
  const QColor own = parseCssColor(palette.value(role).toString());
  if (own.isValid()) return own;
  const QString other = renames().value(role);
  return other.isEmpty() ? QColor() : parseCssColor(palette.value(other).toString());
}

// A derived role from `lookup`, which resolves the roles it is made of.
template <typename Lookup>
QColor derive(const Derivation& recipe, Lookup lookup) {
  const QColor first = lookup(QLatin1String(recipe.a));
  if (!recipe.b) return first;
  const QColor second = lookup(QLatin1String(recipe.b));
  return first.isValid() && second.isValid() ? mix(first, second, recipe.amount) : QColor();
}

// A role in one palette alone: named, or derived from what it names.
QColor resolveIn(const QVariantMap& palette, const QString& role) {
  const QColor own = named(palette, role);
  if (own.isValid()) return own;
  const auto recipe = derivations().constFind(role);
  return recipe == derivations().constEnd() ? QColor() : derive(*recipe, [&](const QString& r) { return named(palette, r); });
}

}  // namespace

QColor ThemeStore::color(const QString& role, const QColor& fallback) const {
  // The shell's theme file first, then the base theme. A derived role the
  // file leaves out still follows the file when it sets what the role is made
  // of: its own text, say, gives its own secondary ink.
  const QColor shell = named(m_colors, role);
  if (shell.isValid()) return shell;
  const auto recipe = derivations().constFind(role);
  if (recipe != derivations().constEnd() &&
      (named(m_colors, QLatin1String(recipe->a)).isValid() || (recipe->b && named(m_colors, QLatin1String(recipe->b)).isValid()))) {
    const QColor derived = derive(*recipe, [this](const QString& r) { return color(r, QColor()); });
    if (derived.isValid()) return derived;
  }
  const QColor base = resolveIn(m_baseColors, role);
  if (base.isValid()) return base;
  // What dims the window behind a dialog, when no palette says.
  if (role == QLatin1String("scrim")) {
    return appearance() == QStringLiteral("light") ? QColor(0x14, 0x16, 0x1a, 82) : QColor(0, 0, 0, 143);
  }
  return fallback;
}

namespace {

// The MC's theme carries CSS font-family lists; QML wants one family and falls
// back on its own, so take the first installed non-generic entry, or the
// first non-generic one when nothing in the list is installed. With
// `orSystem`, a list that ends in the system's font ("Segoe UI", system-ui)
// and has nothing installed is empty instead: the system's own font, as CSS
// resolves it, not Qt's stand-in for a family this machine lacks.
QString firstFontFamily(const QString& list, bool orSystem = false) {
  static const QStringList generic{QStringLiteral("system-ui"), QStringLiteral("sans-serif"),
                                   QStringLiteral("serif"),     QStringLiteral("monospace"),
                                   QStringLiteral("ui-sans-serif"), QStringLiteral("ui-monospace"),
                                   QStringLiteral("-apple-system"), QStringLiteral("BlinkMacSystemFont")};
  static const QStringList system{QStringLiteral("system-ui"), QStringLiteral("sans-serif"), QStringLiteral("ui-sans-serif"),
                                  QStringLiteral("-apple-system"), QStringLiteral("BlinkMacSystemFont")};
  bool endsInSystem = false;
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
    endsInSystem = endsInSystem || system.contains(family);
  }
  for (const QString& family : candidates) {
    if (QFontDatabase::hasFamily(family)) {
      return family;
    }
  }
  return orSystem && endsInSystem ? QString() : candidates.value(0);
}

// A monospace family that is not installed (a phone has none of a desktop's)
// is drawn with the system's fixed-width font: Qt's own stand-in for a family
// it lacks is proportional, which spreads a terminal's cells and unaligns
// code. The family keeps the name the theme gave it.
QString fixedWidth(const QString& family) {
  static QSet<QString> seen;
  if (!family.isEmpty() && !seen.contains(family)) {
    seen.insert(family);
    if (!QFontDatabase::hasFamily(family)) {
      QFont::insertSubstitution(family, QFontDatabase::systemFont(QFontDatabase::FixedFont).family());
    }
  }
  return family;
}

}  // namespace

QColor ThemeStore::link() const {
  return QColor(appearance() == QStringLiteral("light") ? QStringLiteral("#1d4ed8") : QStringLiteral("#60a5fa"));
}

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
  return firstFontFamily(m_fontUi.isEmpty() ? m_baseFontUi : m_fontUi, true);
}

QString ThemeStore::fontMono() const {
  return fixedWidth(m_fontMono.isEmpty() ? firstFontFamily(m_baseFontMono) : firstFontFamily(m_fontMono));
}

QString ThemeStore::fontPrompt() const {
  const QString own = m_baseTheme.value(QStringLiteral("fontPrompt")).toString();
  return own.isEmpty() ? fontUi() : firstFontFamily(own);
}

QString ThemeStore::fontTerminal() const {
  const QString own = m_baseTheme.value(QStringLiteral("fontTerminal")).toString();
  return own.isEmpty() ? fontMono() : fixedWidth(firstFontFamily(own));
}

int ThemeStore::fontSize(const char* part, int fallback) const {
  const int size = m_baseTheme.value(QStringLiteral("fontSizes")).toMap().value(QLatin1String(part)).toInt();
  return size > 0 ? size : fallback;
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
