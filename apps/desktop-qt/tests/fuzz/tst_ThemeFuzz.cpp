// What a user hands the theme importer (ThemeController): theme files of our
// own, and VS Code colour themes converted on the way in (workbench colours
// in `#RGB`, `#RGBA`, `#RRGGBB` and `#RRGGBBAA`, `tokenColors`, `type`), then
// any CSS colour a theme holds. Whatever the bytes, the importer must not
// crash, and a theme it accepts has a valid id, a name and an appearance, and
// colours the app can draw.

#include "Fuzz.h"
#include "Reach.h"

#include <QDir>
#include <QRegularExpression>
#include <QTemporaryDir>

#include <memory>
#include <string>
#include <tuple>
#include <vector>

#include "NativeShell.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ThemeController.h"

namespace halc2::fuzz {
struct ThemeParseFile {
  using type = std::optional<QJsonObject> (ThemeController::*)(const QByteArray&, QString*) const;
  friend type reach(ThemeParseFile);
};
template struct Reach<ThemeParseFile, &ThemeController::parseFile>;
}  // namespace halc2::fuzz

using namespace halc2;

namespace {

// The importer on this device, made once: parseFile reads no settings, but the
// controller is built by its shell (ThemeController.cpp).
ThemeController* themes() {
  static ThemeController* controller = [] {
    static QTemporaryDir* home = new QTemporaryDir(QDir::tempPath() + QStringLiteral("/hal-c2-fuzz-theme-XXXXXX"));
    auto* bridge = new ShellBridge;
    auto* native = new NativeShell(bridge);  // outlive the application object, as the process does
    native->controller<SettingsController>()->setDevicePath(home->filePath(QStringLiteral("preferences.json")));
    return native->controller<ThemeController>();
  }();
  return controller;
}

const std::vector<std::string> kKeys{
    "version", "id", "name", "displayName", "appearance", "type", "colors", "variants", "collection", "label",
    "tokenColors", "semanticTokenColors", "settings", "scope", "foreground", "background", "light", "dark",
    "editor.background", "editorPane.background", "editor.foreground", "foreground", "focusBorder", "button.background",
    "button.foreground", "textLink.foreground", "activityBarBadge.background", "progressBar.background",
    "badge.background", "descriptionForeground", "disabledForeground", "editorWidget.background", "dropdown.background",
    "dropdown.border", "menu.background", "quickInput.background", "panel.border", "editorGroup.border", "contrastBorder",
    "input.border", "input.placeholderForeground", "editorError.foreground", "errorForeground", "editorWarning.foreground",
    "list.activeSelectionBackground", "list.hoverBackground", "list.inactiveSelectionBackground", "textCodeBlock.background",
    "sideBar.background", "sideBar.foreground", "sideBar.border", "activityBar.background", "terminal.background",
    "panel.background", "terminal.foreground", "terminalCursor.foreground", "editorCursor.foreground",
    "terminal.selectionBackground", "editor.selectionBackground", "scrollbarSlider.background",
    "canvas", "text", "textMuted", "accent", "surface", "border", "sidebar", "terminalBackground", "error", "warning"};
const std::vector<std::string> kTexts{
    "#000", "#fff", "#FFF", "#0008", "#abcd", "#000000", "#ffffff", "#1e1e1e", "#FFFFFF", "#1e1e1e80", "#123456ff", "1e1e1e",
    "#12345", "#GGGGGG", "oklch(0.2 0.02 250)", "oklch(98% 0 none)", "oklch(1 0 0 / 50%)", "oklch(nan 0 0)", "oklch(inf inf inf)",
    "oklch(1e999 0 0)", "oklch(0 0 0 / -1)", "rebeccapurple", "red", "transparent", "dark", "light", "hc-black", "hc-light",
    "vs", "vs-dark", "my-theme", "My Theme", "my_theme.v2", "hal-c2", "custom-theme", "-", "default", "nan", "inf"};

// A VS Code theme as the marketplace ships it, and one of our own files.
const char* const kVsCode =
    R"j({"name":"my-theme","type":"dark","colors":{"editor.background":"#1e1e1e","editor.foreground":"#d4d4d4","focusBorder":"#007fd4",
        "button.background":"#0e639c","button.foreground":"#ffffff","sideBar.background":"#252526","sideBar.foreground":"#cccccc",
        "panel.border":"#80808059","list.hoverBackground":"#2a2d2e","list.activeSelectionBackground":"#094771",
        "terminal.background":"#1e1e1e","terminalCursor.foreground":"#aeafad","editorError.foreground":"#f14c4c",
        "editorWarning.foreground":"#cca700","input.placeholderForeground":"#a6a6a6","descriptionForeground":"#ccccccb3",
        "editorWidget.background":"#252526","menu.background":"#252526","scrollbarSlider.background":"#79797966"},
      "tokenColors":[{"scope":["comment"],"settings":{"foreground":"#6A9955"}}]})j";
