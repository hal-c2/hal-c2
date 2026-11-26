#include "MacPlatform.h"

#ifdef Q_OS_MACOS
// MacPlatform.mm.
MacPlatform* createNativeMacPlatform(QObject* parent);
#endif

namespace {

MacPlatform::Factory& factory() {
  static MacPlatform::Factory value;
  return value;
}

}  // namespace

void MacPlatform::setFactory(Factory next) {
  factory() = std::move(next);
}

bool MacPlatform::overridden() {
  return bool(factory());
}

MacPlatform* MacPlatform::create(QObject* parent) {
  if (factory()) return factory()(parent);
#ifdef Q_OS_MACOS
  return createNativeMacPlatform(parent);
#else
  return nullptr;
#endif
}
