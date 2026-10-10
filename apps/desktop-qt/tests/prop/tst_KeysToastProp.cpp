// ToastController as a state machine: toasts shown, dismissed by code or by
// the user, timing out on a pinned clock, updated and replaced in place, their
// actions run by a click or by label (the undo shortcut), an action showing a
// toast of its own on the way, undo notices joining the newest toast of their
// group (which then counts the changes its one Undo takes back, newest first),
// and the stack expanded and collapsed (which holds every toast's time). After
// every step the published `toasts` is exactly the model's list, and no toast
// left it but by its time, a dismiss or an action: there is no cap.

#include "Prop.h"

#include "ShellBridge.h"
#include "ToastController.h"

#include <optional>
#include <vector>

namespace {

const QStringList kLabels{QStringLiteral("Undo"), QStringLiteral("Retry"), QStringLiteral("Open")};
const QStringList kGroups{QString(), QStringLiteral("Settled"), QStringLiteral("Snoozed")};
const QStringList kTypes{QStringLiteral("info"), QStringLiteral("error"), QStringLiteral("success")};
const QStringList kTexts{QString(), QStringLiteral("a"), QStringLiteral("b")};

// rc::gen::elementOf finds begin() by ADL alone, which a QList lacks.
template <typename T>
T pick(const QList<T>& pool) {
  return *rc::gen::elementOf(std::vector<T>(pool.cbegin(), pool.cend()));
}

struct ActionSpec {
  QString label;
  bool keepsToast = false;
  QString group;
  // Running it shows a toast titled "after <label>".
  bool follows = false;
  // The changes showUndo() joined onto it, newest first: it takes them back
  // before it runs itself.
  QStringList undoes;
  // False for the action showUndo() made, which only takes changes back.
  bool plain = true;

  // The changes its toast stands for.
  int count() const { return undoes.size() + (plain ? 1 : 0); }
};

void showValue(const ActionSpec& action, std::ostream& os) {
  os << action.label.toStdString() << (action.keepsToast ? " keeps" : "") << (action.group.isEmpty() ? "" : " ")
     << action.group.toStdString() << (action.follows ? " follows" : "") << (action.undoes.isEmpty() ? "" : " ")
     << action.undoes.join(QLatin1Char(',')).toStdString();
}

struct ModelToast {
  QString id;
  QString type;
  QString title;
  QString description;
  QList<ActionSpec> actions;
  // Running time, or while the stack is expanded the time it has left.
  std::optional<qint64> deadline;
  qint64 remaining = 0;
  int revision = 0;
};

struct Model {
  QList<ModelToast> toasts;  // newest first
  int nextId = 1;
  int undos = 0;  // showUndo() calls so far, which name their changes
  qint64 now = 0;
  bool expanded = false;
  // Every id that left the list, which never comes back.
  QStringList gone;
  // "<toast id>:<label>" per action run, in order.
  QStringList ran;
  QStringList closedByUser;

