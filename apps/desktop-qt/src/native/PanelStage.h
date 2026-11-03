#pragma once

#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <QVariantMap>

#include <functional>

// The stage: right-panel tabs brought into a thread's centre, beside the
// conversation (RightPanelController keeps one per thread). It shows its tabs
// in 1 to 4 panes, as one of four layouts: `single`, `columns` (side by side),
// `rows` (stacked) and `grid` (2x2, panes numbered row by row). A pane shows one
// of the stage's tabs or nothing (""), and a tab shows in one pane at most.
// `focus` shows the stage across the thread's centre, over the composer, in
// place of the conversation beside it; `timeline` (with `focus` only) is the
// strip's Timeline tab chosen, the timeline under the strip in place of the
// panes. Showing, placing or laying out a tab chooses the panes again.
// `chatWidth` is the conversation's width beside the stage (0: the layout's
// default).
//
// A plain value: every change keeps it normal (normalize), so a stage with
// tabs shows at least one, and one without tabs is closed (single, unfocused).
struct PanelStage {
  QStringList tabs;
  QStringList panes{QString()};
  QString layout = QStringLiteral("single");
  int focused = 0;
  bool focus = false;
  bool timeline = false;
  int chatWidth = 0;

  static const QStringList layouts;
  // How many panes `layout` has (an unknown one: 1).
  static int paneCount(const QString& layout);

  bool isEmpty() const { return tabs.isEmpty(); }
  bool contains(const QString& id) const { return tabs.contains(id); }
  // The timeline is put away: the panes fill the centre.
  bool timelineHidden() const { return focus && !timeline; }
  // The tab in the focused pane, or "".
  QString focusedTab() const { return panes.value(focused); }
  // The tabs the panes show, the focused pane's first.
  QStringList shown() const;

  // Adds `id` to the stage (if it is not there yet) and places it.
  void add(const QString& id, int pane = -1, const QString& zone = QStringLiteral("center"));
  // Puts a stage tab in `pane` (-1: the focused one). `zone` "center" puts it
  // in place of what the pane showed (which swaps with it when `id` showed in
  // another pane); "left", "right", "top" or "bottom" splits the pane there
  // when the layout has room to (single → columns or rows, columns or rows →
  // grid), else replaces too. The pane it lands in is focused.
  void place(const QString& id, int pane = -1, const QString& zone = QStringLiteral("center"));
  // Shows a stage tab: focuses its pane, or puts it in the focused one.
  void show(const QString& id);
  // Takes `id` off the stage; its pane shows the next tab no pane shows.
  bool remove(const QString& id);
  // A tab that changed its id (the device picker becoming a device's tab).
  void rename(const QString& from, const QString& to);
  // Another layout (or the same, shown), keeping the focused tab and as many
  // of the shown ones as fit; new panes show tabs no pane showed.
  void setLayout(const QString& layout);
  void focusPane(int pane);
  // Back to a closed stage; the conversation's width is kept.
  void clear();
  void normalize();

  QJsonObject toJson() const;
  // The stage saved by toJson, keeping only the tabs `known` accepts.
  static PanelStage fromJson(const QJsonObject& json, const std::function<bool(const QString&)>& known);
  // What the RightPanel and Stage bricks read (tabs given as published).
  QVariantMap toVariant(const QVariantList& tabs) const;

  bool operator==(const PanelStage&) const = default;
};
