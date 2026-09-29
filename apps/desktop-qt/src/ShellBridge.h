#pragma once

#include <QObject>
#include <QQmlPropertyMap>
#include <QSet>
#include <QUrl>
#include <QVariant>
#include <QVariantMap>

#include <functional>

class ShellChannel;

// The `Shell` singleton QML bricks read from. State flows web -> QML through
// `publish`; actions flow QML -> web through `dispatch`/`actionRequested`.
// The bridge itself holds no domain logic: it stores what is published and
// relays actions, except those an interceptor (NativeShell's controllers,
// which talk to the node themselves) claims first. Pages reach it through
// `channel`, never through this object directly.
class ShellBridge : public QObject {
  Q_OBJECT
  Q_PROPERTY(int protocolVersion READ protocolVersion CONSTANT)
  // One QML property per published key (Shell.state.composer, ...), so a
  // publish only re-evaluates the bindings that read that key. Keys the page
  // may publish are declared up front; a binding made before its key exists
  // would never see the value.
  Q_PROPERTY(QQmlPropertyMap* state READ state CONSTANT)
  Q_PROPERTY(QObject* channel READ channel CONSTANT)
  Q_PROPERTY(QUrl pageUrl READ pageUrl WRITE setPageUrl NOTIFY pageUrlChanged)
  Q_PROPERTY(QUrl webChannelScriptUrl READ webChannelScriptUrl CONSTANT)
  Q_PROPERTY(QString colorScheme READ colorScheme NOTIFY colorSchemeChanged)
  Q_PROPERTY(bool localFolderImportEnabled READ localFolderImportEnabled CONSTANT)

public:
  explicit ShellBridge(QObject* parent = nullptr);

  int protocolVersion() const { return 1; }
  QQmlPropertyMap* state() const { return m_state; }
  QObject* channel() const;
  QVariantMap snapshot() const;
  QUrl pageUrl() const { return m_pageUrl; }
  void setPageUrl(const QUrl& url);
  QUrl webChannelScriptUrl() const;
  QString colorScheme() const { return m_colorScheme; }
  bool localFolderImportEnabled() const { return m_localFolderImportEnabled; }
  void setLocalFolderImportEnabled(bool enabled) { m_localFolderImportEnabled = enabled; }

  // A key bindings can follow before anything publishes it; see kStateKeys.
  void declareKey(const QString& key);
  // Called by the web app (via the channel) with its view models.
  Q_INVOKABLE void publish(const QString& key, const QVariant& value);
  Q_INVOKABLE void openExternal(const QUrl& url);
  // Where openExternal sends a URL; the system browser unless tests say otherwise.
  void setUrlOpener(std::function<void(const QUrl&)> open) { m_openUrl = std::move(open); }
  Q_INVOKABLE void setColorScheme(const QString& scheme);
  Q_INVOKABLE void windowCommand(const QString& command);

  // Called by QML bricks; delivered to the web app as `actionRequested`
  // unless an interceptor (the native controllers) claims it first.
  Q_INVOKABLE void dispatch(const QString& action, const QVariant& payload = QVariant());
  using Interceptor = std::function<bool(const QString& action, const QVariant& payload)>;
  void addInterceptor(Interceptor interceptor) { m_interceptors.append(std::move(interceptor)); }
  // Native code asking the page to do something (navigate, toast): bypasses
  // the interceptors, which would otherwise see their own requests.
  void sendToPage(const QString& action, const QVariant& payload = QVariant()) {
    emit actionRequested(action, payload);
  }
  // A key native code now publishes itself: pages' publishes to it are dropped,
  // so a page that has not caught up (or unmounts, publishing null) cannot
  // overwrite it.
  void claimKey(const QString& key) { m_claimedKeys.insert(key); }
  void releaseKey(const QString& key) { m_claimedKeys.remove(key); }
  bool isClaimed(const QString& key) const { return m_claimedKeys.contains(key); }
  // Reads image files for the composer: [{name, mimeType, base64}], skipping
  // anything that is not an image or is over the page's size limit.
  Q_INVOKABLE QVariantList readImageFiles(const QList<QUrl>& urls) const;
  // A drop imports an existing local directory, never creates or deletes it.
  Q_INVOKABLE QString localDirectoryPath(const QUrl& url) const;
  // Called by WebSurface when a top-level navigation finishes.
  Q_INVOKABLE void notifyPageLoaded(bool ok, const QUrl& url);
  // Permissions belong only to the configured app origin, including its port.
  Q_INVOKABLE bool isAppOrigin(const QUrl& url) const;

signals:
  void stateEntryChanged(const QString& key, const QVariant& value);
  void pageUrlChanged();
  void colorSchemeChanged();
  void actionRequested(const QString& action, const QVariant& payload);
  void windowCommandRequested(const QString& command);
  void pageLoaded(bool ok, const QUrl& url);

private:
  QQmlPropertyMap* m_state;
  ShellChannel* m_channel;
  QList<Interceptor> m_interceptors;
  std::function<void(const QUrl&)> m_openUrl;
  QSet<QString> m_claimedKeys;
  QUrl m_pageUrl;
  QString m_colorScheme = QStringLiteral("system");
  bool m_localFolderImportEnabled = false;
};

// The one object registered on every surface's WebChannel. It has no
// properties on purpose: QWebChannel re-serializes a changed property to
// every connected page, which for the state map meant every publish (each
// composer keystroke) echoed the whole map back to both surfaces. Pages that
// need the map pull `snapshot` once and follow `stateEntryChanged`.
class ShellChannel : public QObject {
  Q_OBJECT

public:
  explicit ShellChannel(ShellBridge* bridge);

  Q_INVOKABLE void publish(const QString& key, const QVariant& value);
  Q_INVOKABLE void dispatch(const QString& action, const QVariant& payload);
  Q_INVOKABLE QVariantMap snapshot() const;

signals:
  void actionRequested(const QString& action, const QVariant& payload);
  void stateEntryChanged(const QString& key, const QVariant& value);

private:
  ShellBridge* m_bridge;
};
