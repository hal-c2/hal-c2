#pragma once

#include <QList>
#include <QObject>
#include <QString>
#include <QVariant>

#include <functional>
#include <optional>

#include "NativeController.h"

class McClient;
class ShellBridge;

// The shell's one context menu and one confirmation question. A controller
// opens a menu of Items at window coordinates with the function that runs the
// chosen id, and asks a question with the function that runs on yes; the
// ContextMenuHost and ConfirmDialog bricks render them from `menu` and
// `confirmation`.
//
// `menu` is {requestId, surfaceId: "shell", x, y, items}, each item {id,
// label, icon, enabled, checked, destructive, separatorBefore, children};
// `menu.select {requestId, id}` picks (a null id dismisses). `confirmation`
// is {requestId, title, description, confirmLabel, destructive};
// `confirmation.answer {requestId, accepted}` answers it. A newer menu or
// question replaces the open one, which is then dismissed.
class MenuController : public QObject, public NativeController {
  Q_OBJECT

public:
  struct Item {
    QString id;
    QString label;
    QString icon;
    bool enabled = true;
    bool checked = false;
    bool destructive = false;
    bool separatorBefore = false;
    QList<Item> children;
  };
  using Chosen = std::function<void(const QString& id)>;

  MenuController(ShellBridge* bridge, McClient* client, QObject* parent = nullptr);

  void activate() override {}
  bool handle(const QString& action, const QVariant& payload) override;

  // Shows `items` at (x, y); `chosen` runs with the id picked, never on dismiss.
  void open(double x, double y, const QList<Item>& items, Chosen chosen);
  void close();
  // Asks; `accepted` runs on yes only, `declined` (when given) on no.
  void confirm(const QString& title, const QString& description, const QString& confirmLabel, bool destructive,
               std::function<void()> accepted, std::function<void()> declined = {});

private:
  ShellBridge* m_bridge;
  int m_nextId = 1;
  struct Open {
    QString requestId;
    Chosen chosen;
  };
  std::optional<Open> m_menu;
  struct Question {
    QString requestId;
    std::function<void()> accepted;
    std::function<void()> declined;
  };
  std::optional<Question> m_question;
};
