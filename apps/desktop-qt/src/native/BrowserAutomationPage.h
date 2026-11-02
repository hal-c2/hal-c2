#pragma once

#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>

#include "PreviewAutomationPage.h"

class BrowserPage;

// A browser tab's page (BrowserPage, the brick's WebEngineView behind it) as
// the preview automation host drives it. It talks to the view through its
// meta-object, so hal_c2_native never links the web engine.
//
// Real input goes to the view's window as the user's would, and so reaches the
// page as trusted events; the window's own input that lands on the page is
// the user's (humanInput). A key goes in only while the page has the focus,
// which a real click gives it.
class BrowserAutomationPage : public PreviewAutomationPage {
  Q_OBJECT

public:
  // Lives as long as `page`, whose child it is.
  explicit BrowserAutomationPage(BrowserPage* page);

  BrowserPage* browserPage() const { return m_page; }

  void runJavaScript(const QString& script, World world, ScriptDone done) override;
  void grab(ImageDone done) override;
  QUrl url() const override;
  QString title() const override;
  bool loading() const override;
  void load(const QUrl& url) override;
  bool devToolsOpen() const override;
  bool onScreen() const override;
  QSize viewport() const override;
  void setViewport(const QSize& size) override;
  bool click(const QPointF& point) override;
  bool key(int key, Qt::KeyboardModifiers modifiers, const QString& text) override;
  void setColorScheme(const QString& scheme) override;

protected:
  bool eventFilter(QObject* watched, QEvent* event) override;

private:
  void follow();
  void watch(QQuickWindow* window);
  QQuickItem* view() const;
  qreal zoom() const;
  // Whether the window's input at `scene` (or its keys, with no point) is the page's.
  bool onPage(const QPointF& scene) const;
  bool pageHasFocus() const;

  QPointer<BrowserPage> m_page;
  QPointer<QQuickItem> m_view;
  QPointer<QQuickWindow> m_window;
  QList<QMetaObject::Connection> m_viewConnections;
};
