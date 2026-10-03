#include "FileActionsController.h"

#include <QClipboard>
#include <QGuiApplication>

#include "ComposerController.h"
#include "ComposerModel.h"
#include "NativeShell.h"
#include "RightPanelController.h"
#include "SettingsController.h"
#include "ShellBridge.h"
#include "ToastController.h"
#include "WorkspaceController.h"

namespace {

const NativeControllerRegistrar<FileActionsController> registrar(QStringLiteral("fileActions"));

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
}

QString FileActionsController::absolute(const QString& path) const {
  const auto* panel = NativeShell::of(this)->controller<RightPanelController>();
  const QString root = panel ? const_cast<RightPanelController*>(panel)->files()->root() : QString();
  if (root.isEmpty() || path.isEmpty()) return {};
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
    const bool selects = workspace->environmentConfig().value(QLatin1String("shellRevealInFileManager")).toBool();
    if (reveal && !selects) target = target.left(target.lastIndexOf(QLatin1Char('/')));
    const bool opened = !target.isEmpty() && (reveal && !selects ? workspace->openInEditor(QStringLiteral("file-manager"), target)
                                                                 : workspace->openInEditor(map.value(QStringLiteral("editorId")).toString(), target, reveal));
    if (!opened) {
      toasts->error(reveal ? tr("Unable to show the file") : tr("Unable to open the file"),
                    reveal ? tr("This environment has no file manager.") : tr("This environment has no editor."));
    }
  } else if (action == QLatin1String("files.copyMention")) {
    if (m_writeClipboard(composer::mention(path))) {
      toasts->show(QStringLiteral("success"), tr("Mention copied"), path);
    } else {
      toasts->error(tr("Failed to copy mention"));
    }
  } else if (action == QLatin1String("files.addToChat")) {
    if (!shell->controller<ComposerController>()->insertAtEnd(composer::mention(path) + QLatin1Char(' '))) {
      toasts->error(tr("Unable to add to chat"), tr("Open a chat for this project and try again."));
    }
  } else {
    return false;
  }
  return true;
}
