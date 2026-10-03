#pragma once

#include <QObject>
#include <QString>

#include <functional>

#include "NativeController.h"

class McClient;
class ShellBridge;

// What a file of the thread's workspace offers from its entry in the Files
// tab (the web's fileContextMenu and FileBrowserPanel), each on a path
// relative to the workspace:
//   `files.open {path}`            the viewer
//   `files.reveal {path}`          the environment's file manager, on the file
//                                  where the MC can select it
//                                  (`shellRevealInFileManager`), else on its folder
//   `files.openInEditor {path, editorId?}`  an editor on the environment (the
//                                  preferred one without an id)
//   `files.copyMention {path}`     the file as a draft links it, on the clipboard
//   `files.addToChat {path}`       that link at the end of the open draft
class FileActionsController : public QObject, public NativeController {
  Q_OBJECT

public:
  FileActionsController(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

  // Follows what the viewer says: which kinds of file the user reads as
  // source (kept on this device, `fileSourceKinds`) and a save the MC refused.
  void activate() override;
  bool handle(const QString& action, const QVariant& payload) override;

  // Writes the clipboard, false when it could not; tests read what was written.
  void setClipboardWriter(std::function<bool(const QString& text)> write) { m_writeClipboard = std::move(write); }

private:
  // The file on its environment, or empty without a workspace.
  QString absolute(const QString& path) const;

  ShellBridge* m_bridge;
  bool m_active = false;
  std::function<bool(const QString&)> m_writeClipboard;
};
