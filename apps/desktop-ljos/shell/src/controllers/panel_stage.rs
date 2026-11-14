//! The stage: right-panel tabs brought into a thread's centre, beside the
//! conversation (the panel keeps one per thread). It shows its tabs
//! in 1 to 4 panes, as one of four layouts: `single`, `columns` (side by side),
//! `rows` (stacked) and `grid` (2x2, panes numbered row by row). A pane shows one
//! of the stage's tabs or nothing (""), and a tab shows in one pane at most.
//! `focus` hides the conversation's timeline (the composer stays); `chat_width` is
//! the conversation's width beside the stage (0: the layout's default).
//!
//! A plain value: every change keeps it normal (normalize), so a stage with
//! tabs shows at least one, and one without tabs is closed (single, unfocused).
//! desktop-qt's PanelStage.h/.cpp.

use serde_json::json;

use crate::json::Json;

const SINGLE: &str = "single";
const COLUMNS: &str = "columns";
const ROWS: &str = "rows";
const GRID: &str = "grid";

pub const LAYOUTS: &[&str] = &[SINGLE, COLUMNS, ROWS, GRID];

fn columns_of(layout: &str) -> usize {
    if layout == COLUMNS || layout == GRID {
        2
    } else {
        1
    }
}

fn rows_of(layout: &str) -> usize {
    if layout == ROWS || layout == GRID {
        2
    } else {
        1
    }
}

/// How many panes `layout` has (an unknown one: 1).
pub fn pane_count(layout: &str) -> usize {
    columns_of(layout) * rows_of(layout)
}

#[derive(Clone, Debug, PartialEq)]
pub struct PanelStage {
    pub tabs: Vec<String>,
    pub panes: Vec<String>,
    pub layout: String,
    pub focused: i32,
    pub focus: bool,
    pub chat_width: i32,
}

impl Default for PanelStage {
    fn default() -> Self {
        PanelStage {
            tabs: Vec::new(),
            panes: vec![String::new()],
            layout: SINGLE.into(),
            focused: 0,
            focus: false,
            chat_width: 0,
        }
    }
}

impl PanelStage {
    pub fn is_empty(&self) -> bool {
        self.tabs.is_empty()
    }

    pub fn contains(&self, id: &str) -> bool {
        self.tabs.iter().any(|t| t == id)
    }

    /// The tab in the focused pane, or "".
    pub fn focused_tab(&self) -> &str {
        self.panes
            .get(usize::try_from(self.focused).unwrap_or(usize::MAX))
            .map_or("", String::as_str)
    }

    /// The tabs the panes show, the focused pane's first.
    pub fn shown(&self) -> Vec<String> {
        let mut ids = Vec::new();
        if !self.focused_tab().is_empty() {
            ids.push(self.focused_tab().to_owned());
        }
        for (pane, id) in self.panes.iter().enumerate() {
            if pane as i32 != self.focused && !id.is_empty() {
                ids.push(id.clone());
            }
        }
        ids
    }

    /// Adds `id` to the stage (if it is not there yet) and places it.
    pub fn add(&mut self, id: &str, pane: i32, zone: &str) {
        if id.is_empty() {
            return;
        }
        if !self.contains(id) {
            self.tabs.push(id.to_owned());
        }
        self.place(id, pane, zone);
    }

