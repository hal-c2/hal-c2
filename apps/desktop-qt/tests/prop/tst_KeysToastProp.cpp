// ToastController as a state machine: toasts shown, dismissed by code or by
// the user, timing out on a pinned clock, updated and replaced in place, and
// their actions run by a click or by label (the undo shortcut), an action
// showing a toast of its own on the way. After every step the published
// `toasts` is exactly the model's list.

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
constexpr qsizetype kMaxToasts = 5;

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
};

void showValue(const ActionSpec& action, std::ostream& os) {
  os << action.label.toStdString() << (action.keepsToast ? " keeps" : "") << (action.group.isEmpty() ? "" : " ")
     << action.group.toStdString() << (action.follows ? " follows" : "");
}

struct ModelToast {
  QString id;
  QString type;
  QString title;
  QString description;
  QList<ActionSpec> actions;
  std::optional<qint64> deadline;
  int revision = 0;
};

struct Model {
  QList<ModelToast> toasts;  // newest first
  int nextId = 1;
  qint64 now = 0;
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
  }
  QString show(const QString& type, const QString& title, const QString& description, const QList<ActionSpec>& actions,
               int timeoutMs) {
    ModelToast toast{QStringLiteral("native:%1").arg(nextId++), type, title, description, actions, {}, 0};
    if (timeoutMs > 0) toast.deadline = now + timeoutMs;
    toasts.prepend(toast);
    while (toasts.size() > kMaxToasts) remove(toasts.size() - 1);
    return toast.id;
  }
  // A click on action `index` of toast `id`.
  void click(const QString& id, int index) {
    const qsizetype at = find(id);
    if (at < 0 || index >= toasts.at(at).actions.size()) return;
    const ActionSpec action = toasts.at(at).actions.at(index);
    if (!action.keepsToast) remove(at);
    ran.append(id + QLatin1Char(':') + action.label);
    if (action.follows) show(QStringLiteral("info"), QStringLiteral("after ") + action.label, {}, {}, 0);
  }
  void expire() {
    for (qsizetype i = toasts.size() - 1; i >= 0; --i) {
      if (toasts.at(i).deadline && *toasts.at(i).deadline <= now) remove(i);
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

void check(const Model& expected, Sut& sut) {
  const QVariantList items =
      sut.bridge.state()->value(QStringLiteral("toasts")).toMap().value(QStringLiteral("items")).toList();
  RC_ASSERT(items == published(expected));
  for (const QString& id : expected.ids()) RC_ASSERT(!expected.gone.contains(id));
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
    toast.deadline = timeoutMs > 0 ? std::optional(model.now + timeoutMs) : std::nullopt;
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
                       rc::state::gen::execOneOfWithArgs<Show, Show, Dismiss, Click, Update, Replace, RunAction, Advance>());
    }));
  }
};

HAL_C2_PROP_MAIN(KeysToastProp)
#include "tst_KeysToastProp.moc"
