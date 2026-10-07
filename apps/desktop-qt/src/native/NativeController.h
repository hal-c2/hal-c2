#pragma once

#include <QList>
#include <QObject>
#include <QStringList>
#include <QVariant>

#include <QtQml/qqml.h>

#include <functional>
#include <type_traits>

class NativeWindow;
class McClient;
class ShellBridge;
class ShellStore;

// A piece of the shell NativeShell runs on its own MC connection. Each one
// registers itself from its .cpp file:
//
//   namespace {
//   const NativeControllerRegistrar<FooController> registrar("foo", {"foo"});
//   }
//
// and NativeShell builds every registered controller, activates them once the
// MC's first snapshot lands, and offers them the bridge's actions. Most are
// one per window (NativeWindow): what the window shows and the state behind
// it. A shared one (NativeControllerScope::Shared) is one per process, for
// what every window has alike (the settings, alerts, the quit shortcut); its keys
// reach every window's bridge and its parent is the NativeShell. Build
// them into the hal_c2_native OBJECT library (any file in src/native is): a
// static archive would drop a registrar nothing else refers to.
class NativeController {
public:
  virtual ~NativeController() = default;

  // Once the shell has its MC's first snapshot. Called again when the
  // sidebar changes hands, so it must be idempotent.
  virtual void activate() = 0;
  // The sidebar came from the cache and the MC has not answered yet: what a
  // controller can show of it, it shows. Nothing is decided on cached rows
  // and nothing is asked of the MC for them; activate() follows once the
  // MC's own rows land. May be called more than once.
  virtual void preview() {}
  // The ShellBridge interceptor: true when the action was handled here.
  // Controllers see actions in name order; claim disjoint ones.
  virtual bool handle(const QString& action, const QVariant& payload) = 0;
  // A shared controller meets each window once that window is active, to
  // follow its route or add its commands.
  virtual void attach(NativeWindow*) {}
};

enum class NativeControllerScope { Window, Shared };

struct NativeControllerRegistration {
  // Orders construction, activation and handling.
  QString name;
  // The `Shell.state` keys it publishes, declared before any QML binds them.
  QStringList stateKeys;
  // Registered as this `HalC2.Shell` singleton when set.
  const char* qmlName = nullptr;
  NativeControllerScope scope = NativeControllerScope::Window;
  std::function<QObject*(ShellBridge*, McClient*, ShellStore*, QObject* parent)> create;
  // Registers the type as singleton qmlName, each engine's from `lookup`.
  std::function<void(std::function<QObject*(QQmlEngine*)> lookup)> registerSingleton;
};

QList<NativeControllerRegistration>& nativeControllerRegistry();

// T is a QObject and a NativeController, built from (bridge, client, store,
// parent) or (bridge, client, parent).
template <class T>
struct NativeControllerRegistrar {
  explicit NativeControllerRegistrar(const QString& name, const QStringList& stateKeys = {},
                                     const char* qmlName = nullptr,
                                     NativeControllerScope scope = NativeControllerScope::Window) {
    static_assert(std::is_base_of_v<QObject, T> && std::is_base_of_v<NativeController, T>);
    nativeControllerRegistry().append(
        {name, stateKeys, qmlName, scope, [](ShellBridge* bridge, McClient* client, ShellStore* store, QObject* parent) {
           if constexpr (std::is_constructible_v<T, ShellBridge*, McClient*, ShellStore*, QObject*>) {
             return static_cast<QObject*>(new T(bridge, client, store, parent));
           } else {
             return static_cast<QObject*>(new T(bridge, client, parent));
           }
         },
         [qmlName](std::function<QObject*(QQmlEngine*)> lookup) {
           // Only a Q_OBJECT class can be one (and one naming no qmlName may not be).
           if constexpr (QtPrivate::HasQ_OBJECT_Macro<T>::Value) {
             qmlRegisterSingletonType<T>("HalC2.Shell", 1, 0, qmlName, [lookup](QQmlEngine* engine, QJSEngine*) {
               return qobject_cast<T*>(lookup(engine));
             });
           }
         }});
  }
};