    /// Puts a stage tab in `pane` (-1: the focused one). `zone` "center" puts it
    /// in place of what the pane showed (which swaps with it when `id` showed in
    /// another pane); "left", "right", "top" or "bottom" splits the pane there
    /// when the layout has room to (single → columns or rows, columns or rows →
    /// grid), else replaces too. The pane it lands in is focused.
    pub fn place(&mut self, id: &str, pane: i32, zone: &str) {
        if !self.contains(id) {
            return;
        }
        let pane = if pane < 0 || pane as usize >= self.panes.len() {
            self.focused
        } else {
            pane
        };
        let pane = pane as usize;
        let columns = columns_of(&self.layout);
        let rows = rows_of(&self.layout);
        let across = zone == "left" || zone == "right";
        let down = zone == "top" || zone == "bottom";
        let from = self.panes.iter().position(|t| t == id);
        // A split needs room in that direction, and something else to split from.
        let split = ((across && columns == 1) || (down && rows == 1))
            && !(self.panes.len() == 1 && from == Some(pane));
        if !split {
            if let Some(from) = from
                && from != pane
            {
                self.panes[from] = self.panes[pane].clone();
            }
            self.panes[pane] = id.to_owned();
            self.focused = pane as i32;
            self.normalize();
            return;
        }
        if let Some(from) = from {
            self.panes[from].clear();
        }
        let next = if across {
            if rows == 1 { COLUMNS } else { GRID }
        } else if columns == 1 {
            ROWS
        } else {
            GRID
        };
        let next_columns = columns_of(next);
        let mut moved = vec![String::new(); pane_count(next)];
        let target_row = pane / columns;
        let target_column = pane % columns;
        for (index, shown) in self.panes.iter().enumerate() {
            let mut row = index / columns;
            let mut column = index % columns;
            // What the target pane showed moves aside for the tab.
            if across && row == target_row && zone == "left" {
                column = 1;
            }
            if down && column == target_column && zone == "top" {
                row = 1;
            }
            moved[row * next_columns + column] = shown.clone();
        }
        let row = if across {
            target_row
        } else if zone == "top" {
            0
        } else {
            1
        };
        let column = if down {
            target_column
        } else if zone == "left" {
            0
        } else {
            1
        };
        self.layout = next.into();
        self.panes = moved;
        self.focused = (row * next_columns + column) as i32;
        self.panes[self.focused as usize] = id.to_owned();
        self.normalize();
    }

    /// Shows a stage tab: focuses its pane, or puts it in the focused one.
    pub fn show(&mut self, id: &str) {
        if !self.contains(id) {
            return;
        }
        if let Some(pane) = self.panes.iter().position(|t| t == id) {
            self.focused = pane as i32;
        } else {
            self.panes[self.focused as usize] = id.to_owned();
        }
        self.normalize();
    }

    /// Takes `id` off the stage; its pane shows the next tab no pane shows.
    pub fn remove(&mut self, id: &str) -> bool {
        let Some(at) = self.tabs.iter().position(|t| t == id) else {
            return false;
        };
        self.tabs.remove(at);
        if let Some(pane) = self.panes.iter().position(|t| t == id) {
            self.panes[pane].clear();
            for tab in self.tabs.clone() {
                if !self.panes.contains(&tab) {
                    self.panes[pane] = tab;
                    break;
                }
            }
        }
        self.normalize();
        true
    }

    /// A tab that changed its id (the device picker becoming a device's tab).
    pub fn rename(&mut self, from: &str, to: &str) {
        if from == to || !self.contains(from) {
            return;
        }
        if self.contains(to) {
            self.remove(from);
            return;
        }
        let at = self.tabs.iter().position(|t| t == from).unwrap_or(0);
        self.tabs[at] = to.to_owned();
        if let Some(pane) = self.panes.iter().position(|t| t == from) {
            self.panes[pane] = to.to_owned();
        }
    }

