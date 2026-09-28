#pragma once

#include <QList>
#include <QObject>
#include <QStringList>
#include <QVariant>

#include <functional>
#include <type_traits>

class NodeClient;
class ShellBridge;
class ShellStore;

// A piece of the shell NativeShell runs on its own node connection. Each one
// registers itself from its .cpp file:
//
//   namespace {
//   const NativeControllerRegistrar<FooController> registrar("foo", {"foo"});
//   }
//
// and NativeShell builds every registered controller, activates them once the
// node's first snapshot lands, and offers them the bridge's actions. Build
// them into the hal_c2_native OBJECT library (any file in src/native is): a
// static archive would drop a registrar nothing else refers to.
class NativeController {
public:
  virtual ~NativeController() = default;

  // Once the shell has its node's first snapshot. Called again when the
  // sidebar changes hands, so it must be idempotent.
  virtual void activate() = 0;
  // The ShellBridge interceptor: true when the action was handled here.
  // Controllers see actions in name order; claim disjoint ones.
  virtual bool handle(const QString& action, const QVariant& payload) = 0;
};

struct NativeControllerRegistration {
  // Orders construction, activation and handling.
  QString name;
  // The `Shell.state` keys it publishes, declared before any QML binds them.
  QStringList stateKeys;
  // Registered as this `HalC2.Shell` singleton when set.
  const char* qmlName = nullptr;
  std::function<QObject*(ShellBridge*, NodeClient*, ShellStore*, QObject* parent)> create;
};

QList<NativeControllerRegistration>& nativeControllerRegistry();

// T is a QObject and a NativeController, built from (bridge, client, store,
// parent) or (bridge, client, parent).
template <class T>
struct NativeControllerRegistrar {
  explicit NativeControllerRegistrar(const QString& name, const QStringList& stateKeys = {},
                                     const char* qmlName = nullptr) {
    static_assert(std::is_base_of_v<QObject, T> && std::is_base_of_v<NativeController, T>);
    nativeControllerRegistry().append(
        {name, stateKeys, qmlName, [](ShellBridge* bridge, NodeClient* client, ShellStore* store, QObject* parent) {
           if constexpr (std::is_constructible_v<T, ShellBridge*, NodeClient*, ShellStore*, QObject*>) {
             return static_cast<QObject*>(new T(bridge, client, store, parent));
           } else {
             return static_cast<QObject*>(new T(bridge, client, parent));
           }
         }});
  }
};