  qsizetype find(const QString& id) const {
    for (qsizetype i = 0; i < toasts.size(); ++i) {
      if (toasts.at(i).id == id) return i;
    }
    return -1;
  }
  void remove(qsizetype index) {
    gone.append(toasts.at(index).id);
    toasts.removeAt(index);
    if (toasts.isEmpty()) expanded = false;
  }
  void startTime(ModelToast& toast, int timeoutMs) const {
    toast.deadline.reset();
    toast.remaining = 0;
    if (timeoutMs <= 0) return;
    if (expanded) {
      toast.remaining = timeoutMs;
    } else {
      toast.deadline = now + timeoutMs;
    }
  }
  QString show(const QString& type, const QString& title, const QString& description, const QList<ActionSpec>& actions,
               int timeoutMs) {
    ModelToast toast{QStringLiteral("native:%1").arg(nextId++), type, title, description, actions};
    startTime(toast, timeoutMs);
    toasts.prepend(toast);
    return toast.id;
  }
  // A click on action `index` of toast `id`.
  void click(const QString& id, int index) {
    const qsizetype at = find(id);
    if (at < 0 || index >= toasts.at(at).actions.size()) return;
    const ActionSpec action = toasts.at(at).actions.at(index);
    if (!action.keepsToast) remove(at);
    for (const QString& change : action.undoes) ran.append(id + QLatin1Char(':') + change);
    if (!action.plain) return;
    ran.append(id + QLatin1Char(':') + action.label);
    if (action.follows) show(QStringLiteral("info"), QStringLiteral("after ") + action.label, {}, {}, 0);
  }
  // The notice of `change`, which the user can take back: onto the newest
  // toast when that offers Undo for the same group, else a toast of its own.
  QString showUndo(const QString& group, const QString& title, const QString& change) {
    ++undos;
    if (!toasts.isEmpty() && !toasts.first().actions.isEmpty() && toasts.first().actions.first().label == QLatin1String("Undo") &&
        toasts.first().actions.first().group == group) {
      ModelToast& newest = toasts.first();
      ActionSpec joined = newest.actions.first();
      joined.undoes.prepend(change);
      joined.keepsToast = false;
      newest.title = QStringLiteral("%1 %2 threads").arg(group).arg(joined.count());
      newest.description.clear();
      newest.actions = {joined};
      startTime(newest, 5000);
      ++newest.revision;
      return newest.id;
    }
    return show(QStringLiteral("success"), title, {}, {ActionSpec{QStringLiteral("Undo"), false, group, false, {change}, false}}, 5000);
  }
  void expire() {
    for (qsizetype i = toasts.size() - 1; i >= 0; --i) {
      if (toasts.at(i).deadline && *toasts.at(i).deadline <= now) remove(i);
    }
  }
  void setExpanded(bool to) {
    if (to == expanded) return;
    if (to) {
      expire();
      if (toasts.isEmpty()) return;
    }
    expanded = to;
    for (ModelToast& toast : toasts) {
      if (to && toast.deadline) {
        toast.remaining = *toast.deadline - now;
        toast.deadline.reset();
      } else if (!to && toast.remaining > 0) {
        toast.deadline = now + toast.remaining;
        toast.remaining = 0;
      }
    }
  }
  QStringList ids() const {
    QStringList list;
    for (const ModelToast& toast : toasts) list.append(toast.id);
    return list;
  }
};

struct Sut {
  ShellBridge bridge;
  ToastController toasts{&bridge, nullptr};
  qint64 now = 0;
  QStringList ran;
  QStringList closedByUser;
  QDateTime epoch = QDateTime::fromString(QStringLiteral("2026-09-23T10:00:00Z"), Qt::ISODate);

  Sut() {
    toasts.setClock([this] { return epoch.addMSecs(now); });
    QObject::connect(&toasts, &ToastController::closedByUser, &toasts, [this](const QString& id) { closedByUser.append(id); });
    toasts.activate();
  }

  QList<ToastController::Action> actions(const QList<ActionSpec>& specs) {
    QList<ToastController::Action> list;
    for (const ActionSpec& spec : specs) {
      list.append({spec.label,
                   [this, spec] {
                     ran.append(spec.label);
                     if (spec.follows) toasts.show(QStringLiteral("info"), QStringLiteral("after ") + spec.label, {}, {}, 0);
                   },
                   spec.keepsToast, spec.group});
    }
    return list;
  }
};

// What the Notifications brick reads for the model's toasts.
QVariantList published(const Model& model) {
  QVariantList items;
  for (const ModelToast& toast : model.toasts) {
    QVariantList actions;
    for (qsizetype index = std::min<qsizetype>(toast.actions.size(), 2) - 1; index >= 0; --index) {
      actions.append(QVariantMap{
          {QStringLiteral("id"), index == 0 ? QStringLiteral("primary") : QStringLiteral("secondary")},
          {QStringLiteral("label"), toast.actions.at(index).label},
          {QStringLiteral("primary"), index == 0},
      });
    }
    items.append(QVariantMap{
        {QStringLiteral("id"), toast.id},
        {QStringLiteral("type"), toast.type},
        {QStringLiteral("title"), toast.title},
        {QStringLiteral("description"),
         toast.description.isEmpty() ? QVariant::fromValue(nullptr) : QVariant(toast.description)},
        {QStringLiteral("updateKey"), toast.revision},
        {QStringLiteral("actions"), actions},
    });
  }
  return items;
}

QVariantMap publishedState(const Model& model) {
  return {{QStringLiteral("items"), published(model)}, {QStringLiteral("expanded"), model.expanded}};
}

void check(const Model& expected, Sut& sut) {
  RC_ASSERT(sut.bridge.state()->value(QStringLiteral("toasts")).toMap() == publishedState(expected));
  RC_ASSERT(sut.toasts.expanded() == expected.expanded);
  for (const QString& id : expected.ids()) RC_ASSERT(!expected.gone.contains(id));
  // Every toast ever shown is still up or went by its time, a dismiss or an
  // action (the model's only ways out).
  RC_ASSERT(expected.toasts.size() + expected.gone.size() == expected.nextId - 1);
  // An expanded stack holds every toast's time; a collapsed one runs it.
  for (const ModelToast& toast : expected.toasts) RC_ASSERT(!(expected.expanded && toast.deadline));
  for (const ModelToast& toast : expected.toasts) RC_ASSERT(expected.expanded || toast.remaining == 0);
  // The runs the model expects, by label (an id is the model's to check).
  QStringList labels;
  for (const QString& run : expected.ran) labels.append(run.section(QLatin1Char(':'), -1));
  RC_ASSERT(sut.ran == labels);
  RC_ASSERT(sut.closedByUser == expected.closedByUser);
}

using Command = rc::state::Command<Model, Sut>;

QString someId(const Model& model) {
  // Mostly a shown toast; now and then one long gone or never shown.
  QStringList pool = model.ids();
  pool.append(model.gone.mid(std::max<qsizetype>(0, model.gone.size() - 2)));
  pool.append(QStringLiteral("native:999"));
  return pick(pool);
}

QList<ActionSpec> someActions() {
  const int count = *rc::gen::inRange(0, 4);
  QList<ActionSpec> actions;
  for (int i = 0; i < count; ++i) {
    actions.append({pick(kLabels), *rc::gen::arbitrary<bool>(), pick(kGroups),
                    *rc::gen::weightedElement<bool>({{4, false}, {1, true}})});
  }
  return actions;
}

struct Show : Command {
  QString type = pick(kTypes);
  QString title = pick(kTexts);
  QString description = pick(kTexts);
  QList<ActionSpec> actions = someActions();
  int timeoutMs = pick(QList<int>{0, 1000, 5000});