    /// Another layout, keeping the focused tab and as many of the shown ones as
    /// fit; new panes show tabs no pane showed.
    pub fn set_layout(&mut self, next: &str) {
        if !LAYOUTS.contains(&next) || next == self.layout || self.tabs.is_empty() {
            return;
        }
        let mut order = self.shown();
        for tab in &self.tabs {
            if !order.contains(tab) {
                order.push(tab.clone());
            }
        }
        // The focused tab keeps its place when it fits, else takes the first pane.
        let kept = self.focused_tab().to_owned();
        let count = pane_count(next);
        let mut moved = vec![String::new(); count];
        let at = if (self.focused as usize) < count {
            self.focused as usize
        } else {
            0
        };
        if !kept.is_empty() {
            moved[at] = kept.clone();
        }
        // The other shown tabs keep their order around it.
        for (pane, tab) in self.panes.iter().enumerate() {
            if tab.is_empty() || *tab == kept {
                continue;
            }
            if pane < count && moved[pane].is_empty() {
                moved[pane] = tab.clone();
            }
        }
        for tab in &order {
            if moved.contains(tab) {
                continue;
            }
            let Some(empty) = moved.iter().position(String::is_empty) else {
                break;
            };
            moved[empty] = tab.clone();
        }
        self.layout = next.into();
        self.panes = moved;
        self.focused = at as i32;
        self.normalize();
    }

    pub fn focus_pane(&mut self, pane: i32) {
        if pane >= 0 && (pane as usize) < self.panes.len() {
            self.focused = pane;
        }
    }

    /// Back to a closed stage; the conversation's width is kept.
    pub fn clear(&mut self) {
        let width = self.chat_width;
        *self = PanelStage::default();
        self.chat_width = width;
    }

    pub fn normalize(&mut self) {
        if self.tabs.is_empty() {
            self.clear();
            return;
        }
        if !LAYOUTS.contains(&self.layout.as_str()) {
            self.layout = SINGLE.into();
        }
        let count = pane_count(&self.layout);
        while self.panes.len() < count {
            self.panes.push(String::new());
        }
        self.panes.truncate(count);
        let mut seen: Vec<String> = Vec::new();
        for tab in &mut self.panes {
            if !tab.is_empty() && (!self.tabs.contains(tab) || seen.contains(tab)) {
                tab.clear();
            }
            if !tab.is_empty() {
                seen.push(tab.clone());
            }
        }
        self.focused = self.focused.clamp(0, count as i32 - 1);
        if seen.is_empty() {
            self.panes[self.focused as usize] = self.tabs[0].clone();
        }
    }

    pub fn to_json(&self) -> Json {
        json!({
            "tabs": self.tabs,
            "panes": self.panes,
            "layout": self.layout,
            "focused": self.focused,
            "focus": self.focus,
            "chatWidth": self.chat_width,
        })
    }

    /// The stage saved by to_json, keeping only the tabs `known` accepts.
    pub fn from_json(json: &Json, known: impl Fn(&str) -> bool) -> PanelStage {
        let mut stage = PanelStage::default();
        for id in json
            .get("tabs")
            .and_then(Json::as_array)
            .into_iter()
            .flatten()
        {
            let id = id.as_str().unwrap_or("");
            if known(id) && !stage.tabs.iter().any(|t| t == id) {
                stage.tabs.push(id.to_owned());
            }
        }
        stage.panes = json
            .get("panes")
            .and_then(Json::as_array)
            .map(|panes| {
                panes
                    .iter()
                    .map(|id| id.as_str().unwrap_or("").to_owned())
                    .collect()
            })
            .unwrap_or_default();
        stage.layout = json
            .get("layout")
            .and_then(Json::as_str)
            .unwrap_or(SINGLE)
            .to_owned();
        stage.focused = json.get("focused").and_then(Json::as_i64).unwrap_or(0) as i32;
        stage.focus = json.get("focus").and_then(Json::as_bool).unwrap_or(false);
        stage.chat_width =
            (json.get("chatWidth").and_then(Json::as_i64).unwrap_or(0) as i32).max(0);
        stage.normalize();
        stage
    }

    /// What the RightPanel and Stage bricks read (tabs given as published).
    pub fn to_variant(&self, published: Vec<Json>) -> Json {
        json!({
            "tabs": published,
            "panes": self.panes,
            "layout": self.layout,
            "focusedPane": self.focused,
            "focus": self.focus,
            "chatWidth": self.chat_width,
        })
    }
}

