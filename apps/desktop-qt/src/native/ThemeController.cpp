#include "ThemeController.h"

#include <QColor>
#include <QFile>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QStyleHints>

#include <cmath>
#include <optional>

#include "KeybindingController.h"
#include "Keybindings.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<ThemeController> registrar(QStringLiteral("theme"), {QStringLiteral("theme")},
                                                           "Themes");

const QString kLight = QStringLiteral("light");
const QString kDark = QStringLiteral("dark");
// The standard look's id on the page (packages/shared MOBILE_DEFAULT_THEME_ID):
// any non-empty id makes it paint the `--app-theme-*` variables it is given.
const QString kStandardId = QStringLiteral("hal-c2");

const QString kSystem = QStringLiteral("system");
const QString kCustomThemes = QStringLiteral("customThemes");
// The page's wording (apps/web CommandPalette, ThemeSettings).
const QString kSaveFailed = QStringLiteral("Couldn't save theme selection");
const QString kRemoveFailed = QStringLiteral("Couldn’t remove theme");

// apps/web themeIdFromName.
QString idFromName(const QString& name) {
  static const QRegularExpression other(QStringLiteral("[^a-z0-9]+"));
  static const QRegularExpression edges(QStringLiteral("^-+|-+$"));
  const QString id = name.trimmed().toLower().replace(other, QStringLiteral("-")).remove(edges).left(48);
  return id.isEmpty() ? QStringLiteral("custom-theme") : id;
}

QString appearanceOf(const QJsonValue& value) {
  return value.toString() == kDark ? kDark : kLight;
}

QString byte(double channel) {
  return QStringLiteral("%1").arg(qBound(0, static_cast<int>(std::lround(channel * 255.0)), 255), 2, 16,
                                  QLatin1Char('0'));
}

// oklch(L C H [/ A]) to sRGB, clipped to the gamut (the CSS Color 4 matrices).
QString oklchToHex(const QString& body) {
  static const QRegularExpression separator(QStringLiteral("[\\s,/]+"));
  const QStringList parts = body.split(separator, Qt::SkipEmptyParts);
  if (parts.size() < 3 || parts.size() > 4) return {};
  const auto number = [](QString text, double percentScale, bool& ok) {
    if (text == QLatin1String("none")) {
      ok = true;
      return 0.0;
    }
    double scale = 1.0;
    if (text.endsWith(QLatin1Char('%'))) {
      text.chop(1);
      scale = percentScale;
    } else if (text.endsWith(QLatin1String("deg"))) {
      text.chop(3);
    }
    return text.toDouble(&ok) * scale;
  };
  bool ok[4] = {true, true, true, true};
  const double l = number(parts.at(0), 0.01, ok[0]);
  const double c = number(parts.at(1), 0.004, ok[1]);
  const double h = number(parts.at(2), 1.0, ok[2]) * M_PI / 180.0;
  const double alpha = parts.size() == 4 ? number(parts.at(3), 0.01, ok[3]) : 1.0;
  if (!ok[0] || !ok[1] || !ok[2] || !ok[3]) return {};
  const double a = c * std::cos(h), b = c * std::sin(h);
  const double l_ = std::pow(l + 0.3963377774 * a + 0.2158037573 * b, 3);
  const double m_ = std::pow(l - 0.1055613458 * a - 0.0638541728 * b, 3);
  const double s_ = std::pow(l - 0.0894841775 * a - 1.2914855480 * b, 3);
  const auto gamma = [](double linear) {
    linear = qBound(0.0, linear, 1.0);
    return linear <= 0.0031308 ? 12.92 * linear : 1.055 * std::pow(linear, 1.0 / 2.4) - 0.055;
  };
  const double red = gamma(4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_);
  const double green = gamma(-1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_);
  const double blue = gamma(-0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_);
  QString hex = QLatin1Char('#') + byte(red) + byte(green) + byte(blue);
  if (alpha < 1.0) hex += byte(qBound(0.0, alpha, 1.0));
  return hex;
}

// The palette a theme file gives, over `base`: roles this build knows, in
// colours it can draw (apps/web lenientThemeColorOverrides).
QJsonObject overlay(QJsonObject base, const QJsonObject& colors, const QJsonArray& roles) {
  for (auto it = colors.begin(); it != colors.end(); ++it) {
    if (!roles.contains(it.key())) continue;
    const QString color = ThemeController::canonicalColor(it.value().toString());
    if (!color.isEmpty()) base.insert(it.key(), color);
  }
  return base;
}

