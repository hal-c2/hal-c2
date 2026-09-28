#pragma once

#include <QColor>
#include <QFileSystemWatcher>
#include <QJsonObject>
#include <QObject>
#include <QString>
#include <QTimer>
#include <QVariantMap>

// The shell's palette for QML (the `Theme` singleton) and the web view: the
// theme ThemeController resolves (the base), with `<configDir>/theme.json`,
// watched, on top. The file is the web app's own
// ThemeFile format (`{version, id, name, appearance, colors, variants}`, role
// names such as `canvas`, `chrome`, `text`, `sidebar`) plus a shell-only
// `window` section, so one file themes both halves and the web's Theme Editor
// can author it.
class ThemeStore : public QObject {
  Q_OBJECT
  Q_PROPERTY(bool loaded READ loaded NOTIFY themeChanged)
  Q_PROPERTY(QString path READ path CONSTANT)
  Q_PROPERTY(QString id READ id NOTIFY themeChanged)
  Q_PROPERTY(QString name READ name NOTIFY themeChanged)
  Q_PROPERTY(QString appearance READ appearance NOTIFY themeChanged)
  Q_PROPERTY(QVariantMap colors READ colors NOTIFY themeChanged)
  // Reading this notified receiver makes palette.color(...) reactive in QML.
  // A direct call to a C++ invokable does not record a binding dependency.
  Q_PROPERTY(QObject* palette READ palette NOTIFY themeChanged)
  Q_PROPERTY(qreal radius READ radius NOTIFY themeChanged)
  Q_PROPERTY(QString fontUi READ fontUi NOTIFY themeChanged)
  Q_PROPERTY(QString fontMono READ fontMono NOTIFY themeChanged)
  Q_PROPERTY(bool baseLoaded READ baseLoaded NOTIFY themeChanged)
  Q_PROPERTY(qreal windowOpacity READ windowOpacity NOTIFY themeChanged)
  Q_PROPERTY(bool windowTransparent READ windowTransparent NOTIFY themeChanged)
  Q_PROPERTY(bool windowBlur READ windowBlur NOTIFY themeChanged)
  Q_PROPERTY(bool windowLiquidGlass READ windowLiquidGlass NOTIFY themeChanged)
  Q_PROPERTY(bool frameless READ frameless NOTIFY themeChanged)
  Q_PROPERTY(QString injectionScript READ injectionScript NOTIFY themeChanged)
  Q_PROPERTY(QString lastError READ lastError NOTIFY themeChanged)

public:
  explicit ThemeStore(const QString& configDir, QObject* parent = nullptr);

  bool loaded() const { return m_loaded; }
  QString path() const { return m_path; }
  QString id() const { return m_id; }
  QString name() const { return m_name; }
  QString appearance() const { return m_loaded ? m_appearance : m_baseAppearance; }
  QVariantMap colors() const { return m_colors; }
  QObject* palette() { return this; }
  qreal radius() const;
  QString fontUi() const;
  QString fontMono() const;
  bool baseLoaded() const { return !m_baseTheme.isEmpty(); }
  qreal windowOpacity() const { return m_windowOpacity; }
  bool windowTransparent() const { return m_windowTransparent; }
  bool windowBlur() const { return m_windowBlur; }
  bool windowLiquidGlass() const { return m_windowLiquidGlass; }
  bool followsSystemAppearance() const { return m_followsSystemAppearance; }
  bool frameless() const { return m_frameless; }
  QString injectionScript() const;
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