  void apply(Model& model) const override { model.show(type, title, description, actions, timeoutMs); }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    const QString id = expected.show(type, title, description, actions, timeoutMs);
    RC_ASSERT(sut.toasts.showActions(type, title, description, sut.actions(actions), timeoutMs) == id);
    check(expected, sut);
  }
  void show(std::ostream& os) const override {
    os << "Show(" << type.toStdString() << ", \"" << title.toStdString() << "\", \"" << description.toStdString()
       << "\", ";
    rc::show(actions, os);
    os << ", " << timeoutMs << ")";
  }
};

struct Dismiss : Command {
  QString id;
  bool byUser;
  explicit Dismiss(const Model& model) : id(someId(model)), byUser(*rc::gen::arbitrary<bool>()) {}

  void apply(Model& model) const override {
    const qsizetype at = model.find(id);
    if (at < 0) return;
    model.remove(at);
    if (byUser) model.closedByUser.append(id);
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    if (byUser) {
      RC_ASSERT(sut.toasts.handle(QStringLiteral("notification.dismiss"), QVariantMap{{QStringLiteral("id"), id}}));
    } else {
      sut.toasts.dismiss(id);
    }
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << (byUser ? "UserDismiss(" : "Dismiss(") << id.toStdString() << ")"; }
};

struct Click : Command {
  QString id;
  int index;
  explicit Click(const Model& model) : id(someId(model)), index(*rc::gen::inRange(0, 2)) {}

  void apply(Model& model) const override { model.click(id, index); }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    sut.toasts.handle(QStringLiteral("notification.action"),
                      QVariantMap{{QStringLiteral("id"), id},
                                  {QStringLiteral("actionId"), index == 0 ? QStringLiteral("primary") : QStringLiteral("secondary")}});
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Click(" << id.toStdString() << ", " << index << ")"; }
};

struct Update : Command {
  QString id;
  QString title = pick(kTexts);
  QString description = pick(kTexts);
  explicit Update(const Model& model) : id(someId(model)) {}

  void apply(Model& model) const override {
    const qsizetype at = model.find(id);
    if (at < 0) return;
    ModelToast& toast = model.toasts[at];
    if (toast.title == title && toast.description == description) return;
    toast.title = title;
    toast.description = description;
    ++toast.revision;
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(sut.toasts.update(id, title, description) == (model.find(id) >= 0));
    check(expected, sut);
  }
  void show(std::ostream& os) const override {
    os << "Update(" << id.toStdString() << ", \"" << title.toStdString() << "\", \"" << description.toStdString() << "\")";
  }
};

struct Replace : Command {
  QString id;
  QString type = pick(kTypes);
  QString title = pick(kTexts);
  QList<ActionSpec> actions = someActions();
  int timeoutMs = pick(QList<int>{0, 1000});
  explicit Replace(const Model& model) : id(someId(model)) {}

