#pragma once

#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QQuickItem>
#include <QStringList>
#include <QVariant>

#include <functional>

#include "ThreadPreviews.h"

class BrowserPage;

// The in-app browser, as the `Browser` QML singleton: whether this build has
// it (QtWebEngine, found at build time like the terminal's module; main.cpp
// says so), the profile its pages share (persistent under the desktop's data
// directory; none in tests, whose pages use the engine's off-the-record
// default), and how DevTools dock (remembered on this device).
//
// It also finds a thread's pages: every BrowserPage registers under its MC
// tab id while it exists, for what drives pages from C++ (the preview
// automation host): Browser::page(tabId).
class Browser : public QObject {
  Q_OBJECT
  Q_PROPERTY(bool supported READ supported CONSTANT)
  Q_PROPERTY(QObject* profile READ profile CONSTANT)
  // "bottom" or "right", and the share of the page DevTools take (0.2-0.8).
  Q_PROPERTY(QString devToolsDock READ devToolsDock WRITE setDevToolsDock NOTIFY devToolsChanged)
  Q_PROPERTY(qreal devToolsShare READ devToolsShare WRITE setDevToolsShare NOTIFY devToolsChanged)

public:
  static Browser* instance();

  static void setSupported(bool supported);
  static bool supported();
  // The profile pages use (a QQuickWebEngineProfile); made by main.cpp.
  static void setProfile(QObject* profile);
  QObject* profile() const;

  QString devToolsDock() const { return m_dock; }
  qreal devToolsShare() const { return m_share; }
  void setDevToolsDock(const QString& dock);
  void setDevToolsShare(qreal share);
  // Where the DevTools layout is kept: read now, written on each change.
  void setStore(std::function<QVariant(const QString&)> read, std::function<void(const QString&, const QVariant&)> write);

  // The page showing MC tab `tabId`, or null while none does.
  static BrowserPage* page(const QString& tabId);
  static QList<BrowserPage*> pages();

signals:
  void devToolsChanged();
  // A page came or went.
  void pagesChanged();

private:
  friend class BrowserPage;
  explicit Browser(QObject* parent = nullptr) : QObject(parent) {}
  void enrol(BrowserPage* page, const QString& tabId);
  void leave(BrowserPage* page, const QString& tabId);

  QString m_dock = QStringLiteral("bottom");
  qreal m_share = 0.4;
  std::function<void(const QString&, const QVariant&)> m_write;
  QHash<QString, QPointer<BrowserPage>> m_pages;
};

// One browser tab's page, made by its brick (BrowserPanel) beside the
// WebEngineView that draws it: the C++ half of the tab. It follows the MC's
// tab (ThreadPreviews) and tells the MC what the page does.
//
// What the view did comes in through report(); the MC hears it as
// `preview.reportStatus`. The MC's tab moving to an address the page did not
// report (an agent's `preview.navigate`, another window) asks the view to load
// it (loadRequested). The device size is the MC's (`viewport`): setViewport
// shows the new size at once and sends `preview.resize`; refused or timed
// out, the size the MC has comes back unless a newer one was picked since.
// Zoom, appearance, mute and DevTools are the page's own, not the MC's.
//
// For drivers in C++: `view` is the WebEngineView (a QQuickItem; call its
// slots through the meta-object), evaluate() runs script in the page and
// grab() takes its picture, both answered by the brick.
class BrowserPage : public QObject {
  Q_OBJECT
  Q_PROPERTY(ThreadPreviews* previews READ previews WRITE setPreviews NOTIFY previewsChanged)
  Q_PROPERTY(QString tabId READ tabId WRITE setTabId NOTIFY tabIdChanged)
  // The MC's address, title and status (idle, loading, loaded, failed) for the tab.
  Q_PROPERTY(QString url READ url NOTIFY tabChanged)
  Q_PROPERTY(QString title READ title NOTIFY tabChanged)
  Q_PROPERTY(QString status READ status NOTIFY tabChanged)
  Q_PROPERTY(bool exists READ exists NOTIFY tabChanged)
  // {_tag: "fill"} or {_tag: "preset"|"freeform", width, height, presetId?}.
  Q_PROPERTY(QVariantMap viewport READ viewport NOTIFY viewportChanged)
  Q_PROPERTY(qreal zoom READ zoom WRITE setZoom NOTIFY zoomChanged)
  // system, light or dark: the page's prefers-color-scheme.
  Q_PROPERTY(QString appearance READ appearance WRITE setAppearance NOTIFY appearanceChanged)
  Q_PROPERTY(bool muted READ muted WRITE setMuted NOTIFY mutedChanged)
  Q_PROPERTY(bool devTools READ devTools WRITE setDevTools NOTIFY devToolsChanged)
  // The WebEngineView showing the page, set by the brick.
  Q_PROPERTY(QQuickItem* view READ view WRITE setView NOTIFY viewChanged)

public:
  explicit BrowserPage(QObject* parent = nullptr);
  ~BrowserPage() override;

