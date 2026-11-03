#include "PanelStage.h"

#include <QJsonArray>

#include <algorithm>

namespace {

const QString kSingle = QStringLiteral("single");
const QString kColumns = QStringLiteral("columns");
const QString kRows = QStringLiteral("rows");
const QString kGrid = QStringLiteral("grid");

int columnsOf(const QString& layout) {
  return layout == kColumns || layout == kGrid ? 2 : 1;
}

int rowsOf(const QString& layout) {
  return layout == kRows || layout == kGrid ? 2 : 1;
}

}  // namespace

const QStringList PanelStage::layouts{kSingle, kColumns, kRows, kGrid};

int PanelStage::paneCount(const QString& layout) {
  return columnsOf(layout) * rowsOf(layout);
}

QStringList PanelStage::shown() const {
  QStringList ids;
  if (!focusedTab().isEmpty()) ids.append(focusedTab());
  for (qsizetype pane = 0; pane < panes.size(); ++pane) {
    if (pane != focused && !panes.at(pane).isEmpty()) ids.append(panes.at(pane));
  }
  return ids;
}

void PanelStage::add(const QString& id, int pane, const QString& zone) {
  if (id.isEmpty()) return;
  if (!tabs.contains(id)) tabs.append(id);
  place(id, pane, zone);
}

void PanelStage::place(const QString& id, int pane, const QString& zone) {
  if (!tabs.contains(id)) return;
  timeline = false;
  if (pane < 0 || pane >= panes.size()) pane = focused;
  const int columns = columnsOf(layout);
  const int rows = rowsOf(layout);
  const bool across = zone == QLatin1String("left") || zone == QLatin1String("right");
  const bool down = zone == QLatin1String("top") || zone == QLatin1String("bottom");
  const qsizetype from = panes.indexOf(id);
  // A split needs room in that direction, and something else to split from.
  const bool split = ((across && columns == 1) || (down && rows == 1)) && !(panes.size() == 1 && from == pane);
  if (!split) {
    if (from >= 0 && from != pane) panes[from] = panes.at(pane);
    panes[pane] = id;
    focused = pane;
    normalize();
    return;
  }
  if (from >= 0) panes[from].clear();
  const QString next = across ? (rows == 1 ? kColumns : kGrid) : (columns == 1 ? kRows : kGrid);
  const int nextColumns = columnsOf(next);
  QStringList moved(paneCount(next));
  const int targetRow = pane / columns;
  const int targetColumn = pane % columns;
  for (qsizetype index = 0; index < panes.size(); ++index) {
    int row = int(index) / columns;
    int column = int(index) % columns;
    // What the target pane showed moves aside for the tab.
    if (across && row == targetRow && zone == QLatin1String("left")) column = 1;
    if (down && column == targetColumn && zone == QLatin1String("top")) row = 1;
    moved[row * nextColumns + column] = panes.at(index);
  }
  const int row = across ? targetRow : (zone == QLatin1String("top") ? 0 : 1);
  const int column = down ? targetColumn : (zone == QLatin1String("left") ? 0 : 1);
  layout = next;
  panes = moved;
  focused = row * nextColumns + column;
  panes[focused] = id;
  normalize();
}

void PanelStage::show(const QString& id) {
  if (!tabs.contains(id)) return;
  timeline = false;
  const qsizetype pane = panes.indexOf(id);
  if (pane >= 0) {
    focused = int(pane);
  } else {
    panes[focused] = id;
  }
  normalize();
}

bool PanelStage::remove(const QString& id) {
  if (!tabs.removeOne(id)) return false;
  const qsizetype pane = panes.indexOf(id);
  if (pane >= 0) {
    panes[pane].clear();
    for (const QString& tab : std::as_const(tabs)) {
      if (!panes.contains(tab)) {
        panes[pane] = tab;
        break;
      }
    }
  }
  normalize();
  return true;
}

void PanelStage::rename(const QString& from, const QString& to) {
  if (from == to || !tabs.contains(from)) return;
  if (tabs.contains(to)) {
    remove(from);
    return;
  }
  tabs[tabs.indexOf(from)] = to;
  const qsizetype pane = panes.indexOf(from);
  if (pane >= 0) panes[pane] = to;
}

