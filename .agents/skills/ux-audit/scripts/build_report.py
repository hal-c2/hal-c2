#!/usr/bin/env python3
"""Build the HTML audit report from an audit dir's findings.jsonl and coverage.jsonl.

Usage:
  build_report.py --dir AUDIT_DIR [--title "..."] [--env "..."]
Writes AUDIT_DIR/report/index.html and copies the referenced screenshots into
AUDIT_DIR/report/shots. Prints every screenshot it could not find.
"""

from __future__ import annotations

import argparse
import html
import json
import shutil
from collections import Counter, defaultdict
from pathlib import Path

SEV_ORDER = ["high", "medium", "low", "info", "ok"]
SEV_LABEL = {"high": "High", "medium": "Medium", "low": "Low", "info": "Info", "ok": "OK as-is"}
SEV_CLASS = {
    "high": "bg-red-100 text-red-800 ring-red-200",
    "medium": "bg-amber-100 text-amber-800 ring-amber-200",
    "low": "bg-sky-100 text-sky-800 ring-sky-200",
    "info": "bg-slate-100 text-slate-700 ring-slate-200",
    "ok": "bg-emerald-100 text-emerald-800 ring-emerald-200",
}
LEGEND = (
    "<b>High</b> = blocks or misleads a task, shows the user internals they cannot act on, or loses work; "
    "<b>Medium</b> = clear usability cost, workaround exists; <b>Low</b> = polish / consistency; "
    "<b>Info</b> = observation; <b>OK as-is</b> = reviewed and justified."
)
# The checklist's areas. A coverage row counts for the area its "area" starts with, so an
# area nobody opened shows up as a gap instead of passing silently.
REQUIRED_AREAS = [
    "Shell and header",
    "Sidebar",
    "Home and centre",
    "Timeline",
    "Live turn",
    "Composer",
    "Right panel › Diff",
    "Right panel › Files",
    "Right panel › Agents",
    "Right panel › Previews",
    "Right panel › Device",
    "Right panel › Pull requests",
    "Terminal",
    "Command palette",
    "Settings",
    "Dialogs and toasts",
    "Connection and errors",
    "Keyboard",
]
E = html.escape


def _list(v) -> list:
    if v is None or v == "":
        return []
    return v if isinstance(v, list) else [v]