QJsonObject canonicalColors(const QJsonObject& colors) {
  QJsonObject result;
  for (auto it = colors.begin(); it != colors.end(); ++it) {
    const QString color = ThemeController::canonicalColor(it.value().toString());
    if (!color.isEmpty()) result.insert(it.key(), color);
  }
  return result;
}

// themes.json (scripts/gen-themes.mjs), its colours made drawable once.
struct BuiltIns {
  QJsonArray roles;
  QJsonObject standard;
  QJsonObject defaults;
  QJsonObject fixed;
  double radius = 10;
  QString fontUi;
  QString fontMono;
  QStringList reserved;
  QJsonArray themes;
};

const BuiltIns& builtIns() {
  static const BuiltIns loaded = [] {
    QFile file(QStringLiteral(":/hal-c2/themes.json"));
    if (!file.open(QIODevice::ReadOnly)) qFatal("hal-c2-desktop: the built-in themes are missing");
    const QJsonObject root = QJsonDocument::fromJson(file.readAll()).object();
    const auto perAppearance = [](const QJsonObject& pair) {
      return QJsonObject{{kLight, canonicalColors(pair.value(kLight).toObject())},
                         {kDark, canonicalColors(pair.value(kDark).toObject())}};
    };
    BuiltIns result;
    result.roles = root.value(QLatin1String("roles")).toArray();
    result.standard = perAppearance(root.value(QLatin1String("standard")).toObject());
    result.defaults = perAppearance(root.value(QLatin1String("defaults")).toObject());
    result.fixed = perAppearance(root.value(QLatin1String("fixed")).toObject());
    result.radius = root.value(QLatin1String("radius")).toDouble(10);
    result.fontUi = root.value(QLatin1String("fonts")).toObject().value(QLatin1String("ui")).toString();
    result.fontMono = root.value(QLatin1String("fonts")).toObject().value(QLatin1String("mono")).toString();
    for (const QJsonValue& id : root.value(QLatin1String("reserved")).toArray()) result.reserved.append(id.toString());
    for (const QJsonValue& value : root.value(QLatin1String("builtIn")).toArray()) {
      QJsonObject theme = value.toObject();
      theme.insert(QStringLiteral("colors"), canonicalColors(theme.value(QLatin1String("colors")).toObject()));
      QJsonObject variants;
      const QJsonObject raw = theme.value(QLatin1String("variants")).toObject();
      for (auto it = raw.begin(); it != raw.end(); ++it) variants.insert(it.key(), canonicalColors(it.value().toObject()));
      theme.insert(QStringLiteral("variants"), variants);
      result.themes.append(theme);
    }
    return result;
  }();
  return loaded;
}

}  // namespace

ThemeController::ThemeController(ShellBridge* bridge, NodeClient*, QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      // Built before this one: controllers are built in name order.
      m_settings(NativeShell::of(this)->controller<SettingsController>()) {
  Q_ASSERT(m_settings);
  // The page's theme follows this one from the start, node or no node.
  m_bridge->claimKey(QStringLiteral("theme"));
  const Qt::ColorScheme scheme = QGuiApplication::styleHints()->colorScheme();
  m_systemDark = scheme == Qt::ColorScheme::Dark;
  connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged, this,
          [this](Qt::ColorScheme scheme) { setSystemDark(scheme == Qt::ColorScheme::Dark); });
  connect(m_settings, &SettingsController::deviceChanged, this, &ThemeController::resolve);
  connect(m_settings, &SettingsController::themesChanged, this, &ThemeController::resolve);
  resolve();
}

QString ThemeController::mode() const {
  const QString mode = m_settings->deviceSettings().value(QLatin1String("appearance")).toString();
  return mode == kLight || mode == kDark ? mode : QStringLiteral("system");
}

QString ThemeController::themeId() const {
  return m_settings->deviceSettings().value(QLatin1String("theme")).toString();
}

QVariantMap ThemeController::halves() const {
  return m_settings->deviceSettings().value(QLatin1String("themeHalves")).toObject().toVariantMap();
}

void ThemeController::setSystemDark(bool dark) {
  if (m_systemDark == dark) return;
  m_systemDark = dark;
  resolve();
}

