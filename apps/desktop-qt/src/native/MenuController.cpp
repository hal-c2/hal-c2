#include "MenuController.h"

#include "ShellBridge.h"

namespace {

const NativeControllerRegistrar<MenuController> registrar(QStringLiteral("menus"),
                                                          {QStringLiteral("menu"), QStringLiteral("confirmation")});

QVariantList variants(const QList<MenuController::Item>& items) {
  QVariantList out;
  for (const MenuController::Item& item : items) {
    QVariantMap entry{
        {QStringLiteral("id"), item.id},
        {QStringLiteral("label"), item.label},
        {QStringLiteral("icon"), item.icon},
        {QStringLiteral("enabled"), item.enabled},
        {QStringLiteral("checked"), item.checked},
        {QStringLiteral("destructive"), item.destructive},
        {QStringLiteral("separatorBefore"), item.separatorBefore},
    };
    if (!item.children.isEmpty()) entry.insert(QStringLiteral("children"), variants(item.children));
    out.append(entry);
  }
  return out;
}

// Whether `id` is an enabled item (or child of an enabled item) of `items`.
bool offered(const QList<MenuController::Item>& items, const QString& id) {
  for (const MenuController::Item& item : items) {
    if (!item.enabled) continue;
    if (item.id == id && item.children.isEmpty()) return true;
    if (offered(item.children, id)) return true;
  }
  return false;
}

}  // namespace

MenuController::MenuController(ShellBridge* bridge, McClient*, QObject* parent)
    : QObject(parent), m_bridge(bridge) {}

bool MenuController::handle(const QString& action, const QVariant& payload) {
  const QVariantMap map = payload.toMap();
  const QString requestId = map.value(QStringLiteral("requestId")).toString();
  if (action == QLatin1String("menu.select")) {
    if (!m_menu || m_menu->requestId != requestId) return true;
    const Open menu = std::move(*m_menu);
    close();
    const QVariant id = map.value(QStringLiteral("id"));
    if (id.typeId() == QMetaType::QString && menu.chosen) menu.chosen(id.toString());
    return true;
  }
  if (action == QLatin1String("confirmation.answer")) {
    if (!m_question || m_question->requestId != requestId) return true;
    const Question question = std::move(*m_question);
    m_question.reset();
    m_bridge->publish(QStringLiteral("confirmation"), QVariant::fromValue(nullptr));
    if (map.value(QStringLiteral("accepted")).toBool()) {
      if (question.accepted) question.accepted();
    } else if (question.declined) {
      question.declined();
    }
    return true;
  }
  return false;
}

void MenuController::open(double x, double y, const QList<Item>& items, Chosen chosen) {
  const QString requestId = QStringLiteral("menu:%1").arg(m_nextId++);
  // Only what was offered can be picked, however the answer is spelled.
  m_menu = Open{requestId, [items, chosen = std::move(chosen)](const QString& id) {
                  if (offered(items, id)) chosen(id);
                }};
  m_bridge->publish(QStringLiteral("menu"), QVariantMap{
                                                {QStringLiteral("requestId"), requestId},
                                                {QStringLiteral("surfaceId"), QStringLiteral("shell")},
                                                {QStringLiteral("x"), x},
                                                {QStringLiteral("y"), y},
                                                {QStringLiteral("items"), variants(items)},
                                            });
}

void MenuController::close() {
  if (!m_menu) return;
  m_menu.reset();
  m_bridge->publish(QStringLiteral("menu"), QVariant::fromValue(nullptr));
}

void MenuController::confirm(const QString& title, const QString& description, const QString& confirmLabel,
                             bool destructive, std::function<void()> accepted, std::function<void()> declined) {
  const QString requestId = QStringLiteral("confirm:%1").arg(m_nextId++);
  m_question = Question{requestId, std::move(accepted), std::move(declined)};
  m_bridge->publish(QStringLiteral("confirmation"), QVariantMap{
                                                        {QStringLiteral("requestId"), requestId},
                                                        {QStringLiteral("title"), title},
                                                        {QStringLiteral("description"), description},
                                                        {QStringLiteral("confirmLabel"), confirmLabel},
                                                        {QStringLiteral("destructive"), destructive},
                                                    });
}
