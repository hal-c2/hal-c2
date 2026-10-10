#include "ThemeController.h"

#include <QColor>
#include <QFile>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QQmlPropertyMap>
#include <QRegularExpression>
#include <QStyleHints>

#include <cmath>
#include <optional>

#include <QFileInfo>
#include <QSaveFile>

#include "KeybindingController.h"
#include "Keybindings.h"
#include "MenuController.h"
#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ToastController.h"

namespace {

const NativeControllerRegistrar<ThemeController> registrar(QStringLiteral("theme"), {QStringLiteral("theme")},
                                                           "Themes");

const QString kLight = QStringLiteral("light");
const QString kDark = QStringLiteral("dark");
// The standard look's id.
const QString kStandardId = QStringLiteral("hal-c2");

const QString kSystem = QStringLiteral("system");
const QString kCustomThemes = QStringLiteral("customThemes");
// The wording of the theme failures.
const QString kSaveFailed = QStringLiteral("Couldn't save theme selection");
const QString kRemoveFailed = QStringLiteral("Couldn’t remove theme");

// A theme's id from its name.
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
// colours it can draw.
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

ThemeController::ThemeController(ShellBridge* bridge, McClient*, QObject* parent)
    : QObject(parent),
      m_bridge(bridge),
      // Built before this one: controllers are built in name order.
      m_settings(NativeShell::of(this)->controller<SettingsController>()) {
  Q_ASSERT(m_settings);
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
  // defaults.
  const auto fromFile = [&](const QJsonObject& theme, const QString& source) -> std::optional<Definition> {
    const QString id = theme.value(QLatin1String("id")).toString();
    if (id.isEmpty() || data.reserved.contains(id)) return std::nullopt;
    const QString appearance = appearanceOf(theme.value(QLatin1String("appearance")));
    QJsonObject base = data.defaults.value(appearance).toObject();
    // The seeded short form: a canvas and an accent, painted over the defaults.
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
    return Definition{id, label, appearance, overlay(base, colors, data.roles), variants, source,
                      theme.value(QLatin1String("collection")).toObject().value(QLatin1String("label")).toString()};
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
// theme the user saved wins over one the MC publishes under its id.
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
                              {QStringLiteral("source"), definition.source},
                              {QStringLiteral("collection"), definition.collection}});
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
  // Opened by its toggle: on the theme drawn now. Closed: the draft goes.
  if (open && m_editing.isEmpty()) m_editing = draft();
  if (!open) m_editing.clear();
  if (!open && (m_inspecting || !m_picked.isEmpty())) {
    m_inspecting = false;
    m_picked.clear();
    emit inspectChanged();
  }
  m_editorOpen = open;
  emit editingChanged();
  emit editorOpenChanged();
}

void ThemeController::setInspecting(bool inspecting) {
  if (inspecting == m_inspecting) return;
  m_inspecting = inspecting;
  if (inspecting) m_picked.clear();
  emit inspectChanged();
}

void ThemeController::pick(const QString& color) {
  if (!m_inspecting) return;
  const QColor wanted(canonicalColor(color));
  QStringList roles;
  if (wanted.isValid()) {
    // The roles the window draws in that colour now.
    const QVariantMap drawn = m_bridge->state()->value(QStringLiteral("theme")).toMap().value(QStringLiteral("colors")).toMap();
    for (const QString& role : this->roles()) {
      if (QColor(drawn.value(role).toString()).rgb() == wanted.rgb()) roles.append(role);
    }
  }
  m_inspecting = false;
  m_picked = {{QStringLiteral("color"), wanted.isValid() ? wanted.name(QColor::HexRgb) : QString()},
              {QStringLiteral("role"), roles.value(0)},
              {QStringLiteral("roles"), roles},
              {QStringLiteral("count"), roles.size()}};
  emit inspectChanged();
}

void ThemeController::edit(const QVariantMap& draft) {
  m_editing = draft;
  emit editingChanged();
  setEditorOpen(true);
}

void ThemeController::setEditing(const QVariantMap& draft) {
  if (!m_editorOpen || draft == m_editing) return;
  m_editing = draft;
  emit editingChanged();
}