  ThreadPreviews* previews() const { return m_previews; }
  void setPreviews(ThreadPreviews* previews);
  QString tabId() const { return m_tabId; }
  void setTabId(const QString& tabId);

  QString url() const;
  QString title() const;
  QString status() const;
  bool exists() const { return !m_tab.isEmpty(); }
  QVariantMap viewport() const;
  qreal zoom() const { return m_zoom; }
  void setZoom(qreal zoom);
  QString appearance() const { return m_appearance; }
  void setAppearance(const QString& appearance);
  bool muted() const { return m_muted; }
  void setMuted(bool muted);
  bool devTools() const { return m_devTools; }
  void setDevTools(bool open);
  QQuickItem* view() const { return m_view; }
  void setView(QQuickItem* view);

  // What the view did: phase "loading", "loaded" or "failed" (with Chromium's
  // net error `code` and its `description`).
  Q_INVOKABLE void report(const QString& phase, const QString& url, const QString& title, int code, const QString& description,
                          bool canGoBack, bool canGoForward);
  // The user went to `url` (already a web address): `preview.navigate`.
  Q_INVOKABLE void navigate(const QString& url);
  // The device size (BrowserPanel's js/browser.js viewportOf).
  Q_INVOKABLE void setViewport(const QVariantMap& viewport);

  // Runs `script` in the page; `done` gets its result (undefined as an
  // invalid QVariant). Answered by the brick (evaluated()); dropped with the page.
  void evaluate(const QString& script, std::function<void(const QVariant&)> done);
  // The page's picture as the view draws it, answered by the brick (grabbed()).
  void grab(std::function<void(const QImage&)> done);
  Q_INVOKABLE void evaluated(int request, const QVariant& result);
  Q_INVOKABLE void grabbed(int request, const QImage& image);

signals:
  void previewsChanged();
  void tabIdChanged();
  void tabChanged();
  void viewportChanged();
  void zoomChanged();
  void appearanceChanged();
  void mutedChanged();
  void devToolsChanged();
  void viewChanged();
  // The MC's tab went to an address the page did not report: the view loads it.
  void loadRequested(const QString& url);
  // For the brick: run `script` and answer evaluated(request, result); take
  // the view's picture and answer grabbed(request, image).
  void evaluateRequested(int request, const QString& script);
  void grabRequested(int request);
  // A keybinding for the showing page: preview.refresh, preview.focusUrl,
  // preview.zoomIn, preview.zoomOut or preview.resetZoom.
  void commandRequested(const QString& command);

private:
  void follow();
  void refresh();
  void went(const QString& url);

  QPointer<ThreadPreviews> m_previews;
  QString m_tabId;
  QString m_enrolled;
  QJsonObject m_tab;
  // Where the view is, and the addresses it went to that the MC has not said
  // back yet, oldest first: saying them back is no news, anything else is.
  QString m_at;
  QStringList m_echoes;
  QJsonObject m_lastReport;
  // A size picked and not yet confirmed, and which pick it was.
  QJsonObject m_pendingViewport;
  int m_viewportPick = 0;
  qreal m_zoom = 1.0;
  QString m_appearance = QStringLiteral("system");
  bool m_muted = false;
  bool m_devTools = false;
  QPointer<QQuickItem> m_view;
  int m_requests = 0;
  QHash<int, std::function<void(const QVariant&)>> m_evaluations;
  QHash<int, std::function<void(const QImage&)>> m_grabs;
};
