//! Geometry checks on mmdr's layout for diagrams it once drew with overlapping parts.
//! They assert what a reader would call an overlap, not exact positions, so a layout
//! change that keeps the drawing legible still passes. Both themes run: they measure
//! text with different fonts and sizes, so they lay out differently.

use mermaid_rs_renderer::{Layout, RenderOptions, Theme, compute_layout, parse_mermaid_strict};

/// A rectangle as (left, top, right, bottom).
type Rect = (f32, f32, f32, f32);

fn layouts(source: &str) -> Vec<(&'static str, Layout)> {
    let parsed = parse_mermaid_strict(source).expect("the fixture parses");
    let options = RenderOptions::modern();
    [("light", options.theme.clone()), ("dark", Theme::dark())]
        .into_iter()
        .map(|(name, theme)| (name, compute_layout(&parsed.graph, &theme, &options.layout)))
        .collect()
}

fn overlap(a: Rect, b: Rect) -> bool {
    a.2.min(b.2) > a.0.max(b.0) && a.3.min(b.3) > a.1.max(b.1)
}

fn inside(a: Rect, b: Rect) -> bool {
    a.0 >= b.0 && a.1 >= b.1 && a.2 <= b.2 && a.3 <= b.3
}

/// Each edge's centre label box, with the edge's index.
fn label_boxes(layout: &Layout) -> Vec<(usize, String, Rect)> {
    layout
        .edges
        .iter()
        .enumerate()
        .filter_map(|(index, edge)| {
            let (label, (x, y)) = (edge.label.as_ref()?, edge.label_anchor?);
            let (w, h) = (label.width / 2.0, label.height / 2.0);
            Some((index, label.lines.join(" "), (x - w, y - h, x + w, y + h)))
        })
        .collect()
}

/// Whether the polyline passes through the rectangle's inside, sampled every pixel.
fn crosses(points: &[(f32, f32)], rect: Rect) -> bool {
    points.windows(2).any(|pair| {
        let ((x1, y1), (x2, y2)) = (pair[0], pair[1]);
        let steps = ((x2 - x1).abs().max((y2 - y1).abs()).ceil() as usize).max(1);
        (0..=steps).any(|step| {
            let t = step as f32 / steps as f32;
            let (x, y) = (x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
            x > rect.0 && x < rect.2 && y > rect.1 && y < rect.3
        })
    })
}

fn assert_labels_apart(source: &str) {
    for (theme, layout) in layouts(source) {
        let labels = label_boxes(&layout);
        for (i, (_, a, ra)) in labels.iter().enumerate() {
            for (_, b, rb) in &labels[i + 1..] {
                assert!(
                    !overlap(*ra, *rb),
                    "{theme}: labels {a:?} and {b:?} overlap"
                );
            }
        }
        for (index, text, rect) in &labels {
            let edge = &layout.edges[*index];
            if edge.from == edge.to {
                // The loop may run along the label's edge, not through its text.
                let inner = (rect.0 + 4.0, rect.1 + 4.0, rect.2 - 4.0, rect.3 - 4.0);
                assert!(
                    !crosses(&edge.points, inner),
                    "{theme}: the self-loop on {} runs through its label {text:?}",
                    edge.from
                );
            }
        }
    }
}

fn assert_nodes_in_their_own_boxes(source: &str) {
    for (theme, layout) in layouts(source) {
        let boxes: Vec<Rect> = layout
            .subgraphs
            .iter()
            .map(|s| (s.x, s.y, s.x + s.width, s.y + s.height))
            .collect();
        for node in layout.nodes.values().filter(|node| !node.hidden) {
            let rect = (node.x, node.y, node.x + node.width, node.y + node.height);
            for (sub, area) in layout.subgraphs.iter().zip(&boxes) {
                let member = sub.nodes.contains(&node.id);
                if member {
                    assert!(
                        inside(rect, *area),
                        "{theme}: {} is outside its box {:?}",
                        node.id,
                        sub.label
                    );
                } else {
                    assert!(
                        !overlap(rect, *area),
                        "{theme}: {} is drawn in {:?}, which does not hold it",
                        node.id,
                        sub.label
                    );
                }
            }
        }
        for (i, a) in boxes.iter().enumerate() {
            for (j, b) in boxes.iter().enumerate().skip(i + 1) {
                assert!(
                    !overlap(*a, *b) || inside(*a, *b) || inside(*b, *a),
                    "{theme}: boxes {:?} and {:?} overlap",
                    layout.subgraphs[i].label,
                    layout.subgraphs[j].label
                );
            }
        }
    }
}

#[test]
fn labels_of_parallel_state_edges_do_not_overlap() {
    // Routing seeded "cancel()" on "finished at the counter", and "price()" on the
    // "add_items()" coming back, and the self-loop's label sat on its own arrow.
    assert_labels_apart(
        "stateDiagram-v2
    [*] --> Draft: create()
    Draft --> Filled: add_items()
    Filled --> Filled: add_items()
    Filled --> Priced: price()
    Priced --> Filled: add_items()
    Draft --> Cancelled: cancel()
    Filled --> Cancelled: cancel()
    Filled --> Done: finished at the counter
    Cancelled --> [*]
    Done --> [*]
",
    );
}

#[test]
fn a_node_outside_a_nested_group_is_not_drawn_in_it() {
    // fetch_coupons belongs to Plugin but not to the nested Orders group, and was
    // ordered in among Orders' members, inside its box.
    assert_nodes_in_their_own_boxes(
        r#"graph LR
    subgraph Plugin["Plugin (plugin.py)"]
        FM[fetch_menu]
        GL[get_location]
        LL[list_locations]
        SO[submit_order]
        FC[fetch_coupons]
        subgraph Orders["Incremental Ordering"]
            OC[open_check]
            ACI[add_check_items]
            VCI[void_check_item]
            CC[calculate_check]
            CLC[close_check]
            GCS[get_check_status]
        end
    end
    subgraph Client["Client (client.py)"]
        GSM[get_store_menu]
        GS[get_stores]
        SS[submit_sale]
        GC[get_coupons]
    end
    Mapper["mapper.py<br/>convert_menu()"]
    Menu["Menu"]
    FM --> GSM --> Mapper --> Menu
    GL --> GS
    LL --> GS
    SO --> SS
    CLC --> SS
    FC --> GC
    subgraph Hooks["WebhookHandler"]
        PW[parse_webhook]
        VS[verify_signature]
    end
"#,
    );
}

#[test]
fn sibling_groups_with_edges_between_them_stay_apart() {
    assert_nodes_in_their_own_boxes(
        "flowchart LR
    subgraph app
        Plugin[VendorPlugin]
        Mapper[MenuMapper / CheckMapper]
    end
    subgraph sdk
        Client[VendorClient]
        OAuth[OAuth Token Manager]
        Schema[Pydantic Schema Models]
    end
    subgraph Cloud
        API[Vendor REST API]
        AuthServer[OAuth Server]
    end
    Plugin --> Mapper
    Plugin --> Client
    Client --> OAuth
    OAuth --> AuthServer
    Client --> API
    Mapper --> Schema
",
    );
}