def _jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    with path.open(encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def shot_name(s) -> str:
    """A shot as its file name in shots/; a bare name gets the .png that ux shot writes."""
    name = Path(str(s)).name
    return name if Path(name).suffix else f"{name}.png"


def load_findings(path: Path) -> list[dict]:
    rows, seen = [], set()
    for r in _jsonl(path):
        # A resumed audit appends to the log; a repeated id would collapse two
        # findings onto one card here and one sub-issue in github_issues.py.
        if r["id"] in seen:
            raise ValueError(f"finding {r['id']!r} appears more than once in {path}")
        seen.add(r["id"])
        sev = str(r.get("sev", "info")).lower()
        # A typo such as "hihg" must not silently downgrade a finding.
        if sev not in SEV_ORDER:
            raise ValueError(f"finding {r['id']!r}: sev {sev!r} is not one of {'|'.join(SEV_ORDER)}")
        why_ok = r.get("why_ok") or ""
        # Every item judged fine says why; a bare "ok" publishes an unexplained pass.
        if sev == "ok" and not str(why_ok).strip():
            raise ValueError(f"finding {r['id']!r}: sev 'ok' needs a why_ok")
        rows.append(
            {
                "id": r["id"],
                "sev": sev,
                "area": r.get("area") or "General",
                "title": r.get("title", r["id"]),
                "desc": r.get("desc") or "",
                "evidence": r.get("evidence"),
                "shots": [shot_name(s) for s in _list(r.get("shots"))],
                "where": _list(r.get("where")),
                "ledger": _list(r.get("ledger")),
                "solutions": _list(r.get("solutions")),
                "why_ok": why_ok,
                "fixed": r.get("fixed") or "",
                "related": _list(r.get("related")),
            }
        )
    return rows


def badge(sev: str) -> str:
    return f'<span class="inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-semibold ring-1 ring-inset {SEV_CLASS[sev]}">{SEV_LABEL[sev]}</span>'


def figure(shot: str) -> str:
    return (
        f'<figure class="min-w-0"><a href="shots/{E(shot)}" target="_blank" rel="noopener" class="block overflow-hidden rounded-lg border border-slate-200 bg-slate-50">'
        f'<img src="shots/{E(shot)}" loading="lazy" alt="{E(shot)}" class="h-56 w-full object-contain object-top"></a>'
        f'<figcaption class="mt-1 truncate font-mono text-[11px] text-slate-500" title="{E(shot)}">{E(shot)}</figcaption></figure>'
    )


def chips(label: str, items: list, link: bool = False) -> str:
    if not items:
        return ""
    if link:
        body = ", ".join(f'<a class="text-indigo-700 hover:underline" href="#{E(i)}">{E(i)}</a>' for i in items)
    else:
        body = " · ".join(f'<code class="rounded bg-slate-100 px-1 py-0.5">{E(str(i))}</code>' for i in items)
    return f'<div class="mt-2 text-xs text-slate-600"><span class="font-semibold">{label}:</span> {body}</div>'


def card(f: dict) -> str:
    head = f'<a href="#{f["id"]}" class="font-mono text-sm text-slate-400 hover:text-slate-700">{f["id"]}</a>{badge(f["sev"])}'
    if f["fixed"]:
        head += '<span class="inline-flex items-center rounded-full bg-violet-100 px-2.5 py-0.5 text-xs font-semibold text-violet-800 ring-1 ring-inset ring-violet-200">Fixed</span>'
    head += f'<span class="text-xs text-slate-500">{E(f["area"])}</span>'
    parts = [
        f'<article id="{f["id"]}" class="scroll-mt-24 rounded-xl border border-slate-200 bg-white p-5 shadow-sm">',
        f'<div class="flex flex-wrap items-center gap-2">{head}</div>',
        f'<h4 class="mt-2 text-lg font-semibold leading-snug text-slate-900">{E(f["title"])}</h4>',
    ]
    if f["desc"]:
        parts.append(f'<p class="mt-2 whitespace-pre-line text-sm leading-relaxed text-slate-700">{E(f["desc"])}</p>')
    if f["evidence"]:
        ev = f["evidence"] if isinstance(f["evidence"], str) else json.dumps(f["evidence"], indent=1, ensure_ascii=False)
        parts.append(
            f'<details class="mt-2"><summary class="cursor-pointer text-xs font-medium text-slate-500">Evidence</summary><pre class="mt-1 overflow-x-auto rounded bg-slate-900 p-3 text-xs text-slate-100">{E(ev)}</pre></details>'
        )
    if f["shots"]:
        parts.append('<div class="mt-3 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">' + "".join(figure(s) for s in f["shots"]) + "</div>")
    parts += [chips("Where", f["where"]), chips("Ledger", f["ledger"]), chips("Related", f["related"], link=True)]
    if f["fixed"]:
        parts.append(f'<div class="mt-3 rounded-lg border border-violet-200 bg-violet-50 p-3 text-sm text-violet-900"><span class="font-semibold">Fixed:</span> {E(str(f["fixed"]))}</div>')
    if f["why_ok"]:
        parts.append(f'<div class="mt-3 rounded-lg border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-900"><span class="font-semibold">Why it is fine as it is:</span> {E(f["why_ok"])}</div>')
    if f["solutions"]:
        parts.append(
            '<div class="mt-3"><div class="text-sm font-semibold text-slate-900">Possible solutions</div><ol class="mt-1 list-decimal space-y-1 pl-5 text-sm text-slate-700">'
            + "".join(f"<li>{E(str(s))}</li>" for s in f["solutions"])
            + "</ol></div>"
        )
    parts.append("</article>")
    return "\n".join(p for p in parts if p)


def table(headers: list[str], rows: list[list[str]]) -> str:
    th = "".join(f'<th class="px-3 py-2 text-left text-xs font-semibold uppercase tracking-wide text-slate-500">{h}</th>' for h in headers)
    trs = "".join(
        '<tr class="border-t border-slate-100">' + "".join(f'<td class="px-3 py-2 align-top">{c}</td>' for c in r) + "</tr>" for r in rows
    )
    return f'<div class="mt-3 overflow-x-auto rounded-xl border border-slate-200 bg-white"><table class="min-w-full text-sm"><thead class="bg-slate-50"><tr>{th}</tr></thead><tbody>{trs}</tbody></table></div>'


def _size_key(size: str) -> tuple:
    try:
        w, h = size.split("x")
        return (-int(w), -int(h))
    except ValueError:
        return (0, 0)


def unvisited(coverage: list[dict]) -> list[str]:
    # A skipped row is a reported gap with a reason; it is listed under "Not covered".
    seen = [r["area"].lower() for r in coverage]
    return [a for a in REQUIRED_AREAS if not any(s.startswith(a.lower()) for s in seen)]


def coverage_section(coverage: list[dict]) -> str:
    if not coverage:
        return "<p class='mt-3 text-sm text-slate-600'>No coverage recorded.</p>"
    seen = [r for r in coverage if not r.get("skipped")]
    skipped = [r for r in coverage if r.get("skipped")]
    areas = list(dict.fromkeys(r["area"] for r in coverage))
    sizes = sorted({r.get("size", "?") for r in seen}, key=_size_key)
    cells: dict[tuple, list] = defaultdict(list)
    for r in seen:
        cells[(r["area"], r.get("size", "?"))].append(r)
    rows = []
    for area in areas:
        row = [E(area)]
        for size in sizes:
            links = [
                f'<a class="text-indigo-700 hover:underline" href="shots/{E(shot_name(r["shot"]))}" target="_blank">{E(r.get("appearance", "?"))}</a>'
                if r.get("shot")
                else E(r.get("appearance", "?"))
                for r in cells[(area, size)]
            ]
            row.append(" ".join(links) or '<span class="text-slate-400">–</span>')
        rows.append(row)
    out = table(["Area"] + [E(s) for s in sizes], rows)
    gaps = unvisited(coverage)
    if gaps:
        out += '<h3 class="mt-6 text-lg font-semibold text-red-700">Checklist areas never visited</h3><ul class="mt-2 list-disc pl-6 text-sm">' + "".join(
            f"<li>{E(a)}</li>" for a in gaps
        ) + "</ul>"
    if skipped:
        out += '<h3 class="mt-6 text-lg font-semibold">Not covered</h3>' + table(
            ["Area", "Reason"], [[E(r["area"]), E(r["skipped"])] for r in skipped]
        )
    return out


def build(args) -> None:
    root = Path(args.dir)
    findings = load_findings(root / "findings.jsonl")
    coverage = _jsonl(root / "coverage.jsonl")
    out = root / "report"
    shots_out = out / "shots"
    # Only evidence the current logs reference: a stale copy from an earlier build must not hide a missing shot.
    shutil.rmtree(shots_out, ignore_errors=True)
    shots_out.mkdir(parents=True)
    wanted = {s for f in findings for s in f["shots"]} | {shot_name(r["shot"]) for r in coverage if r.get("shot")}
    missing = []
    for s in sorted(wanted):
        src = root / "shots" / s
        if src.exists():
            shutil.copy2(src, shots_out / s)
        else:
            missing.append(s)

    counts = Counter(f["sev"] for f in findings)
    issues = sorted((f for f in findings if f["sev"] != "ok"), key=lambda f: (SEV_ORDER.index(f["sev"]), f["id"]))
    oks = [f for f in findings if f["sev"] == "ok"]
    by_area: dict[str, list] = defaultdict(list)
    for f in issues:
        by_area[f["area"].split(" › ")[0]].append(f)

    def sec(id_, title, body):
        return f'<section id="{id_}" class="scroll-mt-20 mt-12"><h2 class="text-2xl font-bold tracking-tight text-slate-900">{title}</h2>{body}</section>'

    stat_cards = "".join(
        f'<div class="rounded-xl border border-slate-200 bg-white p-5"><div class="text-3xl font-bold">{counts.get(s, 0)}</div><div class="mt-1">{badge(s)}</div></div>'
        for s in SEV_ORDER
    )
    top = "".join(
        f'<li><a class="font-mono text-indigo-700 hover:underline" href="#{f["id"]}">{f["id"]}</a> {E(f["title"])}</li>'
        for f in issues
        if f["sev"] == "high"
    )
    index_rows = [
        [f'<a class="font-mono text-indigo-700 hover:underline" href="#{f["id"]}">{f["id"]}</a>', badge(f["sev"]), E(f["area"]), E(f["title"])]
        for f in sorted(findings, key=lambda f: (SEV_ORDER.index(f["sev"]), f["id"]))
    ]
    summary = (
        f'<div class="mt-6 grid gap-4 sm:grid-cols-3 lg:grid-cols-5">{stat_cards}</div>'
        f'<p class="mt-4 text-sm text-slate-600">{len(findings)} entries. {LEGEND}</p>'
        f'<h3 class="mt-8 text-lg font-semibold">Highest-impact items</h3><ol class="mt-2 list-decimal space-y-1 pl-6 text-sm">{top or "<li>none</li>"}</ol>'
        f'<h3 class="mt-8 text-lg font-semibold">Index</h3>{table(["Id", "Severity", "Area", "Title"], index_rows)}'
    )
    method = """<ol class="mt-3 max-w-3xl list-decimal space-y-1 pl-5 text-sm text-slate-700">
<li>The Qt desktop (<code>hal-c2-qt</code>) in the <code>mise run desktop:cua</code> sandbox: a headless sway with its own bus and AT-SPI registry, driven by cua-driver, against a scratch MC seeded with a read-only snapshot of real data.</li>
<li>Every area at several window sizes, with the sidebar and right panel open and closed, in light, dark and a custom theme; every control clicked and every flow completed, mutating flows in a scratch project only; keyboard-only passes.</li>
<li>Findings checked against the code behind them, the <code>features/</code> ledger and the legacy web app; severities argued against the ui-ux-pro-max guidelines; items judged fine carry a justification.</li></ol>"""
    findings_html = "".join(
        f'<h3 class="mt-8 border-b border-slate-300 pb-1 text-xl font-semibold">{E(area)} <span class="text-sm font-normal text-slate-500">({len(fs)})</span></h3><div class="mt-4 space-y-5">'
        + "\n".join(card(f) for f in fs)
        + "</div>"
        for area, fs in by_area.items()
    )
    ok_html = '<div class="mt-4 space-y-5">' + "\n".join(card(f) for f in oks) + "</div>"
    env_html = f'<p class="mt-3 whitespace-pre-line text-sm text-slate-700">{E(args.env)}</p>'
    nav = "".join(
        f'<a class="hover:text-slate-900" href="#{i}">{t}</a>'
        for i, t in [("summary", "Summary"), ("method", "Method"), ("findings", "Findings"), ("ok", "OK as-is"), ("coverage", "Coverage"), ("environment", "Environment")]
    )
    doc = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{E(args.title)}</title><script src="https://cdn.tailwindcss.com"></script></head>
<body class="bg-slate-50 text-slate-800">
<header class="sticky top-0 z-10 border-b border-slate-200 bg-white/95 backdrop-blur"><div class="mx-auto flex max-w-7xl items-center justify-between px-6 py-3"><div><div class="text-xs font-semibold uppercase tracking-wide text-indigo-600">apps/desktop-qt</div><h1 class="text-lg font-bold">{E(args.title)}</h1></div><nav class="hidden gap-4 text-sm text-slate-600 md:flex">{nav}</nav></div></header>
<main class="mx-auto max-w-7xl px-6 py-8">
{sec("summary", "Summary", summary)}
{sec("method", "Method", method)}
{sec("findings", f"Findings by area ({len(issues)})", findings_html)}
{sec("ok", f"Reviewed and fine as-is ({len(oks)})", ok_html)}
{sec("coverage", "Coverage", coverage_section(coverage))}
{sec("environment", "Environment", env_html)}
</main></body></html>"""
    (out / "index.html").write_text(doc, encoding="utf-8")
    print(f"findings {len(findings)}: " + ", ".join(f"{s} {counts.get(s, 0)}" for s in SEV_ORDER))
    print(f"missing shots: {missing}")
    print(f"checklist areas never visited: {unvisited(coverage)}")
    print(f"report: {out / 'index.html'}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True, help="the audit dir bootstrap.sh made")
    ap.add_argument("--title", default="HAL-C2 desktop UX/UI audit")
    ap.add_argument("--env", default="")
    build(ap.parse_args())
