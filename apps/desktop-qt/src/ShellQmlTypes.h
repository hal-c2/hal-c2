#pragma once

// What `import HalC2.Shell` holds, declared for the tools that read QML without
// running it: qmllint, the QML language server and the import scanners that
// package the app. The app registers these same names itself, per window
// (ShellRuntime, NativeShell::registerQmlSingletons, main.cpp), and never links
// this declaration; a name added there is added here.

#include <QtQml/qqmlregistration.h>

#include "LocalFolderModel.h"
#include "LocalTranscriber.h"
#include "ShellBridge.h"
#include "ShellRuntime.h"
#include "ThemeStore.h"
#include "native/CommandPaletteController.h"
#include "native/CommandRegistry.h"
#include "native/ComposerHighlighter.h"
#include "native/DeviceScreen.h"
#include "native/KeybindingController.h"
#include "native/OnboardingController.h"
#include "native/RightPanelController.h"
#include "native/SettingsController.h"
#include "native/TerminalController.h"
#include "native/ThemeController.h"
#include "native/ThreadDiff.h"
#include "native/ThreadStore.h"
#include "native/TimelineModel.h"

#define HAL_C2_SHELL_SINGLETON(Class, Name) \
  struct Name##Declaration {                \
    Q_GADGET                                \
    QML_FOREIGN(Class)                      \
    QML_NAMED_ELEMENT(Name)                 \
    QML_SINGLETON                           \
  };

#define HAL_C2_SHELL_TYPE(Class) \
  struct Class##Declaration {    \
    Q_GADGET                     \
    QML_FOREIGN(Class)           \
    QML_NAMED_ELEMENT(Class)     \
  };

// A type QML only meets as a property's value, never by name.
#define HAL_C2_SHELL_VALUE(Class) \
  struct Class##Declaration {     \
    Q_GADGET                      \
    QML_FOREIGN(Class)            \
    QML_ANONYMOUS                 \
  };

HAL_C2_SHELL_SINGLETON(ShellBridge, Shell)
HAL_C2_SHELL_SINGLETON(ThemeStore, Theme)
HAL_C2_SHELL_SINGLETON(ShellRuntime, Runtime)
HAL_C2_SHELL_SINGLETON(ThreadStore, Threads)
HAL_C2_SHELL_SINGLETON(ThemeController, Themes)
HAL_C2_SHELL_SINGLETON(TerminalController, Terminals)
HAL_C2_SHELL_SINGLETON(SettingsController, Settings)
HAL_C2_SHELL_SINGLETON(RightPanelController, Panel)
HAL_C2_SHELL_SINGLETON(CommandPaletteController, PaletteModel)
HAL_C2_SHELL_SINGLETON(OnboardingController, Onboarding)
HAL_C2_SHELL_SINGLETON(KeybindingController, Keybindings)

HAL_C2_SHELL_TYPE(LocalTranscriber)
HAL_C2_SHELL_TYPE(LocalFolderModel)
HAL_C2_SHELL_TYPE(ComposerHighlighter)
HAL_C2_SHELL_TYPE(DeviceScreen)

struct DeviceStreamDeclaration {
  Q_GADGET
  QML_FOREIGN(DeviceStream)
  QML_NAMED_ELEMENT(DeviceStream)
  QML_UNCREATABLE("A device tab's stream")
};

HAL_C2_SHELL_VALUE(CommandRegistry)
HAL_C2_SHELL_VALUE(TerminalTabs)
HAL_C2_SHELL_VALUE(ThreadDiff)
HAL_C2_SHELL_VALUE(TimelineModel)
