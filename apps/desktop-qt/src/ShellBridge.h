#pragma once

#include <QObject>
#include <QQmlPropertyMap>
#include <QUrl>
#include <QVariant>
#include <QVariantMap>

#include <functional>

// The `Shell` singleton QML bricks read from. State flows controllers -> QML
// through `publish`; actions flow QML -> controllers through `dispatch`.
// The bridge itself holds no domain logic: it stores what is published and
// hands each action to the interceptors (NativeShell's controllers) until one
// handles it; the rest reach the bricks as `actionRequested`.
class ShellBridge : public QObject {
  Q_OBJECT
  Q_PROPERTY(int protocolVersion READ protocolVersion CONSTANT)
  // One QML property per published key (Shell.state.composer, ...), so a
  // publish only re-evaluates the bindings that read that key. Keys are
  // declared up front; a binding made before its key exists would never see
  // the value.
  Q_PROPERTY(QQmlPropertyMap* state READ state CONSTANT)
  Q_PROPERTY(bool localFolderImportEnabled READ localFolderImportEnabled CONSTANT)

public:
  explicit ShellBridge(QObject* parent = nullptr);

  int protocolVersion() const { return 1; }
  QQmlPropertyMap* state() const { return m_state; }
  bool localFolderImportEnabled() const { return m_localFolderImportEnabled; }
  void setLocalFolderImportEnabled(bool enabled) { m_localFolderImportEnabled = enabled; }
  // The MC the shell is connected to; local folders are its only when it
  // runs on this machine (a loopback origin).
  QUrl mcOrigin() const { return m_mcOrigin; }
  void setMcOrigin(const QUrl& origin) { m_mcOrigin = origin; }
  // Whether this machine's folders are the MC's: import is allowed and the
  // MC runs here.
  bool localFolders() const;

  // A key bindings can follow before anything publishes it; see kStateKeys.
  void declareKey(const QString& key);
  // Called by the controllers with their view models.
  Q_INVOKABLE void publish(const QString& key, const QVariant& value);
  Q_INVOKABLE void openExternal(const QUrl& url);
  // Where openExternal sends a URL; the system browser unless tests say otherwise.
  void setUrlOpener(std::function<void(const QUrl&)> open) { m_openUrl = std::move(open); }
  Q_INVOKABLE void windowCommand(const QString& command);

  // Called by QML bricks; handed to the interceptors (the native controllers)
  // in turn, and delivered as `actionRequested` when none handles it.
  Q_INVOKABLE void dispatch(const QString& action, const QVariant& payload = QVariant());
  using Interceptor = std::function<bool(const QString& action, const QVariant& payload)>;
  void addInterceptor(Interceptor interceptor) { m_interceptors.append(std::move(interceptor)); }
  // Native code asking the bricks to do something (focus the composer, open
  // its model picker): bypasses the interceptors, which would otherwise see
  // their own requests.
  void sendToBricks(const QString& action, const QVariant& payload = QVariant()) {
    emit actionRequested(action, payload);
  }
  // Reads image files for the composer: [{name, mimeType, base64}], skipping
  // anything that is not an image or is over the attachment size limit.
  Q_INVOKABLE QVariantList readImageFiles(const QList<QUrl>& urls) const;
  // Reads files for the composer: an image as readImageFiles has it, any
  // other file as {name, mimeType, path} (its bytes go up from the path);
  // folders, empty files and ones over the attachment limits are skipped.
  Q_INVOKABLE QVariantList readAttachmentFiles(const QList<QUrl>& urls) const;
  // The folders among `urls`, as paths on this machine.
  Q_INVOKABLE QStringList directoryPaths(const QList<QUrl>& urls) const;
  // The clipboard's text, for the composer's own paste.
  Q_INVOKABLE QString clipboardText() const;
  // The files the composer's own paste attaches: copied files
  // when one is a picture or the clipboard has no other text than
  // their names, else a copied picture as "image.png" ({name, mimeType,
  // base64}). Empty when the paste is text.
  Q_INVOKABLE QVariantList clipboardFiles() const;
  // Whether pasting `text` into a prompt of `promptLength` characters makes
  // it a text file instead: 32 KiB or
  // more, or more than the prompt can hold.
  Q_INVOKABLE bool pasteAttaches(const QString& text, int promptLength) const;
  // A drop imports an existing local directory, never creates or deletes it.
  Q_INVOKABLE QString localDirectoryPath(const QUrl& url) const;

signals:
  void stateEntryChanged(const QString& key, const QVariant& value);
  void actionRequested(const QString& action, const QVariant& payload);
  void windowCommandRequested(const QString& command);

private:
  QQmlPropertyMap* m_state;
  QList<Interceptor> m_interceptors;
  std::function<void(const QUrl&)> m_openUrl;
  QUrl m_mcOrigin;
  bool m_localFolderImportEnabled = false;
};