QList<ThemeController::Definition> ThemeController::definitions() const {
  const BuiltIns& data = builtIns();
  QList<Definition> result;
  for (const QJsonValue& value : data.themes) {
    const QJsonObject theme = value.toObject();
    result.append({theme.value(QLatin1String("id")).toString(), theme.value(QLatin1String("label")).toString(),
                   appearanceOf(theme.value(QLatin1String("appearance"))),
                   theme.value(QLatin1String("colors")).toObject(), theme.value(QLatin1String("variants")).toObject(),
                   QStringLiteral("builtIn")});
  }
  // Saved and published themes fill the roles they leave out from the
  // defaults (apps/web getDefaultThemeColors).
  const auto fromFile = [&](const QJsonObject& theme, const QString& source) -> std::optional<Definition> {
    const QString id = theme.value(QLatin1String("id")).toString();
    if (id.isEmpty() || data.reserved.contains(id)) return std::nullopt;
    const QString appearance = appearanceOf(theme.value(QLatin1String("appearance")));
    QJsonObject base = data.defaults.value(appearance).toObject();
    // The seeded short form: a canvas and an accent. The other clients grow a
    // whole palette from them (themePalette.ts createVividThemeColors); this
    // paints the two over the defaults.
    const QString canvas = canonicalColor(theme.value(QLatin1String("canvas")).toString());
    const QString accent = canonicalColor(theme.value(QLatin1String("accent")).toString());
    const bool seeded = !canvas.isEmpty() && !accent.isEmpty();
    if (seeded) {
      for (const char* role : {"canvas", "chrome", "toolbar", "sidebar"}) base.insert(QLatin1String(role), canvas);
      for (const char* role : {"accent", "focus"}) base.insert(QLatin1String(role), accent);
    }
    const QJsonObject colors = theme.value(QLatin1String("colors")).toObject();
    const QJsonObject rawVariants = theme.value(QLatin1String("variants")).toObject();
    QJsonObject variants;
    for (auto it = rawVariants.begin(); it != rawVariants.end(); ++it) {
      if (it.key() == appearance || (it.key() != kLight && it.key() != kDark)) continue;
      const QJsonObject variant = it.value().toObject();
      if (overlay({}, variant, data.roles).isEmpty()) continue;
      variants.insert(it.key(), overlay(data.defaults.value(it.key()).toObject(), variant, data.roles));
    }
    if (!seeded && overlay({}, colors, data.roles).isEmpty() && variants.isEmpty()) return std::nullopt;
    QString label = theme.value(QLatin1String("label")).toString();
    if (label.isEmpty()) label = theme.value(QLatin1String("name")).toString(id);
    return Definition{id, label, appearance, overlay(base, colors, data.roles), variants, source};
  };
  for (const QJsonValue& value : m_settings->deviceSettings().value(QLatin1String("customThemes")).toArray()) {
    if (auto definition = fromFile(value.toObject(), QStringLiteral("custom"))) result.append(*definition);
  }
  for (const QJsonValue& value : m_settings->themes()) {
    if (auto definition = fromFile(value.toObject(), QStringLiteral("environment"))) result.append(*definition);
  }
  return result;
}

// The first with the id: built-in, then this device's, then published, so a
// theme the user saved wins over one the node publishes under its id.
std::optional<ThemeController::Definition> ThemeController::find(const QString& id) const {
  if (id.isEmpty()) return std::nullopt;
  for (const Definition& definition : definitions()) {
    if (definition.id == id) return definition;
  }
  return std::nullopt;
}

QJsonObject ThemeController::colorsFor(const Definition& definition, const QString& appearance) {
  return appearance == definition.appearance ? definition.colors : definition.variants.value(appearance).toObject();
}

QVariantList ThemeController::available() const {
  QVariantList result;
  QStringList seen;
  for (const Definition& definition : definitions()) {
    if (seen.contains(definition.id)) continue;
    seen.append(definition.id);
    QStringList appearances;
    for (const QString& appearance : {kLight, kDark}) {
      if (!colorsFor(definition, appearance).isEmpty()) appearances.append(appearance);
    }
    result.append(QVariantMap{{QStringLiteral("id"), definition.id},
                              {QStringLiteral("label"), definition.label},
                              {QStringLiteral("appearance"), definition.appearance},
                              {QStringLiteral("appearances"), appearances},
                              {QStringLiteral("source"), definition.source}});
  }
  return result;
}

QStringList ThemeController::roles() const {
  QStringList result;
  for (const QJsonValue& role : builtIns().roles) result.append(role.toString());
  return result;
}

