#pragma once

#include <QColor>
#include <cmath>
#include <QFileSystemWatcher>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QTimer>
#include <QVariantMap>

// One step of the type ramp (`Theme.type.body`): pixel size and line height,
// already scaled by the interface size, and a weight for `font.weight`.
class ThemeTypeStep : public QObject {
  Q_OBJECT
  Q_PROPERTY(int size READ size NOTIFY changed)
  Q_PROPERTY(int lineHeight READ lineHeight NOTIFY changed)
  Q_PROPERTY(int weight READ weight NOTIFY changed)

public:
  using QObject::QObject;
  int size() const { return m_size; }
  int lineHeight() const { return m_lineHeight; }
  int weight() const { return m_weight; }
  void set(int size, int lineHeight, int weight);

signals:
  void changed();

private:
  int m_size = 13;
  int m_lineHeight = 18;
  int m_weight = 400;
};

// The six text sizes, and nothing between them: caption (badges, counts,
// keys), meta (secondary lines, times), body (controls, rows, menus), prose
// (messages), title (dialog and section titles) and display (page titles).
class ThemeTypeRamp : public QObject {
  Q_OBJECT
  Q_PROPERTY(ThemeTypeStep* caption READ caption CONSTANT)
  Q_PROPERTY(ThemeTypeStep* meta READ meta CONSTANT)
  Q_PROPERTY(ThemeTypeStep* body READ body CONSTANT)
  Q_PROPERTY(ThemeTypeStep* prose READ prose CONSTANT)
  Q_PROPERTY(ThemeTypeStep* title READ title CONSTANT)
  Q_PROPERTY(ThemeTypeStep* display READ display CONSTANT)

public:
  using QObject::QObject;
  ThemeTypeStep* caption() { return &m_caption; }
  ThemeTypeStep* meta() { return &m_meta; }
  ThemeTypeStep* body() { return &m_body; }
  ThemeTypeStep* prose() { return &m_prose; }
  ThemeTypeStep* title() { return &m_title; }
  ThemeTypeStep* display() { return &m_display; }
  // Scales the ramp; a monospace interface gets more leading and a smaller display.
  void apply(qreal scale, bool monospace);

private:
  ThemeTypeStep m_caption, m_meta, m_body, m_prose, m_title, m_display;
};

// The spacing scale (`Theme.space.md`): 2 4 8 12 16 24 32, nothing between.
class ThemeSpace : public QObject {
  Q_OBJECT
  Q_PROPERTY(int xxs MEMBER m_xxs CONSTANT)
  Q_PROPERTY(int xs MEMBER m_xs CONSTANT)
  Q_PROPERTY(int sm MEMBER m_sm CONSTANT)
  Q_PROPERTY(int md MEMBER m_md CONSTANT)
  Q_PROPERTY(int lg MEMBER m_lg CONSTANT)
  Q_PROPERTY(int xl MEMBER m_xl CONSTANT)
  Q_PROPERTY(int xxl MEMBER m_xxl CONSTANT)

public:
  using QObject::QObject;

private:
  int m_xxs = 2, m_xs = 4, m_sm = 8, m_md = 12, m_lg = 16, m_xl = 24, m_xxl = 32;
};

// Control heights (`Theme.control.md`, the default; a text field is md) and
// icon sizes (`Theme.icon.md`), with the stroke each size draws at.
class ThemeSizes : public QObject {
  Q_OBJECT
  Q_PROPERTY(int sm MEMBER m_sm CONSTANT)
  Q_PROPERTY(int md MEMBER m_md CONSTANT)
  Q_PROPERTY(int lg MEMBER m_lg CONSTANT)
  Q_PROPERTY(int xl MEMBER m_xl CONSTANT)

public:
  ThemeSizes(int sm, int md, int lg, int xl, QObject* parent = nullptr)
      : QObject(parent), m_sm(sm), m_md(md), m_lg(lg), m_xl(xl) {}
  // The lucide stroke (in its 24-unit box) for an icon `size` pixels wide:
  // small icons draw heavier so every size reads at about the same weight.
  Q_INVOKABLE qreal stroke(qreal size) const { return size <= 12 ? 2.0 : size <= 16 ? 1.75 : 1.5; }

private:
  int m_sm, m_md, m_lg, m_xl;
};

