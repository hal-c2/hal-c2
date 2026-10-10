#pragma once

#include <QColor>
#include <QFileSystemWatcher>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QTimer>
#include <QVariantMap>

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

  // Resolved colour for a role (`canvas`, `text`, ...): theme.json first, then
  // the base theme, then `fallback`.
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
};