void ThemeController::activate() {
  const QString command = KeybindingController::kAppearanceCycle;
  auto* commands = NativeShell::of(this)->controller<KeybindingController>()->commands();
  if (!commands->contains(command)) commands->add(command, keybindings::commandLabel(command), [this] { cycleAppearance(); });

  // The standard look first, then every theme offered; a theme drawn in one
  // appearance takes that half. "Current" is the one drawn now.
  const QString select = QStringLiteral("theme.select");
  commands->addMenu(select, tr("Change theme"), [this] {
    const QString current = halves().value(m_appearance).toString();
    const QString drawn = current.isEmpty() ? themeId() : current;
    QList<CommandRegistry::Choice> choices;
    CommandRegistry::Choice standard;
    standard.id = QStringLiteral("theme:standard");
    standard.title = QStringLiteral("HAL-C2");
    standard.current = drawn.isEmpty();
    standard.terms = {QStringLiteral("theme"), QStringLiteral("appearance")};
    standard.run = [this] { choose({}); };
    choices.append(standard);
    for (const QVariant& value : available()) {
      const QVariantMap theme = value.toMap();
      const QString id = theme.value(QStringLiteral("id")).toString();
      const QStringList appearances = theme.value(QStringLiteral("appearances")).toStringList();
      CommandRegistry::Choice choice;
      choice.id = QStringLiteral("theme:palette:") + id;
      choice.title = theme.value(QStringLiteral("label")).toString();
      if (appearances.size() == 1) choice.description = tr("For %1 mode").arg(appearances.first());
      choice.current = id == drawn;
      choice.terms = {QStringLiteral("theme"), QStringLiteral("appearance")};
      choice.run = [this, id, appearances] {
        if (appearances.size() == 1) {
          chooseHalf(appearances.first(), id);
        } else {
          choose(id);
        }
      };
      choices.append(choice);
    }
    return choices;
  });
  commands->setTerms(select, {QStringLiteral("change theme"), QStringLiteral("appearance"), QStringLiteral("colors"),
                              QStringLiteral("palette")});

  const QString appearance = QStringLiteral("appearance.select");
  commands->addMenu(appearance, tr("Change appearance"), [this] {
    QList<CommandRegistry::Choice> choices;
    for (const auto& [mode, label] : {std::pair{kSystem, tr("System")}, std::pair{kLight, tr("Light")},
                                      std::pair{kDark, tr("Dark")}}) {
      CommandRegistry::Choice choice;
      choice.id = QStringLiteral("appearance:") + mode;
      choice.title = label;
      choice.current = this->mode() == mode;
      choice.terms = {QStringLiteral("appearance"), QStringLiteral("mode")};
      choice.run = [this, mode] { setMode(mode); };
      choices.append(choice);
    }
    return choices;
  });
  commands->setTerms(appearance, {QStringLiteral("change appearance"), QStringLiteral("light"), QStringLiteral("dark"),
                                  QStringLiteral("system"), QStringLiteral("mode"), QStringLiteral("toggle")});

  const QString editor = QStringLiteral("themeEditor.toggle");
  commands->add(editor, tr("Toggle theme editor"), [this] { setEditorOpen(!m_editorOpen); });
  commands->setTerms(editor, {QStringLiteral("theme"), QStringLiteral("appearance"), QStringLiteral("colors"),
                              QStringLiteral("palette"), QStringLiteral("customize")});
}

void ThemeController::setEditorOpen(bool open) {
  if (open == m_editorOpen) return;
  m_editorOpen = open;
  emit editorOpenChanged();
}

bool ThemeController::handle(const QString& action, const QVariant& payload) {
  const QVariantMap map = payload.toMap();
  if (action == QLatin1String("appearance.cycle")) cycleAppearance();
  else if (action == QLatin1String("theme.mode")) setMode(map.value(QStringLiteral("mode")).toString());
  else if (action == QLatin1String("theme.choose")) choose(map.value(QStringLiteral("id")).toString());
  else if (action == QLatin1String("theme.chooseHalf"))
    chooseHalf(map.value(QStringLiteral("appearance")).toString(), map.value(QStringLiteral("id")).toString());
  else return false;
  return true;
}

bool ThemeController::save(const QJsonObject& device, const QString& failure) {
  if (m_settings->setDeviceSettings(device)) return true;
  // Built after this one: looked up when needed.
  if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) {
    toasts->error(failure.isEmpty() ? kSaveFailed : failure, QStringLiteral("Try again."));
  }
  return false;
}