// The shell's palette for QML (the `Theme` singleton): the theme
// ThemeController resolves (the base), with `<configDir>/theme.json`, watched,
// on top. The file is the theme file format (`{version, id, name,
// appearance, colors, variants}`, role names such as `canvas`, `chrome`,
// `text`, `sidebar`) plus a shell-only `window` section.
class ThemeStore : public QObject {
  Q_OBJECT
  Q_PROPERTY(bool loaded READ loaded NOTIFY themeChanged)
  Q_PROPERTY(QString path READ path CONSTANT)
  Q_PROPERTY(QString id READ id NOTIFY themeChanged)
  Q_PROPERTY(QString name READ name NOTIFY themeChanged)
  Q_PROPERTY(QString appearance READ appearance NOTIFY themeChanged)
  // Whether the file leaves light or dark to the app's choice
  // (`window.followSystemAppearance`); it keeps its own `appearance` otherwise.
  Q_PROPERTY(bool followsSystemAppearance READ followsSystemAppearance NOTIFY themeChanged)
  Q_PROPERTY(QVariantMap colors READ colors NOTIFY themeChanged)
  // Reading this notified receiver makes palette.color(...) reactive in QML.
  // A direct call to a C++ invokable does not record a binding dependency.
  Q_PROPERTY(ThemeStore* palette READ palette NOTIFY themeChanged)
  // What a link in prose reads in: the info foreground.
  Q_PROPERTY(QColor link READ link NOTIFY themeChanged)
  Q_PROPERTY(qreal radius READ radius NOTIFY themeChanged)
  // The radius scale from `radius` (R): xs R/2, sm 3R/4, md R, lg 3R/2, xl 2R.
  // Popovers and dialogs are lg; a radius nested in padding p is the outer one less p.
  Q_PROPERTY(qreal radiusXs READ radiusXs NOTIFY themeChanged)
  Q_PROPERTY(qreal radiusSm READ radiusSm NOTIFY themeChanged)
  Q_PROPERTY(qreal radiusMd READ radius NOTIFY themeChanged)
  Q_PROPERTY(qreal radiusLg READ radiusLg NOTIFY themeChanged)
  Q_PROPERTY(qreal radiusXl READ radiusXl NOTIFY themeChanged)
  // Fully round: a Rectangle clamps its radius to half its shorter side.
  Q_PROPERTY(qreal radiusPill READ radiusPill CONSTANT)
  Q_PROPERTY(ThemeTypeRamp* type READ type CONSTANT)
  Q_PROPERTY(ThemeSpace* space READ space CONSTANT)
  Q_PROPERTY(ThemeSizes* control READ control CONSTANT)
  Q_PROPERTY(ThemeSizes* icon READ icon CONSTANT)
  // Whether the interface font is monospaced, where weight barely separates
  // and hierarchy is size and ink.
  Q_PROPERTY(bool monospace READ monospace NOTIFY themeChanged)
  Q_PROPERTY(QString fontUi READ fontUi NOTIFY themeChanged)
  Q_PROPERTY(QString fontMono READ fontMono NOTIFY themeChanged)
  // The composer's and the terminal's families (the interface's and the code
  // font's unless the user named one), and the sizes: `fontScale` multiplies
  // every interface size (the interface size over its default of 16), the
  // others are pixel sizes.
  Q_PROPERTY(QString fontPrompt READ fontPrompt NOTIFY themeChanged)
  Q_PROPERTY(QString fontTerminal READ fontTerminal NOTIFY themeChanged)
  Q_PROPERTY(qreal fontScale READ fontScale NOTIFY themeChanged)
  Q_PROPERTY(int fontSizePrompt READ fontSizePrompt NOTIFY themeChanged)
  Q_PROPERTY(int fontSizeCode READ fontSizeCode NOTIFY themeChanged)
  Q_PROPERTY(int fontSizeTerminal READ fontSizeTerminal NOTIFY themeChanged)
  Q_PROPERTY(bool baseLoaded READ baseLoaded NOTIFY themeChanged)
  Q_PROPERTY(qreal windowOpacity READ windowOpacity NOTIFY themeChanged)
  Q_PROPERTY(bool windowTransparent READ windowTransparent NOTIFY themeChanged)
  Q_PROPERTY(bool windowBlur READ windowBlur NOTIFY themeChanged)
  Q_PROPERTY(bool windowLiquidGlass READ windowLiquidGlass NOTIFY themeChanged)
  Q_PROPERTY(bool frameless READ frameless NOTIFY themeChanged)
  Q_PROPERTY(QString lastError READ lastError NOTIFY themeChanged)

public:
  explicit ThemeStore(const QString& configDir, QObject* parent = nullptr);
  ~ThemeStore() override;