void PanelStage::setLayout(const QString& next) {
  if (!layouts.contains(next) || tabs.isEmpty()) return;
  timeline = false;
  if (next == layout) return;
  QStringList order = shown();
  for (const QString& tab : std::as_const(tabs)) {
    if (!order.contains(tab)) order.append(tab);
  }
  // The focused tab keeps its place when it fits, else takes the first pane.
  const QString kept = focusedTab();
  const int count = paneCount(next);
  QStringList moved(count);
  int at = focused < count ? focused : 0;
  if (!kept.isEmpty()) moved[at] = kept;
  // The other shown tabs keep their order around it.
  for (qsizetype pane = 0; pane < panes.size(); ++pane) {
    const QString& tab = panes.at(pane);
    if (tab.isEmpty() || tab == kept) continue;
    if (pane < count && moved.at(pane).isEmpty()) moved[pane] = tab;
  }
  for (const QString& tab : std::as_const(order)) {
    if (moved.contains(tab)) continue;
    const qsizetype empty = moved.indexOf(QString());
    if (empty < 0) break;
    moved[empty] = tab;
  }
  layout = next;
  panes = moved;
  focused = at;
  normalize();
}

void PanelStage::focusPane(int pane) {
  if (pane >= 0 && pane < panes.size()) focused = pane;
}

void PanelStage::clear() {
  const int width = chatWidth;
  *this = PanelStage();
  chatWidth = width;
}

void PanelStage::normalize() {
  if (tabs.isEmpty()) return clear();
  if (!layouts.contains(layout)) layout = kSingle;
  const int count = paneCount(layout);
  while (panes.size() < count) panes.append(QString());
  while (panes.size() > count) panes.removeLast();
  QStringList seen;
  for (QString& tab : panes) {
    if (!tab.isEmpty() && (!tabs.contains(tab) || seen.contains(tab))) tab.clear();
    if (!tab.isEmpty()) seen.append(tab);
  }
  focused = std::clamp(focused, 0, count - 1);
  if (seen.isEmpty()) panes[focused] = tabs.first();
  timeline = timeline && focus;
}

QJsonObject PanelStage::toJson() const {
  return {{QStringLiteral("tabs"), QJsonArray::fromStringList(tabs)},
          {QStringLiteral("panes"), QJsonArray::fromStringList(panes)},
          {QStringLiteral("layout"), layout},
          {QStringLiteral("focused"), focused},
          {QStringLiteral("focus"), focus},
          {QStringLiteral("timeline"), timeline},
          {QStringLiteral("chatWidth"), chatWidth}};
}

PanelStage PanelStage::fromJson(const QJsonObject& json, const std::function<bool(const QString&)>& known) {
  PanelStage stage;
  for (const QJsonValue& id : json.value(QLatin1String("tabs")).toArray()) {
    if (known(id.toString()) && !stage.tabs.contains(id.toString())) stage.tabs.append(id.toString());
  }
  stage.panes.clear();
  for (const QJsonValue& id : json.value(QLatin1String("panes")).toArray()) stage.panes.append(id.toString());
  stage.layout = json.value(QLatin1String("layout")).toString(kSingle);
  stage.focused = json.value(QLatin1String("focused")).toInt();
  stage.focus = json.value(QLatin1String("focus")).toBool();
  stage.timeline = json.value(QLatin1String("timeline")).toBool();
  stage.chatWidth = std::max(0, json.value(QLatin1String("chatWidth")).toInt());
  stage.normalize();
  return stage;
}

QVariantMap PanelStage::toVariant(const QVariantList& published) const {
  return {{QStringLiteral("tabs"), published},
          {QStringLiteral("panes"), panes},
          {QStringLiteral("layout"), layout},
          {QStringLiteral("focusedPane"), focused},
          {QStringLiteral("focus"), focus},
          {QStringLiteral("timeline"), timeline},
          {QStringLiteral("chatWidth"), chatWidth}};
}