const char* const kVsCodeShort =
    R"j({"name":"short","type":"light","colors":{"editor.background":"#fff","foreground":"#333","focusBorder":"#08f8","badge.background":"#0008"}})j";
const char* const kOwn =
    R"j({"version":1,"name":"Mine","appearance":"dark","id":"mine","colors":{"canvas":"#101010","text":"#eeeeee","accent":"oklch(0.7 0.15 250)"},
      "variants":{"light":{"canvas":"#ffffff"}},"collection":{"id":"pack.a:1","label":"Pack"}})j";

void FileParses(const std::string& bytes) {
  QString error;
  const QByteArray text = fuzz::bytes(bytes);
  const auto theme = (themes()->*reach(fuzz::ThemeParseFile{}))(text, &error);
  if (!theme) {
    // A refusal says why.
    ASSERT_FALSE(error.isEmpty()) << bytes;
    return;
  }
  static const QRegularExpression valid(QStringLiteral("^[a-z0-9]+(-[a-z0-9]+)*$"));
  const QString id = theme->value(QLatin1String("id")).toString();
  ASSERT_TRUE(id.size() <= 48 && valid.match(id).hasMatch()) << id.toStdString();
  const QString label = theme->value(QLatin1String("label")).toString();
  ASSERT_TRUE(!label.isEmpty() && label.size() <= 48) << label.toStdString();
  const QString appearance = theme->value(QLatin1String("appearance")).toString();
  ASSERT_TRUE(appearance == QLatin1String("light") || appearance == QLatin1String("dark")) << appearance.toStdString();
  // Every colour it keeps is one the app draws, in the form it keeps them.
  static const QRegularExpression drawable(QStringLiteral("^#[0-9a-f]{6}([0-9a-f]{2})?$"));
  const auto drawn = [](const QJsonObject& colors) {
    for (auto it = colors.begin(); it != colors.end(); ++it) {
      ASSERT_TRUE(it.value().isString() && drawable.match(it.value().toString()).hasMatch())
          << it.key().toStdString() << ": " << it.value().toString().toStdString();
    }
  };
  drawn(theme->value(QLatin1String("colors")).toObject());
  const QJsonObject variants = theme->value(QLatin1String("variants")).toObject();
  for (auto it = variants.begin(); it != variants.end(); ++it) {
    ASSERT_NE(it.key(), appearance);
    drawn(it.value().toObject());
  }
}
FUZZ_TEST(ThemeController, FileParses)
    .WithDomains(fuzz::Text({"{", "}", "\"colors\"", "\"tokenColors\"", "\"editor.background\"", "\"version\":1", "\"name\"",
                             "\"appearance\"", "\"dark\"", "\"id\"", "\"type\"", "#", "oklch(", "e999", "[", "]", ":", ",", "\""}))
    .WithSeeds({{kVsCode}, {kVsCodeShort}, {kOwn}, {R"j({"colors":{"a.b":"#000"}})j"}, {R"j({"tokenColors":[]})j"}});

// The same through JSON the engine cannot break syntactically: the shape of a
// VS Code theme or ours, with its colours and words mutated.
void ShapesParse(const fuzz::JsonSteps& steps) {
  QJsonObject file = fuzz::object(steps);
  fuzz::print(file);
  FileParses(QJsonDocument(file).toJson(QJsonDocument::Compact).toStdString());
}
FUZZ_TEST(ThemeController, ShapesParse)
    .WithDomains(fuzz::Json(kKeys, kTexts, 192))
    .WithSeeds([] {
      return std::vector<std::tuple<fuzz::JsonSteps>>{{fuzz::steps(kVsCode)}, {fuzz::steps(kVsCodeShort)}, {fuzz::steps(kOwn)}};
    });

// Any CSS colour string: it is drawable or it is refused, and what it gives
// is its own canonical form.
void ColorsCanonicalise(const std::string& css) {
  const QString color = ThemeController::canonicalColor(fuzz::utf16(css));
  const QString utf = ThemeController::canonicalColor(fuzz::utf8(css));
  for (const QString& canonical : {color, utf}) {
    if (canonical.isEmpty()) continue;
    static const QRegularExpression drawable(QStringLiteral("^#[0-9a-f]{6}([0-9a-f]{2})?$"));
    ASSERT_TRUE(drawable.match(canonical).hasMatch()) << canonical.toStdString();
    ASSERT_EQ(ThemeController::canonicalColor(canonical), canonical);
  }
}
FUZZ_TEST(ThemeController, ColorsCanonicalise)
    .WithDomains(fuzz::Text({"#", "oklch(", ")", "%", "deg", "none", "/", ",", " ", "nan", "inf", "-inf", "1e999", "-1e999", "0.5", "180",
                             "rgb", "red", "transparent", "rebeccapurple", "abc", "ABCDEF"}))
    .WithSeeds({{"#ABC"}, {"#11223344"}, {"oklch(1 0 0)"}, {"oklch(0.5 0.2 270 / 50%)"}, {"oklch(nan nan nan)"}, {"oklch(1e999 0 0)"}, {"Red"}});

}  // namespace