  bool loaded() const { return m_loaded; }
  QString path() const { return m_path; }
  QString id() const { return m_id; }
  QString name() const { return m_name; }
  QString appearance() const { return m_loaded ? m_appearance : m_baseAppearance; }
  QVariantMap colors() const { return m_colors; }
  ThemeStore* palette() { return this; }
  QColor link() const;
  qreal radius() const;
  qreal radiusXs() const { return std::round(radius() * 0.5); }
  qreal radiusSm() const { return std::round(radius() * 0.75); }
  qreal radiusLg() const { return std::round(radius() * 1.5); }
  qreal radiusXl() const { return std::round(radius() * 2); }
  qreal radiusPill() const { return 9999; }
  ThemeTypeRamp* type() { return &m_type; }
  ThemeSpace* space() { return &m_space; }
  ThemeSizes* control() { return &m_control; }
  ThemeSizes* icon() { return &m_icon; }
  bool monospace() const { return m_monospace; }
  QString fontUi() const;
  QString fontMono() const;
  QString fontPrompt() const;
  QString fontTerminal() const;
  qreal fontScale() const { return fontSize("interface", 16) / 16.0; }
  int fontSizePrompt() const { return fontSize("prompt", 14); }
  int fontSizeCode() const { return fontSize("code", 13); }
  int fontSizeTerminal() const { return fontSize("terminal", 12); }
  bool baseLoaded() const { return !m_baseTheme.isEmpty(); }
  qreal windowOpacity() const { return m_windowOpacity; }
  bool windowTransparent() const { return m_windowTransparent; }
  bool windowBlur() const { return m_windowBlur; }
  bool windowLiquidGlass() const { return m_windowLiquidGlass; }
  bool followsSystemAppearance() const { return m_followsSystemAppearance; }
  bool frameless() const { return m_frameless; }
  QString lastError() const { return m_lastError; }

  // Resolved colour for a role (`canvas`, `ink`, ...): theme.json first, then
  // the base theme, then `fallback`. In each, a role it lacks is read from the
  // older role it renames (`ink` is `text`) or derived from the ones it has
  // (`inkSecondary` between `ink` and `inkTertiary`), so themes written before
  // a role existed still draw it in their own colours.
  Q_INVOKABLE QColor color(const QString& role, const QColor& fallback) const;
  Q_INVOKABLE void reload();

public slots:
  // The resolved theme ThemeController publishes as `theme` (ShellThemeState).
  void applyBaseTheme(const QVariant& theme);

signals:
  void themeChanged();

private:
  void watch();
  void scheduleReload();
  void applyDefaults();
  void resolveColors();
  // Makes fontUi() the application's font, so text that names no family is
  // written in it without binding to the theme: a label made later starts in
  // it, and the ones already drawn are rewritten once, when the family changes.
  void applyInterfaceFont();
  int fontSize(const char* part, int fallback) const;
  // Rescales the type ramp after the fonts or sizes changed.
  void applyType();

  QString m_configDir;
  QString m_path;
  QFileSystemWatcher m_watcher;
  QTimer m_debounce;
  QByteArray m_lastContent;

  bool m_loaded = false;
  QString m_id;
  QString m_name;
  QString m_appearance;
  QJsonObject m_fileColors;
  QJsonObject m_variants;
  bool m_followsSystemAppearance = false;
  QVariantMap m_colors;
  QString m_radius;
  QString m_fontUi;
  QString m_fontMono;
  // The family applyInterfaceFont() last gave the application; empty is the system's.
  QString m_interfaceFont;
  QVariantMap m_baseTheme;
  QVariantMap m_baseColors;
  QString m_baseAppearance;
  qreal m_baseRadius = 8;
  QString m_baseFontUi;
  QString m_baseFontMono;
  qreal m_windowOpacity = 1.0;
  bool m_windowTransparent = false;
  bool m_windowBlur = false;
  bool m_windowLiquidGlass = false;
  bool m_frameless = true;
  QString m_lastError;
  bool m_monospace = false;
  ThemeTypeRamp m_type;
  ThemeSpace m_space;
  // xl is a tab strip.
  ThemeSizes m_control{24, 28, 32, 36};
  ThemeSizes m_icon{12, 16, 20, 24};
};