#[cfg(test)]
mod tests {
    use proptest::prelude::*;

    use super::*;

    /// What every stage, after any sequence of moves, still is (the
    /// invariants desktop-qt's tst_RightPanelProp checks of its stage).
    fn normal(stage: &PanelStage) -> bool {
        let mut tabs = stage.tabs.clone();
        tabs.sort();
        tabs.dedup();
        if tabs.len() != stage.tabs.len() {
            return false;
        }
        if stage.tabs.is_empty() {
            return stage.layout == SINGLE
                && stage.panes == [String::new()]
                && !stage.focus
                && stage.focused == 0;
        }
        if stage.panes.len() != pane_count(&stage.layout)
            || stage.focused < 0
            || stage.focused as usize >= stage.panes.len()
        {
            return false;
        }
        let mut shown: Vec<&String> = stage.panes.iter().filter(|t| !t.is_empty()).collect();
        if shown.is_empty() || shown.iter().any(|t| !stage.tabs.contains(t)) {
            return false;
        }
        shown.sort();
        shown.dedup();
        shown.len() == stage.panes.iter().filter(|t| !t.is_empty()).count()
    }

    proptest! {
        #[test]
        fn any_sequence_of_moves_keeps_the_stage_normal(
            ops in proptest::collection::vec((0usize..8, 0usize..4, 0i32..5, 0usize..5), 0..40)
        ) {
            const IDS: [&str; 4] = ["diff", "files", "agents", "previews"];
            const ZONES: [&str; 5] = ["center", "left", "right", "top", "bottom"];
            let mut stage = PanelStage::default();
            for (op, tab, pane, zone) in ops {
                let id = IDS[tab];
                match op {
                    0 => stage.add(id, pane - 1, ZONES[zone]),
                    1 => stage.place(id, pane - 1, ZONES[zone]),
                    2 => stage.show(id),
                    3 => { stage.remove(id); }
                    4 => stage.rename(id, IDS[(tab + 1) % IDS.len()]),
                    5 => stage.set_layout(LAYOUTS[pane as usize % LAYOUTS.len()]),
                    6 => stage.focus_pane(pane),
                    _ => {
                        if !stage.is_empty() {
                            stage.focus = !stage.focus;
                        }
                    }
                }
                prop_assert!(normal(&stage), "after op {op}: {stage:?}");
                // What was saved comes back, normalising the same way.
                let kept = stage.tabs.clone();
                let back = PanelStage::from_json(&stage.to_json(), |id| kept.iter().any(|t| t == id));
                prop_assert_eq!(&back, &stage);
            }
        }
    }

    #[test]
    fn a_tab_dropped_at_an_edge_splits_the_pane() {
        let mut stage = PanelStage::default();
        stage.add("diff", -1, "center");
        stage.add("files", 0, "right");
        assert_eq!(stage.layout, "columns");
        assert_eq!(stage.panes, ["diff", "files"]);
        assert_eq!(stage.focused_tab(), "files");
    }

    #[test]
    fn removing_the_last_tab_closes_the_stage_but_keeps_the_width() {
        let mut stage = PanelStage::default();
        stage.add("diff", -1, "center");
        stage.chat_width = 720;
        stage.focus = true;
        assert!(stage.remove("diff"));
        assert!(stage.is_empty());
        assert!(!stage.focus);
        assert_eq!(stage.chat_width, 720);
    }

    #[test]
    fn a_layout_change_keeps_the_focused_tab_shown() {
        let mut stage = PanelStage::default();
        stage.add("diff", -1, "center");
        stage.add("files", 0, "right");
        stage.set_layout("single");
        assert_eq!(stage.panes.len(), 1);
        assert_eq!(stage.focused_tab(), "files");
        stage.set_layout("grid");
        assert_eq!(stage.panes.len(), 4);
        assert_eq!(stage.shown(), ["files", "diff"]);
    }
}