  void apply(Model& model) const override {
    const qsizetype at = model.find(id);
    if (at < 0) return;
    ModelToast& toast = model.toasts[at];
    toast.type = type;
    toast.title = title;
    toast.description.clear();
    toast.actions = actions;
    model.startTime(toast, timeoutMs);
    ++toast.revision;
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(sut.toasts.replace(id, type, title, {}, sut.actions(actions), timeoutMs) == (model.find(id) >= 0));
    check(expected, sut);
  }
  void show(std::ostream& os) const override {
    os << "Replace(" << id.toStdString() << ", " << type.toStdString() << ", \"" << title.toStdString() << "\", ";
    rc::show(actions, os);
    os << ", " << timeoutMs << ")";
  }
};

// A thread settled, snoozed, archived or unpinned: the notice that offers to
// take it back.
struct ShowUndo : Command {
  QString group = pick(QStringList{QStringLiteral("Settled"), QStringLiteral("Snoozed")});
  QString title = pick(QStringList{QStringLiteral("a"), QStringLiteral("b")});
  QString change;
  explicit ShowUndo(const Model& model) : change(QStringLiteral("undo%1").arg(model.undos + 1)) {}

  void apply(Model& model) const override { model.showUndo(group, title, change); }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    const QString id = expected.showUndo(group, title, change);
    RC_ASSERT(sut.toasts.showUndo(group, title, [&sut, change = change] { sut.ran.append(change); }) == id);
    check(expected, sut);
  }
  void show(std::ostream& os) const override {
    os << "ShowUndo(" << group.toStdString() << ", \"" << title.toStdString() << "\", " << change.toStdString() << ")";
  }
};

// The undo shortcut: the newest toast offering `label`, and the ones right
// after it offering it for the same group.
struct RunAction : Command {
  QString label = pick(kLabels);

  QList<std::pair<QString, int>> chosen(const Model& model) const {
    QList<std::pair<QString, int>> picks;
    QString group;
    for (const ModelToast& toast : model.toasts) {
      int found = -1;
      for (int i = 0; i < std::min<int>(toast.actions.size(), 2) && found < 0; ++i) {
        if (toast.actions.at(i).label == label) found = i;
      }
      if (found < 0) {
        if (picks.isEmpty()) continue;
        break;
      }
      const QString& its = toast.actions.at(found).group;
      if (!picks.isEmpty() && (group.isEmpty() || its != group)) break;
      group = its;
      picks.append({toast.id, found});
    }
    return picks;
  }
  void apply(Model& model) const override {
    for (const auto& [id, index] : chosen(model)) model.click(id, index);
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(sut.toasts.runAction(label) == !chosen(model).isEmpty());
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "RunAction(" << label.toStdString() << ")"; }
};

// The pointer enters or leaves the stack (or a tap opens or closes it on a
// phone): the brick's `notification.expand`.
struct Expand : Command {
  bool expanded = *rc::gen::arbitrary<bool>();

  void apply(Model& model) const override { model.setExpanded(expanded); }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    RC_ASSERT(sut.toasts.handle(QStringLiteral("notification.expand"),
                                QVariantMap{{QStringLiteral("expanded"), expanded}}));
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << (expanded ? "Expand" : "Collapse"); }
};

// Time passes; the timer's expire() runs, as it would at the deadline.
struct Advance : Command {
  int ms = pick(QList<int>{1, 500, 999, 1000, 4000, 5000});

  void apply(Model& model) const override {
    model.now += ms;
    model.expire();
  }
  void run(const Model& model, Sut& sut) const override {
    Model expected = model;
    apply(expected);
    sut.now += ms;
    sut.toasts.expire();
    check(expected, sut);
  }
  void show(std::ostream& os) const override { os << "Advance(" << ms << ")"; }
};

}  // namespace

class KeysToastProp : public QObject {
  Q_OBJECT

private slots:
  void toasts() {
    QVERIFY(rc::check("toasts publish what the model holds", [] {
      Sut sut;
      rc::state::check(Model{}, sut,
                       rc::state::gen::execOneOfWithArgs<Show, Show, Show, ShowUndo, ShowUndo, Dismiss, Click, Update,
                                                                Replace, RunAction, Expand, Advance, Advance>());
    }));
  }
};

HAL_C2_PROP_MAIN(KeysToastProp)
#include "tst_KeysToastProp.moc"