void ThemeController::requestRemove(const QString& id) {
  const auto definition = find(id);
  if (!definition || definition->source != QLatin1String("custom")) return;
  NativeShell::of(this)->controller<MenuController>()->confirm(
      tr("Remove “%1”?").arg(definition->label), tr("This device will no longer offer it."), tr("Remove"), true,
      [this, id] { removeCustom(id); });
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
  // Saved and applied at once.
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

void ThemeController::requestRemoveMany(const QStringList& ids) {
  QStringList own;
  for (const QString& id : ids) {
    if (const auto definition = find(id); definition && definition->source == QLatin1String("custom")) own.append(id);
  }
  if (own.isEmpty()) return;
  if (own.size() == 1) return requestRemove(own.first());
  NativeShell::of(this)->controller<MenuController>()->confirm(
      tr("Remove %1 themes?").arg(own.size()), tr("This device will no longer offer them."), tr("Remove"), true,
      [this, own] { removeCustomMany(own); });
}

bool ThemeController::removeCustom(const QString& id) {
  return removeCustomMany({id});
}

bool ThemeController::removeCustomMany(const QStringList& ids) {
  QJsonObject device = m_settings->deviceSettings();
  QJsonArray saved = device.value(kCustomThemes).toArray();
  QJsonArray kept;
  for (const QJsonValue& value : saved) {
    if (!ids.contains(value.toObject().value(QLatin1String("id")).toString())) kept.append(value);
  }
  if (kept.size() == saved.size()) return false;
  if (kept.isEmpty()) device.remove(kCustomThemes);
  else device.insert(kCustomThemes, kept);
  if (ids.contains(device.value(QLatin1String("theme")).toString())) device.remove(QStringLiteral("theme"));
  QJsonObject halves = device.value(QLatin1String("themeHalves")).toObject();
  for (const QString& appearance : {kLight, kDark}) {
    if (ids.contains(halves.value(appearance).toString())) halves.remove(appearance);
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
  // gives one.
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
  // The interface rows of Settings → Appearance that are colours: what diffs
  // draw additions and deletions in, and how solid menus, dialogs and the
  // composer are.
  const bool blueOrange = m_settings->setting(QStringLiteral("diffColorScheme")).toString() == QLatin1String("blue-orange");
  colors.insert(QStringLiteral("diffAdded"), blueOrange ? QStringLiteral("#3b82f6") : QStringLiteral("#22c55e"));
  colors.insert(QStringLiteral("diffRemoved"), blueOrange ? QStringLiteral("#f97316") : QStringLiteral("#ef4444"));
  const int glass = qBound(40, m_settings->setting(QStringLiteral("glassOpacity")).toInt(), 100);
  if (glass < 100) {
    QColor overlay(colors.value(QLatin1String("surfaceOverlay")).toString());
    if (overlay.isValid()) {
      overlay.setAlphaF(overlay.alphaF() * glass / 100.0);
      colors.insert(QStringLiteral("surfaceOverlay"), overlay.name(QColor::HexArgb).replace(
                                                          QRegularExpression(QStringLiteral("^#(..)(......)$")), QStringLiteral("#\\2\\1")));
    }
  }
  // The font rows of Settings → Appearance: a family the user named wins over
  // the theme's, and each part of the app has its size.
  const auto family = [this](const char* key, const QString& fallback) {
    const QString chosen = m_settings->setting(QLatin1String(key)).toString().trimmed();
    return chosen.isEmpty() ? fallback : chosen;
  };
  const auto size = [this](const char* key, int fallback) {
    const int chosen = m_settings->setting(QLatin1String(key)).toInt();
    return chosen > 0 ? chosen : fallback;
  };
  m_appearance = appearance;
  m_resolvedId = id;
  m_bridge->publish(QStringLiteral("theme"), QVariantMap{
                                                 {QStringLiteral("id"), id},
                                                 {QStringLiteral("appearance"), appearance},
                                                 {QStringLiteral("colors"), colors.toVariantMap()},
                                                 {QStringLiteral("radius"), data.radius},
                                                 {QStringLiteral("fontUi"), family("fontFamilySans", data.fontUi)},
                                                 {QStringLiteral("fontMono"), family("fontFamilyCode", data.fontMono)},
                                                 // Empty: the composer writes in the interface font, the terminal in the code font.
                                                 {QStringLiteral("fontPrompt"), family("fontFamilyComposer", QString())},
                                                 {QStringLiteral("fontTerminal"), family("fontFamilyTerminal", QString())},
                                                 {QStringLiteral("fontSizes"),
                                                  QVariantMap{{QStringLiteral("interface"), size("fontSizeInterface", 16)},
                                                              {QStringLiteral("prompt"), size("fontSizePrompt", 14)},
                                                              {QStringLiteral("code"), size("fontSizeCode", 13)},
                                                              {QStringLiteral("terminal"), size("fontSizeTerminal", 12)}}},
                                             });
  // The choice and `available` move with the device and the MC as well.
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

// --- The editor's palette ----------------------------------------------------------

namespace {

struct Oklch {
  double l = 0, c = 0, h = 0;
};

double linear(double channel) {
  return channel <= 0.04045 ? channel / 12.92 : std::pow((channel + 0.055) / 1.055, 2.4);
}

double luminance(const QColor& color) {
  return 0.2126 * linear(color.redF()) + 0.7152 * linear(color.greenF()) + 0.0722 * linear(color.blueF());
}

double contrast(const QColor& a, const QColor& b) {
  const double la = luminance(a), lb = luminance(b);
  return (std::max(la, lb) + 0.05) / (std::min(la, lb) + 0.05);
}

Oklch toOklch(const QColor& color) {
  const double r = linear(color.redF()), g = linear(color.greenF()), b = linear(color.blueF());
  const double l = std::cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const double m = std::cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const double s = std::cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  const double a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
  const double bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
  double hue = std::atan2(bb, a) * 180.0 / M_PI;
  if (hue < 0) hue += 360.0;
  return {0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, std::hypot(a, bb), hue};
}

QColor fromOklch(const Oklch& color) {
  return QColor(oklchToHex(QStringLiteral("%1 %2 %3").arg(color.l, 0, 'f', 5).arg(color.c, 0, 'f', 5).arg(color.h, 0, 'f', 3)));
}

// `base` moved lighter or darker until it reads against `against`.
QColor solve(Oklch base, const QColor& against, double ratio, bool lighter) {
  QColor color = fromOklch(base);
  for (int step = 0; step < 60 && contrast(color, against) < ratio; ++step) {
    base.l = qBound(0.0, base.l + (lighter ? 0.015 : -0.015), 1.0);
    color = fromOklch(base);
  }
  return color;
}

QColor readableOn(const QColor& surface) {
  const QColor light(QStringLiteral("#ffffff")), dark(QStringLiteral("#111111"));
  return contrast(light, surface) >= contrast(dark, surface) ? light : dark;
}

}  // namespace

QVariantList ThemeController::families() const {
  // The web editor's groups (ThemeEditorPanel), over this build's roles.
  static const QList<std::pair<QString, QStringList>> prefixes{
      {QStringLiteral("Status"), {QStringLiteral("error"), QStringLiteral("warning"), QStringLiteral("update")}},
      {QStringLiteral("Context"), {QStringLiteral("sidebar"), QStringLiteral("terminal")}},
      {QStringLiteral("Brand & content"),
       {QStringLiteral("accent"), QStringLiteral("secondary"), QStringLiteral("muted"), QStringLiteral("message"),
        QStringLiteral("code"), QStringLiteral("focus")}},
  };
  QMap<QString, QStringList> byFamily;
  for (const QString& role : roles()) {
    QString family = QStringLiteral("Foundation");
    for (const auto& [title, starts] : prefixes) {
      if (std::any_of(starts.cbegin(), starts.cend(), [&role](const QString& start) { return role.startsWith(start); })) {
        family = title;
        break;
      }
    }
    byFamily[family].append(role);
  }
  QVariantList result;
  for (const QString& title : {QStringLiteral("Foundation"), QStringLiteral("Brand & content"), QStringLiteral("Context"),
                               QStringLiteral("Status")}) {
    result.append(QVariantMap{{QStringLiteral("title"), title}, {QStringLiteral("roles"), byFamily.value(title)}});
  }
  return result;
}

QVariantMap ThemeController::derive(const QString& canvasValue, const QString& accentValue) const {
  const QColor canvas(canonicalColor(canvasValue));
  const QColor accent(canonicalColor(accentValue));
  if (!canvas.isValid() || !accent.isValid()) return {};
  // Follows the canvas picked, not an appearance: 0.179 is where white and
  // black text read equally well.
  const bool dark = luminance(canvas) < 0.179;
  const Oklch base = toOklch(canvas);
  const Oklch tone = toOklch(accent);
  const double hue = tone.c < 0.02 ? base.h : tone.h;
  const double tint = qBound(0.008, tone.c * 0.22, 0.045);
  const auto surface = [&](double delta, double chroma) {
    return fromOklch({qBound(0.05, base.l + (dark ? delta : -delta), 0.98), chroma, hue});
  };
  const QColor text = solve({dark ? 0.95 : 0.2, std::min(0.035, tone.c * 0.25), hue}, canvas, 7, dark);
  QColor textMuted = QColor::fromRgbF(text.redF() * 0.65 + canvas.redF() * 0.35, text.greenF() * 0.65 + canvas.greenF() * 0.35,
                                      text.blueF() * 0.65 + canvas.blueF() * 0.35);
  if (contrast(textMuted, canvas) < 4.5) textMuted = text;
  const QColor border = surface(dark ? 0.16 : 0.12, std::min(0.07, tone.c * 0.35));
  const QColor input = surface(dark ? 0.21 : 0.16, std::min(0.08, tone.c * 0.4));
  const QColor raised = surface(0.05, tint);
  const QColor overlay = surface(0.075, tint);
  const QColor accentSurface = surface(dark ? 0.13 : 0.08, std::min(0.11, tone.c * 0.55));
  // The companion action turns off the accent's hue.
  const Oklch actionTone{qBound(0.35, tone.l + (dark ? 0.06 : -0.02), 0.85), std::max(tone.c * 0.9, 0.06), std::fmod(hue + 50, 360.0)};
  const QColor action = fromOklch(actionTone);

  QJsonObject colors = builtIns().defaults.value(dark ? kDark : kLight).toObject();  // the status colours
  const auto set = [&colors](const char* role, const QColor& color) { colors.insert(QLatin1String(role), color.name(QColor::HexRgb)); };
  for (const char* role : {"canvas", "chrome", "toolbar", "terminalBackground"}) set(role, canvas);
  for (const char* role : {"text", "toolbarForeground", "toolbarControlForeground", "secondaryForeground", "accentSurfaceForeground",
                           "messageForeground", "codeForeground", "sidebarForeground", "terminalForeground"}) {
    set(role, text);
  }
  for (const char* role : {"textMuted", "mutedForeground", "placeholder", "secondaryLabel", "iconMuted", "sidebarMutedForeground"}) {
    set(role, textMuted);
  }
  for (const char* role : {"border", "toolbarBorder", "sidebarBorder", "terminalScrollbar"}) set(role, border);
  for (const char* role : {"accent", "focus", "terminalCursor"}) set(role, accent);
  set("accentForeground", readableOn(accent));
  set("surface", surface(0.015, tint));
  set("surfaceRaised", raised);
  set("toolbarControl", raised);
  set("surfaceOverlay", overlay);
  set("toolbarControlHover", overlay);
  set("input", input);
  set("terminalScrollbarHover", input);
  set("secondary", surface(dark ? 0.1 : 0.06, std::min(0.09, tone.c * 0.5)));
  set("muted", surface(dark ? 0.06 : 0.04, std::min(0.06, tone.c * 0.35)));
  set("accentSurface", accentSurface);
  set("terminalSelection", accentSurface);
  set("messageSurface", surface(dark ? 0.16 : 0.1, std::min(0.13, tone.c * 0.6)));
  set("messageAction", action);
  set("messageActionForeground", readableOn(action));
  set("messageActionHover", fromOklch({qBound(0.3, actionTone.l + (dark ? 0.05 : -0.05), 0.9), actionTone.c, actionTone.h}));
  set("codeBackground", surface(0.035, tint * 0.8));
  set("sidebar", surface(0.045, tint * 1.4));
  set("sidebarControlSurface", surface(0.08, tint));
  set("sidebarRowHover", surface(0.09, tint));
  set("sidebarRowActive", surface(0.12, tint));
  set("sidebarRowSelected", surface(0.14, tint));
  return colors.toVariantMap();
}

// --- Importing and exporting -------------------------------------------------------

namespace {

QString byteSize(qint64 bytes) {
  return bytes >= 1024 * 1024 ? QStringLiteral("%1 MB").arg(bytes / (1024.0 * 1024.0), 0, 'f', 1)
                              : QStringLiteral("%1 KB").arg(std::max<qint64>(1, bytes / 1024));
}

QString oversized(qint64 bytes) {
  if (bytes <= ThemeController::kMaxThemeFileBytes) return {};
  return QStringLiteral("That file is %1. Theme files are only a few KB, so this one was not read (limit %2).")
      .arg(byteSize(bytes), byteSize(ThemeController::kMaxThemeFileBytes));
}

}  // namespace

bool ThemeController::installed(const QString& id) const {
  for (const QJsonValue& value : m_settings->deviceSettings().value(kCustomThemes).toArray()) {
    if (value.toObject().value(QLatin1String("id")).toString() == id) return true;
  }
  return false;
}

QStringList ThemeController::importConflicts() const {
  QStringList labels;
  for (const QJsonValue& value : m_importConflicts) labels.append(value.toObject().value(QLatin1String("label")).toString());
  return labels;
}

// --- VS Code themes ------------------------------------------------------------------

namespace {

struct VsColor {
  double r = 0, g = 0, b = 0, a = 1;
  bool valid = false;
  QColor solid() const { return QColor::fromRgbF(r, g, b); }
};

// VS Code writes #RGB, #RGBA, #RRGGBB and #RRGGBBAA.
VsColor vsColor(const QJsonValue& value) {
  static const QRegularExpression hex(QStringLiteral("^#?([0-9a-fA-F]{3,4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$"));
  const auto match = hex.match(value.toString().trimmed());
  if (!match.hasMatch()) return {};
  QString digits = match.captured(1);
  if (digits.size() <= 4) {
    QString wide;
    for (const QChar digit : std::as_const(digits)) wide += QString(2, digit);
    digits = wide;
  }
  const auto channel = [&digits](int at) { return digits.mid(at, 2).toInt(nullptr, 16) / 255.0; };
  return {channel(0), channel(2), channel(4), digits.size() == 8 ? channel(6) : 1.0, true};
}

// Overlays are translucent in VS Code and our roles are opaque: over the surface they sit on.
QString flattened(const VsColor& color, const QColor& base) {
  return QColor::fromRgbF(color.r * color.a + base.redF() * (1 - color.a), color.g * color.a + base.greenF() * (1 - color.a),
                          color.b * color.a + base.blueF() * (1 - color.a))
      .name(QColor::HexRgb);
}

// Extension names are often package slugs; read them as words.
QString humanized(const QString& raw) {
  static const QRegularExpression space(QStringLiteral("\\s")), separators(QStringLiteral("[-_.]+"));
  const QString trimmed = raw.trimmed();
  if (trimmed.contains(space) || !trimmed.contains(separators)) return trimmed;
  QStringList words;
  for (const QString& word : trimmed.split(separators, Qt::SkipEmptyParts)) words.append(word.left(1).toUpper() + word.mid(1));
  return words.join(QLatin1Char(' '));
}

// Its workbench colours are dotted paths (`editor.background`), which our own files never use.
bool isVsCodeTheme(const QJsonObject& file) {
  if (file.value(QLatin1String("version")).toInt() == 1) return false;
  if (file.value(QLatin1String("tokenColors")).isArray()) return true;
  const QJsonObject colors = file.value(QLatin1String("colors")).toObject();
  const QStringList keys = colors.keys();
  return std::any_of(keys.cbegin(), keys.cend(), [](const QString& key) { return key.contains(QLatin1Char('.')); });
}

}  // namespace

// A VS Code theme describes editor chrome, not an app palette: a whole palette
// is grown from its editor background and a muted accent (derive), then the
// workbench colours it does set go on top, foregrounds only where they stay
// readable. The result is one of our theme files. Batches are not paired into
// light and dark here.
std::optional<QJsonObject> ThemeController::fromVsCodeTheme(const QJsonObject& file, QString* error) const {
  const QJsonObject colors = file.value(QLatin1String("colors")).toObject();
  const auto pick = [&colors](std::initializer_list<const char*> keys) {
    for (const char* key : keys) {
      if (const VsColor color = vsColor(colors.value(QLatin1String(key))); color.valid) return color;
    }
    return VsColor();
  };
  const VsColor canvasColor = pick({"editor.background", "editorPane.background"});
  if (!canvasColor.valid) {
    *error = tr("That VS Code theme has no \"editor.background\" color, so there is nothing to build a palette from.");
    return std::nullopt;
  }
  const QColor canvas = canvasColor.solid();
  const QString type = file.value(QLatin1String("type")).toString().toLower();
  const QString appearance = type == QLatin1String("light") || type == QLatin1String("hc-light")  ? kLight
                             : type == QLatin1String("dark") || type == QLatin1String("hc-black") ? kDark
                             : luminance(canvas) < 0.179                                          ? kDark
                                                                                                  : kLight;
  const VsColor accentColor = pick({"focusBorder", "button.background", "textLink.foreground", "activityBarBadge.background",
                                    "progressBar.background", "badge.background"});
  const QString canvasHex = canvas.name(QColor::HexRgb);
  // The floor grows from a muted accent, so a neutral theme is not washed in its focus colour.
  VsColor muted = accentColor;
  muted.a = 0.2;
  QJsonObject palette = QJsonObject::fromVariantMap(derive(canvasHex, accentColor.valid ? flattened(muted, canvas) : canvasHex));
  const auto derived = [&palette](const char* role) { return palette.value(QLatin1String(role)).toString(); };
  const auto solidOver = [&pick](const QColor& base, std::initializer_list<const char*> keys) {
    const VsColor color = pick(keys);
    return color.valid ? flattened(color, base) : QString();
  };
  const auto orDerived = [&derived](const QString& value, const char* role) { return value.isEmpty() ? derived(role) : value; };
  const auto readable = [&](const QString& surface, const char* role, std::initializer_list<const char*> keys) {
    const QColor on(surface);
    const auto reads = [&on](const QString& candidate) { return contrast(QColor(candidate), on) >= 4.5; };
    const QString named = solidOver(on, keys);
    if (!named.isEmpty() && reads(named)) return named;
    if (reads(derived(role))) return derived(role);
    return luminance(on) < 0.179 ? QStringLiteral("#ffffff") : QStringLiteral("#000000");
  };
  const auto status = [&](const char* role, std::initializer_list<const char*> keys) {
    const QString named = solidOver(canvas, keys);
    return !named.isEmpty() && contrast(QColor(named), canvas) >= 4.5 ? named : derived(role);
  };
  const QString sidebarHex = orDerived(solidOver(canvas, {"sideBar.background", "activityBar.background"}), "sidebar");
  const QColor sidebar(sidebarHex);
  const QString terminalHex = orDerived(solidOver(canvas, {"terminal.background", "panel.background"}), "terminalBackground");
  const QColor terminal(terminalHex);
  const QList<std::pair<const char*, QString>> overrides{
      {"canvas", canvasHex},
      {"text", readable(canvasHex, "text", {"editor.foreground", "foreground"})},
      {"textMuted", readable(canvasHex, "textMuted", {"descriptionForeground", "disabledForeground"})},
      {"surface", orDerived(solidOver(canvas, {"editorWidget.background"}), "surface")},
      {"surfaceRaised", orDerived(solidOver(canvas, {"editorWidget.background", "dropdown.background"}), "surfaceRaised")},
      {"surfaceOverlay", orDerived(solidOver(canvas, {"menu.background", "quickInput.background", "dropdown.background"}), "surfaceOverlay")},
      {"border", orDerived(solidOver(canvas, {"panel.border", "editorGroup.border", "contrastBorder"}), "border")},
      {"input", orDerived(solidOver(canvas, {"input.border", "dropdown.border"}), "input")},
      {"placeholder", readable(canvasHex, "placeholder", {"input.placeholderForeground"})},
      // The status colours stay the standard ones unless the theme's own read here.
      {"error", status("error", {"editorError.foreground", "errorForeground"})},
      {"warning", status("warning", {"editorWarning.foreground"})},
      {"accentSurface", orDerived(solidOver(canvas, {"list.activeSelectionBackground", "list.hoverBackground"}), "accentSurface")},
      {"codeBackground", orDerived(solidOver(canvas, {"textCodeBlock.background"}), "codeBackground")},
      {"sidebar", sidebarHex},
      {"sidebarForeground", readable(sidebarHex, "sidebarForeground", {"sideBar.foreground"})},
      {"sidebarBorder", orDerived(solidOver(sidebar, {"sideBar.border"}), "sidebarBorder")},
      {"sidebarRowHover", orDerived(solidOver(sidebar, {"list.hoverBackground"}), "sidebarRowHover")},
      {"sidebarRowActive", orDerived(solidOver(sidebar, {"list.inactiveSelectionBackground", "list.hoverBackground"}), "sidebarRowActive")},
      {"sidebarRowSelected", orDerived(solidOver(sidebar, {"list.activeSelectionBackground"}), "sidebarRowSelected")},
      {"terminalBackground", terminalHex},
      {"terminalForeground", readable(terminalHex, "terminalForeground", {"terminal.foreground"})},
      {"terminalCursor", orDerived(solidOver(terminal, {"terminalCursor.foreground", "editorCursor.foreground"}), "terminalCursor")},
      {"terminalSelection", orDerived(solidOver(terminal, {"terminal.selectionBackground", "editor.selectionBackground"}), "terminalSelection")},
      {"terminalScrollbar", orDerived(solidOver(terminal, {"scrollbarSlider.background"}), "terminalScrollbar")},
  };
  for (const auto& [role, value] : overrides) palette.insert(QLatin1String(role), value);
  if (accentColor.valid) {
    const QString accentHex = flattened(accentColor, canvas);
    // The button pair is the closest thing VS Code has to our action colour.
    const QString button = solidOver(canvas, {"button.background"});
    const QString actionHex = button.isEmpty() ? accentHex : button;
    palette.insert(QStringLiteral("accent"), accentHex);
    palette.insert(QStringLiteral("focus"), accentHex);
    palette.insert(QStringLiteral("messageAction"), actionHex);
    palette.insert(QStringLiteral("messageActionForeground"), readable(actionHex, "messageActionForeground", {"button.foreground"}));
    palette.insert(QStringLiteral("accentForeground"), readable(accentHex, "accentForeground", {"button.foreground"}));
  }
  QString name;
  for (const char* key : {"displayName", "name"}) {
    const QJsonValue candidate = file.value(QLatin1String(key));
    if (!candidate.isString() || humanized(candidate.toString()).isEmpty()) continue;
    name = humanized(candidate.toString()).left(48);
    break;
  }
  if (name.isEmpty()) name = QStringLiteral("VS Code theme");
  return QJsonObject{{QStringLiteral("version"), 1}, {QStringLiteral("name"), name}, {QStringLiteral("appearance"), appearance}, {QStringLiteral("colors"), palette}};
}

// A theme file's JSON, or why it cannot be read.
std::optional<QJsonObject> ThemeController::parseFile(const QByteArray& text, QString* error) const {
  const auto refuse = [error](const QString& why) {
    *error = why;
    return std::nullopt;
  };
  QJsonParseError parse;
  const QJsonDocument document = QJsonDocument::fromJson(text, &parse);
  if (parse.error != QJsonParseError::NoError) return refuse(tr("That theme file is invalid."));
  if (!document.isObject()) return refuse(tr("Theme files must contain a JSON object."));
  QJsonObject file = document.object();
  // A VS Code colour theme is converted on the way in.
  if (isVsCodeTheme(file)) {
    const auto converted = fromVsCodeTheme(file, error);
    if (!converted) return std::nullopt;
    file = *converted;
  }
  if (file.value(QLatin1String("version")).toInt() != 1) {
    return refuse(tr("This theme file uses an unsupported version. Expected 1."));
  }
  const QString name = file.value(QLatin1String("name")).toString().trimmed();
  if (name.isEmpty() || name.size() > 48) return refuse(tr("Theme files need a name (48 characters or fewer)."));
  const QString appearance = file.value(QLatin1String("appearance")).toString();
  if (appearance != kLight && appearance != kDark) return refuse(tr("Theme files need an appearance of \"light\" or \"dark\"."));
  if (!file.value(QLatin1String("colors")).isObject()) return refuse(tr("Theme files need a colors object."));
  const QString id = file.contains(QLatin1String("id")) ? file.value(QLatin1String("id")).toString() : idFromName(name);
  static const QRegularExpression valid(QStringLiteral("^[a-z0-9]+(-[a-z0-9]+)*$"));
  if (id.size() > 48 || !valid.match(id).hasMatch()) {
    return refuse(tr("Theme ids may only contain lowercase letters, numbers, and hyphens."));
  }
  if (builtIns().reserved.contains(id)) return refuse(tr("The theme id \"%1\" is reserved.").arg(id));
  for (const QJsonValue& value : builtIns().themes) {
    if (value.toObject().value(QLatin1String("id")).toString() == id) return refuse(tr("The theme id \"%1\" is reserved.").arg(id));
  }
  QJsonObject theme{{QStringLiteral("id"), id},
                    {QStringLiteral("label"), name},
                    {QStringLiteral("appearance"), appearance},
                    {QStringLiteral("colors"), overlay({}, file.value(QLatin1String("colors")).toObject(), builtIns().roles)}};
  QJsonObject variants;
  const QJsonObject rawVariants = file.value(QLatin1String("variants")).toObject();
  for (auto it = rawVariants.begin(); it != rawVariants.end(); ++it) {
    if (it.key() != kLight && it.key() != kDark) return refuse(tr("Theme variants may only be named \"light\" or \"dark\"."));
    if (it.key() == appearance) return refuse(tr("Theme variants must not repeat the base appearance \"%1\".").arg(appearance));
    variants.insert(it.key(), overlay({}, it.value().toObject(), builtIns().roles));
  }
  if (!variants.isEmpty()) theme.insert(QStringLiteral("variants"), variants);
  // The family it was installed with (an extension's themes).
  if (file.contains(QLatin1String("collection"))) {
    static const QRegularExpression collectionId(QStringLiteral("^[A-Za-z0-9][A-Za-z0-9.:-]{0,127}$"));
    const QJsonObject collection = file.value(QLatin1String("collection")).toObject();
    const QString label = collection.value(QLatin1String("label")).toString().trimmed();
    if (!collectionId.match(collection.value(QLatin1String("id")).toString()).hasMatch() || label.isEmpty() || label.size() > 48) {
      return refuse(tr("Theme collections need a valid id and label."));
    }
    theme.insert(QStringLiteral("collection"), QJsonObject{{QStringLiteral("id"), collection.value(QLatin1String("id"))}, {QStringLiteral("label"), label}});
  }
  return theme;
}

bool ThemeController::install(const QJsonArray& themes, const QString& activate) {
  QJsonObject device = m_settings->deviceSettings();
  QJsonArray saved = device.value(kCustomThemes).toArray();
  for (const QJsonValue& value : themes) {
    const QString id = value.toObject().value(QLatin1String("id")).toString();
    bool replaced = false;
    for (qsizetype index = 0; index < saved.size() && !replaced; ++index) {
      if (saved.at(index).toObject().value(QLatin1String("id")).toString() != id) continue;
      saved.replace(index, value);
      replaced = true;
    }
    if (!replaced) saved.append(value);
  }
  device.insert(kCustomThemes, saved);
  if (!activate.isEmpty()) {
    // As choosing it: a theme of one appearance takes that side only.
    const QJsonObject theme = themes.first().toObject();
    if (theme.value(QLatin1String("variants")).toObject().isEmpty()) {
      QJsonObject halves = device.value(QLatin1String("themeHalves")).toObject();
      halves.insert(theme.value(QLatin1String("appearance")).toString(), activate);
      device.insert(QStringLiteral("themeHalves"), halves);
    } else {
      device.insert(QStringLiteral("theme"), activate);
      device.remove(QStringLiteral("themeHalves"));
    }
  }
  return save(device, QStringLiteral("Couldn’t add theme"));
}

void ThemeController::failImport(const QString& error) {
  m_importError = error;
  emit importChanged();
}

void ThemeController::told(const QJsonArray& themes, const QString& verb, const QString& description) {
  auto* toasts = NativeShell::of(this)->controller<ToastController>();
  if (!toasts || themes.isEmpty()) return;
  QStringList labels;
  for (const QJsonValue& value : themes) labels.append(value.toObject().value(QLatin1String("label")).toString());
  toasts->show(QStringLiteral("success"),
               labels.size() == 1 ? QStringLiteral("%1 %2").arg(labels.first(), verb)
                                  : QStringLiteral("%1 themes %2").arg(labels.size()).arg(verb),
               description.isEmpty() ? labels.join(QStringLiteral(", ")) : description);
}

void ThemeController::clearImport() {
  if (m_importError.isEmpty() && m_importConflicts.isEmpty()) return;
  m_importError.clear();
  m_importConflicts = {};
  emit importChanged();
}

bool ThemeController::importText(const QString& json) {
  clearImport();
  const QByteArray text = json.toUtf8();
  // Pasted text gets the file's limit too.
  if (const QString tooBig = oversized(text.size()); !tooBig.isEmpty()) {
    failImport(tooBig);
    return false;
  }
  QString error;
  const auto theme = parseFile(text, &error);
  if (!theme) {
    failImport(error);
    return false;
  }
  const QString id = theme->value(QLatin1String("id")).toString();
  if (installed(id)) {
    m_importConflicts = {*theme};
    emit importChanged();
    return false;
  }
  if (!install({*theme}, id)) {
    failImport(tr("Theme added, but it could not be selected. Try again."));
    return false;
  }
  const bool half = theme->value(QLatin1String("variants")).toObject().isEmpty();
  told({*theme}, QStringLiteral("added"),
       half ? QStringLiteral("It’s now your %1 theme.").arg(theme->value(QLatin1String("appearance")).toString())
            : QStringLiteral("It’s now active."));
  return true;
}

void ThemeController::importFiles(const QStringList& paths) {
  clearImport();
  if (paths.isEmpty()) return;
  const auto read = [](const QString& path, QString* error) -> std::optional<QByteArray> {
    // The size first: a large file is never read at all.
    const QFileInfo info(path);
    if (const QString tooBig = oversized(info.size()); info.exists() && !tooBig.isEmpty()) {
      *error = tooBig;
      return std::nullopt;
    }
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
      *error = tr("Could not read that file. Paste the JSON below instead.");
      return std::nullopt;
    }
    return file.readAll();
  };
  if (paths.size() == 1) {
    QString error;
    const auto text = read(paths.first(), &error);
    if (!text) return failImport(error);
    importText(QString::fromUtf8(*text));
    return;
  }
  // Several at once install without activating.
  QStringList failures;
  QJsonArray fresh;
  QJsonArray conflicting;
  for (const QString& path : paths) {
    const QString name = QFileInfo(path).fileName();
    QString error;
    const auto text = read(path, &error);
    if (!text) {
      failures.append(QStringLiteral("%1: %2").arg(name, error.startsWith(QLatin1String("That file is")) ? tr("too large") : error));
      continue;
    }
    const auto theme = parseFile(*text, &error);
    if (!theme) {
      failures.append(QStringLiteral("%1: %2").arg(name, error));
    } else if (installed(theme->value(QLatin1String("id")).toString())) {
      conflicting.append(*theme);
    } else {
      fresh.append(*theme);
    }
  }
  if (!fresh.isEmpty()) {
    if (install(fresh)) told(fresh, QStringLiteral("added"));
    else failures.append(tr("the themes could not be saved"));
  }
  m_importConflicts = conflicting;
  m_importError = failures.join(QStringLiteral(" — "));
  emit importChanged();
}

void ThemeController::resolveImport(const QString& choice) {
  const QJsonArray conflicts = m_importConflicts;
  clearImport();
  if (conflicts.isEmpty() || choice == QLatin1String("cancel")) return;
  QJsonArray resolved;
  for (const QJsonValue& value : conflicts) {
    QJsonObject theme = value.toObject();
    if (choice == QLatin1String("copy")) {
      // The next free "<name> (2)".
      const QString label = theme.value(QLatin1String("label")).toString();
      for (int copy = 2; copy < 100; ++copy) {
        const QString suffix = QStringLiteral(" (%1)").arg(copy);
        const QString name = label.left(48 - suffix.size()) + suffix;
        const QString id = idFromName(name);
        if (installed(id) || find(id)) continue;
        theme.insert(QStringLiteral("id"), id);
        theme.insert(QStringLiteral("label"), name);
        break;
      }
    }
    resolved.append(theme);
  }
  if (!install(resolved)) return failImport(tr("The themes could not be saved."));
  told(resolved, choice == QLatin1String("copy") ? QStringLiteral("added") : QStringLiteral("updated"));
}

bool ThemeController::exportTheme(const QString& id, const QString& path) {
  auto* toasts = NativeShell::of(this)->controller<ToastController>();
  const auto definition = find(id);
  if (!definition) return false;
  // The theme file, version 1.
  QJsonObject file{{QStringLiteral("version"), 1},
                   {QStringLiteral("id"), definition->id},
                   {QStringLiteral("name"), definition->label},
                   {QStringLiteral("appearance"), definition->appearance},
                   {QStringLiteral("colors"), definition->colors}};
  if (!definition->variants.isEmpty()) file.insert(QStringLiteral("variants"), definition->variants);
  for (const QJsonValue& value : m_settings->deviceSettings().value(kCustomThemes).toArray()) {
    const QJsonObject saved = value.toObject();
    if (saved.value(QLatin1String("id")).toString() == id && saved.contains(QLatin1String("collection"))) {
      file.insert(QStringLiteral("collection"), saved.value(QLatin1String("collection")));
    }
  }
  QSaveFile out(path);
  if (!out.open(QIODevice::WriteOnly) || out.write(QJsonDocument(file).toJson()) < 0 || !out.commit()) {
    if (toasts) toasts->error(tr("Couldn’t export theme"), out.errorString());
    return false;
  }
  if (toasts) toasts->show(QStringLiteral("success"), tr("%1 exported").arg(definition->label), path);
  return true;
}