bool ThemeController::setMode(const QString& mode) {
  if (mode != kLight && mode != kDark && mode != kSystem) return false;
  QJsonObject device = m_settings->deviceSettings();
  device.insert(QStringLiteral("appearance"), mode);
  return save(device);
}

bool ThemeController::restoreDefaults() {
  QJsonObject device = m_settings->deviceSettings();
  for (const char* key : {"appearance", "theme", "themeHalves"}) device.remove(QLatin1String(key));
  return save(device, QStringLiteral("Couldn’t restore theme settings"));
}

bool ThemeController::cycleAppearance() {
  const QString current = mode();
  const QString next = current == kSystem ? kLight : current == kLight ? kDark : kSystem;
  if (!setMode(next)) return false;
  if (auto* toasts = NativeShell::of(this)->controller<ToastController>()) {
    // One toast however fast the shortcut is pressed.
    if (!m_cycleToast.isEmpty()) toasts->dismiss(m_cycleToast);
    QString label = next;
    label[0] = label[0].toUpper();
    m_cycleToast = toasts->show(QStringLiteral("info"), QStringLiteral("Appearance: %1").arg(label), {}, {}, 1500);
  }
  return true;
}

QVariantMap ThemeController::draft(const QString& id) const {
  const auto definition = find(id.isEmpty() ? m_resolvedId : id);
  const QString appearance = definition && !colorsFor(*definition, m_appearance).isEmpty()
                                 ? m_appearance
                                 : (definition ? definition->appearance : m_appearance);
  QJsonObject colors = builtIns().standard.value(appearance).toObject();
  if (definition) {
    const QJsonObject own = colorsFor(*definition, appearance);
    for (auto it = own.begin(); it != own.end(); ++it) colors.insert(it.key(), it.value());
  }
  const bool editable = definition && definition->source == QLatin1String("custom");
  return {{QStringLiteral("id"), editable ? definition->id : QString()},
          {QStringLiteral("label"), definition ? definition->label : QStringLiteral("HAL-C2")},
          {QStringLiteral("appearance"), appearance},
          {QStringLiteral("colors"), colors.toVariantMap()}};
}

QString ThemeController::saveCustom(const QVariantMap& theme) {
  const QString label = theme.value(QStringLiteral("label")).toString().trimmed();
  if (label.isEmpty()) return {};
  QJsonObject device = m_settings->deviceSettings();
  QJsonArray saved = device.value(kCustomThemes).toArray();
  const auto indexOf = [&saved](const QString& id) {
    for (qsizetype i = 0; i < saved.size(); ++i) {
      if (saved.at(i).toObject().value(QLatin1String("id")).toString() == id) return i;
    }
    return qsizetype(-1);
  };
  QString id = theme.value(QStringLiteral("id")).toString();
  if (indexOf(id) < 0) {
    // A new theme: an id from its name no other theme or the standard look has.
    const QString base = idFromName(label);
    id = base;
    for (int n = 2; builtIns().reserved.contains(id) || find(id); ++n) id = QStringLiteral("%1-%2").arg(base).arg(n);
  }
  const QJsonObject colors = canonicalColors(QJsonObject::fromVariantMap(theme.value(QStringLiteral("colors")).toMap()));
  const QJsonObject entry{{QStringLiteral("id"), id},
                          {QStringLiteral("label"), label},
                          {QStringLiteral("appearance"), appearanceOf(theme.value(QStringLiteral("appearance")).toString())},
                          {QStringLiteral("colors"), colors}};
  const qsizetype at = indexOf(id);
  if (at < 0) saved.append(entry);
  else saved.replace(at, entry);
  device.insert(kCustomThemes, saved);
  // Saved and applied at once, as the page's editor does.
  device.insert(QStringLiteral("theme"), id);
  device.remove(QStringLiteral("themeHalves"));
  return save(device) ? id : QString();
}

QString ThemeController::duplicate(const QString& id) {
  const auto definition = find(id);
  if (!definition) return {};
  QVariantMap copy = draft(id);
  copy.insert(QStringLiteral("id"), QString());
  copy.insert(QStringLiteral("label"), QStringLiteral("%1 copy").arg(definition->label));
  return saveCustom(copy);
}

