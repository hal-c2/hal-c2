#include "FileActionsController.h"

#include <QClipboard>
#include <QGuiApplication>

#include "CommandRegistry.h"
#include "ComposerController.h"
#include "ComposerModel.h"
#include "KeybindingController.h"
#include "NativeShell.h"
#include "RightPanelController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ToastController.h"
#include "WorkspaceController.h"

namespace {

const NativeControllerRegistrar<FileActionsController> registrar(QStringLiteral("fileActions"));

const QString kCopyContents = QStringLiteral("files.copyContents");

// The viewer shows a file as text, which can be copied.
bool copyable(const WorkspaceFiles* files) {
  return files && files->fileStatus() == QLatin1String("ready") && files->mediaKind().isEmpty();
}

}  // namespace

FileActionsController::FileActionsController(ShellBridge* bridge, McClient*, QObject* parent) : QObject(parent), m_bridge(bridge) {
  m_writeClipboard = [](const QString& text) {
    QClipboard* clipboard = QGuiApplication::clipboard();
    if (!clipboard) return false;
    clipboard->setText(text);
    return true;
  };
}

void FileActionsController::activate() {
  if (m_active) return;
  m_active = true;
  auto* shell = NativeShell::of(this);
  WorkspaceFiles* files = shell->controller<RightPanelController>()->files();
  auto* settings = shell->controller<SettingsController>();
  const QString key = QStringLiteral("fileSourceKinds");
  const auto read = [files, settings, key] { files->setSourceKinds(settings->deviceValue(key).toStringList()); };
  connect(settings, &SettingsController::deviceChanged, files, read);
  read();
  connect(files, &WorkspaceFiles::sourceKindsChanged, settings, [files, settings, key] {
    settings->writeDevice(key, files->sourceKinds().isEmpty() ? QVariant() : QVariant(files->sourceKinds()));
  });
  connect(files, &WorkspaceFiles::saveFailed, this, [shell](const QString& path, const QString& problem) {
    shell->controller<ToastController>()->error(tr("Could not save %1").arg(path), problem);
  });
  CommandRegistry* commands = shell->controller<KeybindingController>()->commands();
  commands->add(kCopyContents, tr("Copy file contents"), [this] { copyContents(); });
  commands->setTerms(kCopyContents, {QStringLiteral("clipboard"), QStringLiteral("text"), QStringLiteral("file")});
  const auto follow = [commands, files] {
    commands->setEnabled(kCopyContents, copyable(files));
    commands->setListed(kCopyContents, copyable(files));
  };
  connect(files, &WorkspaceFiles::fileChanged, commands, follow);
  follow();
}

void FileActionsController::copyContents() {
  auto* shell = NativeShell::of(this);
  auto* toasts = shell->controller<ToastController>();
  const WorkspaceFiles* files = shell->controller<RightPanelController>()->files();
  if (!copyable(files)) {
    toasts->error(tr("No file to copy"), tr("Open a text file in the Files panel first."));
  } else if (!m_writeClipboard(files->text())) {
    toasts->error(tr("Failed to copy file contents"));
  } else {
    // A file larger than the MC reads whole has only its start in the viewer.
    const QString path = files->openPath();
    toasts->show(QStringLiteral("success"), tr("File contents copied"),
                 files->truncatedNotice().isEmpty() ? path : tr("Only the first 1 MB of %1.").arg(path));
  }
}

QString FileActionsController::absolute(const QString& path) const {
  const auto* panel = NativeShell::of(this)->controller<RightPanelController>();
  const QString root = panel ? const_cast<RightPanelController*>(panel)->files()->root() : QString();
  if (root.isEmpty() || path.isEmpty()) return {};
  // One the agent left outside the workspace is opened by its full path.
  if (path.startsWith(QLatin1Char('/')) || path.contains(QLatin1String(":\\"))) return path;
  return root + (root.endsWith(QLatin1Char('/')) ? QString() : QStringLiteral("/")) + path;
}

bool FileActionsController::handle(const QString& action, const QVariant& payload) {
  if (!action.startsWith(QLatin1String("files."))) return false;
  auto* shell = NativeShell::of(this);
  const QVariantMap map = payload.toMap();
  const QString path = map.value(QStringLiteral("path")).toString();
  auto* toasts = shell->controller<ToastController>();
  if (action == QLatin1String("files.open")) {
    m_bridge->dispatch(QStringLiteral("panel.open"), QVariantMap{{QStringLiteral("tab"), QStringLiteral("files")}, {QStringLiteral("path"), path}});
  } else if (action == QLatin1String("files.reveal") || action == QLatin1String("files.openInEditor")) {
    auto* workspace = shell->controller<WorkspaceController>();
    const bool reveal = action == QLatin1String("files.reveal");
    QString target = absolute(path);
    // An MC that cannot select a file shows the folder it is in.
    const bool selects = workspace->localConfig().value(QLatin1String("shellRevealInFileManager")).toBool();
    if (reveal && !selects) target = target.left(target.lastIndexOf(QLatin1Char('/')));
    const bool opened = !target.isEmpty() && (reveal && !selects ? workspace->openInEditor(QStringLiteral("file-manager"), target)
                                                                 : workspace->openInEditor(map.value(QStringLiteral("editorId")).toString(), target, reveal));
    if (!opened) {
      toasts->error(reveal ? tr("Unable to show the file") : tr("Unable to open the file"),
                    reveal ? tr("This environment has no file manager.") : tr("This environment has no editor."));
    }
  } else if (action == QLatin1String("files.copyMention")) {
    if (m_writeClipboard(composer::pathLink(path).chopped(1))) {
      toasts->show(QStringLiteral("success"), tr("Mention copied"), path);
    } else {
      toasts->error(tr("Failed to copy mention"));
    }
  } else if (action == kCopyContents) {
    copyContents();
  } else if (action == QLatin1String("files.addToChat")) {
    if (!shell->controller<ComposerController>()->insertAtEnd(composer::pathLink(path))) {
      toasts->error(tr("Unable to add to chat"), tr("Open a chat for this project and try again."));
    }
  } else {
    return false;
  }
  return true;
}
