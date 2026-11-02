#pragma once

#include <QImage>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QPointF>
#include <QSize>
#include <QUrl>
#include <QVariant>

#include <functional>

// One browser page an agent may drive (PreviewAutomationHost): a preview tab's
// web view as the browser brick shows it. The host only talks to this, so it
// never links the web engine; QuickWebPage is the WebEngineView behind it, and
// tests stand in pages of their own.
class PreviewAutomationPage : public QObject {
  Q_OBJECT

public:
  // The worlds a script runs in: the page's own, where its scripts see what the
  // agent's do, or one apart from them that shares only the DOM.
  enum World { PageWorld = 0, IsolatedWorld = 1 };
  // A script's completion value, invalid when the page went away first.
  using ScriptDone = std::function<void(const QVariant& result)>;
  // A null image when the page has nothing to show yet.
  using ImageDone = std::function<void(const QImage& image)>;

  using QObject::QObject;

  virtual void runJavaScript(const QString& script, World world, ScriptDone done) = 0;
  virtual void grab(ImageDone done) = 0;
  virtual QUrl url() const = 0;
  virtual QString title() const = 0;
  virtual bool loading() const = 0;
  virtual void load(const QUrl& url) = 0;
  // Whether the user has the page's developer tools open: an agent keeps off it.
  virtual bool devToolsOpen() const = 0;
  // Whether the page is on screen, where it takes real input.
  virtual bool onScreen() const = 0;
  // The page's size in CSS pixels.
  virtual QSize viewport() const = 0;
  // A fixed size in CSS pixels, or the space it is given (an empty size).
  virtual void setViewport(const QSize& size) = 0;
  // Real input at a point of the page in CSS pixels, as the user's mouse would
  // give it; false when the page cannot take any (off screen).
  virtual bool click(const QPointF& point) = 0;
  virtual bool key(int key, Qt::KeyboardModifiers modifiers, const QString& text) = 0;
  // system, light or dark: what the page's prefers-color-scheme says.
  virtual void setColorScheme(const QString& scheme) = 0;

  // The newest console messages, at most kConsoleEntries ({level, text, timestamp, source?}).
  QJsonArray consoleEntries() const;
  void addConsoleEntry(const QString& level, const QString& text, const QString& source);
  // A load that failed, as a network entry ({url, method, status, failed, errorText}).
  void addFailedLoad(const QUrl& url, const QString& error);
  QJsonArray failedLoads() const { return m_failedLoads; }

  static constexpr int kConsoleEntries = 200;

signals:
  void loadingChanged();
  void urlChanged();
  void viewportChanged();
  void devToolsChanged();
  // The user's own mouse or keys inside the page; never the agent's, nor
  // events the page's scripts make.
  void humanInput();

private:
  QJsonArray m_console;
  QJsonArray m_failedLoads;
};
