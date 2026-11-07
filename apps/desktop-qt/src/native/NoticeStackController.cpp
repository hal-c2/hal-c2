// Several notices above the composer show one at a time, the most pressing
// first (features/timeline/runs-and-queue.feature, the web's
// ComposerBannerStack): the thread's error (ThreadErrorController), a usage
// limit with its recovery actions (LimitRecoveryController) and what its
// provider says when it cannot run (ProviderNoticeController) stay in front
// of the answer to "/usage-limits" (ComposerController) and of what the
// agent is doing (ThreadNoticeController's background work, then a settled
// thread). The bricks draw only the front one while the stack is collapsed;
// asking for the other notices draws them all, and Escape (or going to
// another thread, or the stack shrinking to one) collapses it again.
// Dismissing the front one is its own controller's action and brings the
// next one forward on its own.
//
// Publishes `noticeStack`: {front, behind, expanded, order}; front is ""
// when there are no notices, behind counts the ones behind it.
//
// Actions: `noticeStack.expand` shows every notice; `noticeStack.collapse`
// shows only the front one again.

#include "NoticeStackController.h"

#include <QVariantMap>

#include "NativeShell.h"
#include "NavigationController.h"
#include "ShellBridge.h"

namespace {

// The published states the stack is ordered from.
const QStringList kSources{QStringLiteral("threadError"), QStringLiteral("limitRecovery"), QStringLiteral("providerNotice"),
                           QStringLiteral("composer"), QStringLiteral("threadNotice")};

bool shown(const QVariant& state) {
  return state.isValid() && !state.isNull() && !state.toMap().isEmpty();
}

}  // namespace

NoticeStackController::NoticeStackController(ShellBridge* bridge, McClient*, ShellStore*, QObject* parent)
    : QObject(parent), m_bridge(bridge) {}

void NoticeStackController::activate() {
  if (m_active) return;
  m_active = true;
  connect(m_bridge, &ShellBridge::stateEntryChanged, this, [this](const QString& key, const QVariant&) {
    if (kSources.contains(key)) publish();
  });
  connect(NativeShell::of(this)->controller<NavigationController>(), &NavigationController::changed, this, [this] {
    const QString key = NativeShell::of(this)->controller<NavigationController>()->threadKey();
    if (key != m_threadKey) {
      m_threadKey = key;
      m_expanded = false;
    }
    publish();
  });
  m_threadKey = NativeShell::of(this)->controller<NavigationController>()->threadKey();
  publish();
}

bool NoticeStackController::handle(const QString& action, const QVariant&) {
  if (!m_active) return false;
  if (action == QLatin1String("noticeStack.expand")) {
    m_expanded = order().size() > 1;
    publish();
    return true;
  }
  if (action != QLatin1String("noticeStack.collapse")) return false;
  m_expanded = false;
  publish();
  return true;
}

QStringList NoticeStackController::order() const {
  QStringList order;
  const auto state = [this](const QString& key) { return m_bridge->state()->value(key); };
  if (shown(state(QStringLiteral("threadError")))) order.append(QStringLiteral("error"));
  if (shown(state(QStringLiteral("limitRecovery")))) order.append(QStringLiteral("limit"));
  if (shown(state(QStringLiteral("providerNotice")))) order.append(QStringLiteral("provider"));
  if (shown(state(QStringLiteral("composer")).toMap().value(QStringLiteral("usageLimits")))) {
    order.append(QStringLiteral("usageLimits"));
  }
  const QVariantMap notice = state(QStringLiteral("threadNotice")).toMap();
  if (notice.value(QStringLiteral("kind")) == QLatin1String("background")) order.append(QStringLiteral("activity"));
  if (notice.value(QStringLiteral("kind")) == QLatin1String("settled")) order.append(QStringLiteral("settled"));
  return order;
}

void NoticeStackController::publish() {
  if (!m_active) return;
  const QStringList ordered = order();
  if (ordered.size() < 2) m_expanded = false;
  m_bridge->publish(QStringLiteral("noticeStack"),
                    QVariantMap{{QStringLiteral("front"), ordered.isEmpty() ? QString() : ordered.first()},
                                {QStringLiteral("behind"), int(ordered.size() > 0 ? ordered.size() - 1 : 0)},
                                {QStringLiteral("expanded"), m_expanded},
                                {QStringLiteral("order"), ordered}});
}

namespace {
const NativeControllerRegistrar<NoticeStackController> registrar(QStringLiteral("noticeStack"), {QStringLiteral("noticeStack")});
}  // namespace
