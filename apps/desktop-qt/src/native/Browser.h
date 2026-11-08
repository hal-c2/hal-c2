#pragma once

#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QPointer>
#include <QQuickItem>
#include <QStringList>
#include <QVariant>

#include <functional>

#include "PagePermissions.h"
#include "ThreadPreviews.h"

class BrowserPage;

// The in-app browser, as the `Browser` QML singleton: the profile its pages share (persistent under the desktop's data
// directory; none in tests, whose pages use the engine's off-the-record
// default), and how DevTools dock and the Devices view look (remembered on
// this device).
//
// It also finds a thread's pages: every BrowserPage registers under its MC
// tab id while it exists, for what drives pages from C++ (the preview
// automation host): Browser::page(tabId).
class Browser : public QObject {
  Q_OBJECT
  Q_PROPERTY(QObject* profile READ profile CONSTANT)
  // "bottom" or "right", and the share of the page DevTools take (0.2-0.8).
  Q_PROPERTY(QString devToolsDock READ devToolsDock WRITE setDevToolsDock NOTIFY devToolsChanged)
  Q_PROPERTY(qreal devToolsShare READ devToolsShare WRITE setDevToolsShare NOTIFY devToolsChanged)
  // Whether a browser tab opens showing its Devices view, which presets it
  // shows there (js/browser.js's preset ids, plus "desktop"), and whether it
  // shows them on their 3D bodies.
  Q_PROPERTY(bool devicesView READ devicesView WRITE setDevicesView NOTIFY devicesViewChanged)
  Q_PROPERTY(QStringList devicesPresetIds READ devicesPresetIds WRITE setDevicesPresetIds NOTIFY devicesViewChanged)
  Q_PROPERTY(bool devices3d READ devices3d WRITE setDevices3d NOTIFY devicesViewChanged)
  // What pages may ask for, and the question the user is being asked.
  Q_PROPERTY(PagePermissions* permissions READ permissions CONSTANT)

public:
  static Browser* instance();

  // Whether this client has the in-app browser: the desktop does (main.cpp
  // says so); the phone client links no QtWebEngine and opens pages in the
  // system browser. Not in QML: the desktop's QML always has it.
  static void setSupported(bool supported);
  static bool supported();
  // The profile pages use (a QQuickWebEngineProfile); made by main.cpp.
  static void setProfile(QObject* profile);
  QObject* profile() const;

  QString devToolsDock() const { return m_dock; }
  qreal devToolsShare() const { return m_share; }
  void setDevToolsDock(const QString& dock);
  void setDevToolsShare(qreal share);
  bool devicesView() const { return m_devicesView; }
  void setDevicesView(bool shown);
  QStringList devicesPresetIds() const { return m_devicesPresetIds; }
  void setDevicesPresetIds(const QStringList& ids);
  bool devices3d() const { return m_devices3d; }
  void setDevices3d(bool shown);
  // Where the DevTools and Devices view layout are kept: read now, written on each change.
  void setStore(std::function<QVariant(const QString&)> read, std::function<void(const QString&, const QVariant&)> write);

  PagePermissions* permissions() { return &m_permissions; }

  // The page showing MC tab `tabId`, or null while none does.
  static BrowserPage* page(const QString& tabId);
  static QList<BrowserPage*> pages();

signals:
  void devToolsChanged();
  void devicesViewChanged();
  // A page came or went.
  void pagesChanged();

private:
  friend class BrowserPage;
  explicit Browser(QObject* parent = nullptr) : QObject(parent) {}
  void enrol(BrowserPage* page, const QString& tabId);
  void leave(BrowserPage* page, const QString& tabId);

  QString m_dock = QStringLiteral("bottom");
  qreal m_share = 0.4;
  bool m_devicesView = false;
  QStringList m_devicesPresetIds{QStringLiteral("iphone-12-pro"), QStringLiteral("ipad-air"), QStringLiteral("desktop")};
  bool m_devices3d = false;
  std::function<void(const QString&, const QVariant&)> m_write;
  QHash<QString, QPointer<BrowserPage>> m_pages;
  PagePermissions m_permissions;
};

// One browser tab's page, made by its brick (BrowserPanel) beside the
// WebEngineView that draws it: the C++ half of the tab. It follows the MC's
// tab (ThreadPreviews) and tells the MC what the page does.
//
// What the view did comes in through report(); the MC hears it as
// `preview.reportStatus`; one the MC refuses takes the page back to its tab,
// one the connection could not carry goes again once the MC lists the tabs.
// The MC's tab moving to an address the page did not
// report (an agent's `preview.navigate`, another window) asks the view to load
// it (loadRequested). The device size is the MC's (`viewport`): setViewport
// shows the new size at once (`resizing` until the MC answers) and sends
// `preview.resize`; refused or timed out, the size the MC has is the size;
// taken, the size picked is, until the MC's tab says otherwise. A newer pick
// outlives an older one's answer.
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
  // A size was picked (setViewport) and the MC has not confirmed it yet.
  Q_PROPERTY(bool resizing READ resizing NOTIFY resizingChanged)
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
  bool resizing() const { return m_resizing; }
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
  // `world` is the script world (WebEngineScript: 0 the page's own, 1 the
  // application's, which shares only the DOM with the page's scripts).
  void evaluate(const QString& script, std::function<void(const QVariant&)> done, int world = 0);
  // The page's picture as the view draws it, answered by the brick (grabbed()).
  void grab(std::function<void(const QImage&)> done);
  Q_INVOKABLE void evaluated(int request, const QVariant& result);
  Q_INVOKABLE void grabbed(int request, const QImage& image);
  // What the page logged (WebEngineView's javaScriptConsoleMessage).
  Q_INVOKABLE void consoleMessage(int level, const QString& message, int line, const QString& source);

signals:
  void previewsChanged();
  void tabIdChanged();
  void tabChanged();
  void viewportChanged();
  void resizingChanged();
  void zoomChanged();
  void appearanceChanged();
  void mutedChanged();
  void devToolsChanged();
  void viewChanged();
  // The MC's tab went to an address the page did not report: the view loads it.
  void loadRequested(const QString& url);
  // For the brick: run `script` and answer evaluated(request, result); take
  // the view's picture and answer grabbed(request, image).
  void evaluateRequested(int request, const QString& script, int world);
  void grabRequested(int request);
  // A keybinding for the showing page: preview.refresh, preview.focusUrl,
  // preview.zoomIn, preview.zoomOut or preview.resetZoom.
  void commandRequested(const QString& command);
  // For drivers: the page logged `text` (level info, warning or error), or a
  // load failed.
  void logged(const QString& level, const QString& text, const QString& source);
  void loadFailed(const QString& url, const QString& description);

private:
  void follow();
  void refresh();
  void went(const QString& url);
  void send();
  void setPending(const QJsonObject& viewport, bool waiting);

  QPointer<ThreadPreviews> m_previews;
  QString m_tabId;
  QString m_enrolled;
  QJsonObject m_tab;
  // Where the view is, and the addresses it went to that the MC has not said
  // back yet, oldest first: saying them back is no news, anything else is.
  QString m_at;
  QStringList m_echoes;
  QJsonObject m_lastReport;
  // The last report never reached the MC (the connection was down): it goes
  // again once the MC lists the tabs, unless its tab has moved on since.
  bool m_unsent = false;
  // A size picked that the MC's tab does not show yet, whether the MC is yet
  // to answer it, and which pick it was.
  QJsonObject m_pendingViewport;
  bool m_resizing = false;
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