bool ThemeController::removeCustom(const QString& id) {
  QJsonObject device = m_settings->deviceSettings();
  QJsonArray saved = device.value(kCustomThemes).toArray();
  QJsonArray kept;
  for (const QJsonValue& value : saved) {
    if (value.toObject().value(QLatin1String("id")).toString() != id) kept.append(value);
  }
  if (kept.size() == saved.size()) return false;
  if (kept.isEmpty()) device.remove(kCustomThemes);
  else device.insert(kCustomThemes, kept);
  if (device.value(QLatin1String("theme")).toString() == id) device.remove(QStringLiteral("theme"));
  QJsonObject halves = device.value(QLatin1String("themeHalves")).toObject();
  for (const QString& appearance : {kLight, kDark}) {
    if (halves.value(appearance).toString() == id) halves.remove(appearance);
  }
  if (halves.isEmpty()) device.remove(QStringLiteral("themeHalves"));
  else device.insert(QStringLiteral("themeHalves"), halves);
  return save(device, kRemoveFailed);
}

bool ThemeController::choose(const QString& id) {
  QJsonObject device = m_settings->deviceSettings();
  if (const auto definition = find(id)) {
    const bool light = !colorsFor(*definition, kLight).isEmpty();
    const bool dark = !colorsFor(*definition, kDark).isEmpty();
    if (light != dark) return chooseHalf(light ? kLight : kDark, id);
  }
  if (id.isEmpty()) device.remove(QStringLiteral("theme"));
  else device.insert(QStringLiteral("theme"), id);
  device.remove(QStringLiteral("themeHalves"));
  return save(device);
}

bool ThemeController::chooseHalf(const QString& appearance, const QString& id) {
  if (appearance != kLight && appearance != kDark) return false;
  QJsonObject device = m_settings->deviceSettings();
  QJsonObject halves = device.value(QLatin1String("themeHalves")).toObject();
  if (id.isEmpty()) halves.remove(appearance);
  else halves.insert(appearance, id);
  if (halves.isEmpty()) device.remove(QStringLiteral("themeHalves"));
  else device.insert(QStringLiteral("themeHalves"), halves);
  return save(device);
}

void ThemeController::resolve() {
  const BuiltIns& data = builtIns();
  const QString chosen = mode();
  const QString target = chosen == QLatin1String("system") ? (m_systemDark ? kDark : kLight) : chosen;
  const QJsonObject halves = m_settings->deviceSettings().value(QLatin1String("themeHalves")).toObject();
  // A theme without the appearance asked for keeps its own, unless a half
  // gives one (apps/web resolveThemeAppearance).
  QString appearance = target;
  if (halves.value(target).toString().isEmpty()) {
    const auto base = find(themeId());
    if (base && colorsFor(*base, target).isEmpty()) appearance = base->appearance;
  }
  QString id = halves.value(appearance).toString();
  if (id.isEmpty()) id = themeId();
  const auto definition = find(id);
  QJsonObject colors = definition ? colorsFor(*definition, appearance) : QJsonObject();
  if (colors.isEmpty()) {
    // No theme, or one no longer anywhere: the standard look.
    id = kStandardId;
    colors = data.standard.value(appearance).toObject();
  }
  const QJsonObject fixed = data.fixed.value(appearance).toObject();
  for (auto it = fixed.begin(); it != fixed.end(); ++it) {
    if (!colors.contains(it.key())) colors.insert(it.key(), it.value());
  }
  m_appearance = appearance;
  m_resolvedId = id;
  m_bridge->publish(QStringLiteral("theme"), QVariantMap{
                                                 {QStringLiteral("id"), id},
                                                 {QStringLiteral("appearance"), appearance},
                                                 {QStringLiteral("colors"), colors.toVariantMap()},
                                                 {QStringLiteral("radius"), data.radius},
                                                 {QStringLiteral("fontUi"), data.fontUi},
                                                 {QStringLiteral("fontMono"), data.fontMono},
                                             });
  // The choice and `available` move with the device and the node as well.
  emit changed();
}

QString ThemeController::canonicalColor(const QString& css) {
  const QString value = css.trimmed().toLower();
  if (value.isEmpty() || value.size() > 64) return {};
  if (value.startsWith(QLatin1Char('#'))) {
    static const QRegularExpression hex(QStringLiteral("^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$"));
    if (!hex.match(value).hasMatch()) return {};
    if (value.size() > 5) return value;
    QString expanded = QStringLiteral("#");
    for (const QChar digit : value.mid(1)) expanded += QString(2, digit);
    return expanded;
  }
  if (value.startsWith(QLatin1String("oklch(")) && value.endsWith(QLatin1Char(')'))) {
    return oklchToHex(value.mid(6).chopped(1));
  }
  const QColor named = QColor::fromString(value);
  return named.isValid() ? named.name(QColor::HexRgb) : QString();
}
