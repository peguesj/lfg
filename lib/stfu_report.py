#!/usr/bin/env python3
"""STFU Report Generator - Creates interactive HTML from STFU JSON data."""

import json
import os
import sys


def generate_html(data: dict, lfg_dir: str, execute_mode: bool = False) -> str:
    theme = open(f"{lfg_dir}/lib/theme.css").read()
    uijs = open(f"{lfg_dir}/lib/ui.js").read()

    meta = data.get("meta", {})
    summary = data.get("summary", {})
    projects = data.get("projects", [])
    duplicates = data.get("duplicates", [])
    relationships = data.get("relationships", [])
    clusters = data.get("clusters", [])
    conflicts = data.get("version_conflicts", [])
    fingerprints = data.get("fingerprints", {})
    code_dupes = data.get("code_duplicates", [])
    lib_candidates = data.get("library_candidates", [])
    env_groups = data.get("environment_groups", [])
    ai_analysis = data.get("ai_analysis", {})

    savings = summary.get("estimated_savings_mb", 0)
    mode_label = "EXECUTE MODE" if execute_mode else "DRY RUN"
    mode_color = "#ff4d6a" if execute_mode else "#06d6a0"

    # Build duplicate rows with action cards
    dupe_rows = ""
    for d in duplicates[:20]:
        score = round(d.get("jaccard_similarity", 0) * 100)
        color = "#ff4d6a" if score > 80 else "#ff8c42"
        shared = len(d.get("shared_deps", []))
        pa, pb = d["project_a"], d["project_b"]
        shared_preview = ", ".join(d.get("shared_deps", [])[:8])

        # Action card
        risk_class = "high" if score > 85 else "medium"
        archive_btn = ""
        if execute_mode:
            sq = "'"
            archive_btn = (
                '<button class="action-btn-exec" onclick="LFG.confirm('
                + sq + 'Archive ' + pa + '?' + sq + ','
                + sq + '$HOME/tools/@yj/lfg/lfg stfu archive ' + pa + sq + ','
                + "function(o){LFG.toast(o,{type:" + sq + "success" + sq + "}); refreshReport()})"
                + '">Archive ' + pa + '</button>'
            )
        action_html = f'''<div class="action-card">
            <div class="action-header">
                <span class="action-type">Merge Candidate</span>
                <span class="risk-dot risk-{risk_class}"></span>
                <span class="mode-badge" style="color:{mode_color}">{mode_label}</span>
            </div>
            <div class="action-detail">
                <div class="action-what">Merge <strong>{pa}</strong> into <strong>{pb}</strong> (or archive {pa})</div>
                <div class="action-meta">{shared} shared deps | {score}% overlap | {shared_preview}</div>
            </div>
            <div class="action-buttons">
                <button class="action-btn-sm" onclick="togglePreview(this, '{pa}', '{pb}')">Preview</button>
                <button class="action-btn-sm" onclick="LFG.exec('$HOME/tools/@yj/lfg/lfg stfu merge-check {pa} {pb}', function(o){{showResult(o)}})">Check</button>
                {archive_btn}
            </div>
            <div class="action-preview" style="display:none">
                <div class="preview-cmd">lfg stfu merge-check {pa} {pb}</div>
                <div class="preview-cmd">lfg stfu archive {pa}</div>
                <div class="preview-note">Restore: mv ~/Developer/.archive/{pa}_* ~/Developer/{pa}</div>
            </div>
        </div>'''

        dupe_rows += f'''<tr data-tip="{shared_preview}">
            <td class="name">{pa}</td>
            <td class="name">{pb}</td>
            <td class="pct" style="color:{color}">{score}%</td>
            <td class="meta">{shared} deps</td>
        </tr>'''
        dupe_rows += f'<tr class="action-row"><td colspan="4">{action_html}</td></tr>'

    # Relationship rows
    rel_rows = ""
    for r in relationships[:25]:
        score = round(r.get("combined_score", r.get("jaccard_similarity", 0)) * 100)
        dep_sim = round(r.get("jaccard_similarity", 0) * 100)
        struct_sim = round(r.get("structural_similarity", 0) * 100)
        rel_rows += f'''<tr data-tip="Dep: {dep_sim}% Struct: {struct_sim}%">
            <td class="name">{r["project_a"]}</td>
            <td class="name">{r["project_b"]}</td>
            <td class="bar-cell"><div class="bar-track"><div class="bar-fill" style="width:{score}%;background:#c084fc"></div></div></td>
            <td class="pct">{score}%</td>
            <td class="meta">{len(r.get('shared_deps', []))} shared</td>
        </tr>'''

    # Cluster cards
    cluster_html = ""
    for i, c in enumerate(clusters[:10]):
        projects_html = " ".join(
            f'<span class="ai-pill" style="background:#06d6a020;color:#06d6a0;border:1px solid #06d6a033">{p}</span>'
            for p in c
        )
        cluster_html += f'''<div style="margin-bottom:12px;padding:12px 14px;background:#1c1c22;border:1px solid #2a2a34;border-radius:8px;border-left:3px solid #06d6a0">
            <div style="font-size:10px;text-transform:uppercase;letter-spacing:0.8px;color:#06d6a0;margin-bottom:6px">Cluster {i+1} ({len(c)} projects)</div>
            <div style="display:flex;flex-wrap:wrap;gap:6px">{projects_html}</div>
        </div>'''

    # Code duplicate rows
    code_dupe_rows = ""
    for cd in code_dupes[:15]:
        sim = round(cd.get("similarity", 0) * 100)
        cat = cd.get("pattern_category", "custom")
        cat_colors = {"auth": "#ff4d6a", "error_handling": "#ff8c42", "cors": "#ffd166", "validation": "#4a9eff", "custom": "#6b6b78"}
        cc = cat_colors.get(cat, "#6b6b78")
        fa = cd["file_a"].replace(os.path.expanduser("~/Developer/"), "")
        fb = cd["file_b"].replace(os.path.expanduser("~/Developer/"), "")
        code_dupe_rows += f'''<tr data-tip="{fa} vs {fb}">
            <td class="name">{cd["project_a"]}</td>
            <td class="name">{cd["project_b"]}</td>
            <td><span class="cat" style="color:{cc}">{cat}</span></td>
            <td class="pct">{sim}%</td>
            <td class="meta">{cd.get("line_count", 0)} lines</td>
        </tr>'''

    # Library candidate cards with action buttons
    lib_html = ""
    type_colors = {
        "ui-components": "#4a9eff", "auth": "#ff4d6a", "api-client": "#ffd166",
        "middleware": "#ff8c42", "testing-config": "#06d6a0", "build-config": "#c084fc",
    }
    for lc in lib_candidates:
        lc_color = type_colors.get(lc["lib_type"], "#6b6b78")
        projs = ", ".join(lc["source_projects"][:6])
        lib_short = lc["name"].rsplit("/", 1)[-1]
        if execute_mode:
            sq = "'"
            scaffold_btn = (
                '<button class="action-btn-exec" onclick="LFG.confirm('
                + sq + "Create scaffold for " + lc["name"] + "?" + sq + ","
                + sq + "$HOME/tools/@yj/lfg/lfg stfu scaffold " + lib_short + sq + ","
                + "function(o){LFG.toast(o,{type:" + sq + "success" + sq + "})})\">"
                + "Scaffold</button>"
            )
        else:
            scaffold_btn = f'<button class="action-btn-sm" onclick="showScaffoldPreview(this, \'lfg stfu scaffold {lib_short}\')">Preview</button>'
        lib_html += f'''<div style="margin-bottom:10px;padding:12px 14px;background:#1c1c22;border:1px solid #2a2a34;border-radius:8px;border-left:3px solid {lc_color}">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px">
                <span style="font-weight:700;color:#fff;font-size:13px">{lc["name"]}</span>
                <div style="display:flex;gap:8px;align-items:center">
                    <span class="ai-pill" style="background:{lc_color}20;color:{lc_color};border:1px solid {lc_color}33">{lc["lib_type"]}</span>
                    {scaffold_btn}
                </div>
            </div>
            <div style="font-size:11px;color:#6b6b78;margin-bottom:4px">Sources: {projs}</div>
            <div style="display:flex;gap:16px;font-size:10px;color:#4a4a56">
                <span>~{lc["estimated_dedup_savings_mb"]:.0f} MB savings</span>
                <span>~{lc["effort_hours"]}h effort</span>
                <span>Priority: {"!" * lc["priority"]}</span>
            </div>
        </div>'''

    # Environment group cards with action buttons
    env_html = ""
    for eg in env_groups:
        compat = round(eg["compatibility_score"] * 100)
        projs = ", ".join(eg["projects"][:8])
        conflict_count = len(eg.get("conflicts", []))
        env_html += f'''<div style="margin-bottom:10px;padding:12px 14px;background:#1c1c22;border:1px solid #2a2a34;border-radius:8px;border-left:3px solid #ff8c42">
            <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:6px">
                <span style="font-weight:700;color:#fff;font-size:12px">{eg["ecosystem"].upper()} Group ({len(eg["projects"])} projects)</span>
                <span style="font-size:11px;color:{'#06d6a0' if compat > 80 else '#ff8c42'}">{compat}% compatible</span>
            </div>
            <div style="font-size:11px;color:#6b6b78;margin-bottom:4px">{projs}</div>
            <div style="display:flex;gap:16px;font-size:10px;color:#4a4a56">
                <span>~{eg["savings_estimate_mb"]:.0f} MB potential savings</span>
                <span>{conflict_count} version conflicts</span>
                <span>{len(eg.get('shared_deps', []))} shared deps</span>
            </div>
        </div>'''

    # Template groups
    tpl_html = ""
    for tpl, projs in fingerprints.get("template_groups", {}).items():
        tpl_html += f'''<div style="margin-bottom:8px;padding:8px 12px;background:#1c1c22;border:1px solid #2a2a34;border-radius:6px">
            <span style="font-size:11px;color:#e879f9;font-weight:600">{tpl}</span>
            <span style="font-size:10px;color:#6b6b78"> - {len(projs)} projects: {', '.join(projs)}</span>
        </div>'''

    # AI insights
    ai_html = ""
    for name, info in list(ai_analysis.items())[:12]:
        purpose = info.get("purpose", "Unknown")
        category = info.get("category", "other")
        risk = info.get("merge_risk", "unknown")
        risk_color = {"low": "#06d6a0", "medium": "#ffd166", "high": "#ff4d6a"}.get(risk, "#6b6b78")
        ai_html += f'''<tr>
            <td class="name">{name}</td>
            <td style="font-size:11px;color:#a0a0b0">{purpose[:60]}</td>
            <td><span class="ai-pill">{category}</span></td>
            <td style="color:{risk_color};font-size:11px">{risk}</td>
        </tr>'''

    # Project search/filter
    project_count = len(projects)

    html = f'''<!DOCTYPE html>
<html><head><meta charset="utf-8">
<style>{theme}
.stfu-nav {{ display:flex; gap:8px; margin:12px 0; flex-wrap:wrap; }}
.stfu-nav a {{ padding:6px 14px; border:1px solid #2a2a34; border-radius:6px; font-size:11px; color:#6b6b78; cursor:pointer; transition:all 0.15s; text-decoration:none; }}
.stfu-nav a:hover, .stfu-nav a.active {{ border-color:#e879f9; color:#e879f9; background:#e879f910; }}
.stfu-section {{ display:none; }}
.stfu-section.active {{ display:block; }}
.action-btn-sm {{ padding:4px 10px; border:1px solid #c084fc; border-radius:4px; background:transparent; color:#c084fc; font-size:10px; cursor:pointer; font-family:inherit; transition:all 0.15s; }}
.action-btn-sm:hover {{ background:#c084fc15; }}
.action-btn-exec {{ padding:4px 10px; border:1px solid #ff4d6a; border-radius:4px; background:#ff4d6a15; color:#ff4d6a; font-size:10px; cursor:pointer; font-family:inherit; transition:all 0.15s; }}
.action-btn-exec:hover {{ background:#ff4d6a30; }}
.action-card {{ margin:6px 0 10px; padding:10px 14px; background:#16161b; border:1px solid #2a2a34; border-radius:8px; }}
.action-header {{ display:flex; align-items:center; gap:8px; margin-bottom:6px; }}
.action-type {{ font-size:10px; font-weight:700; text-transform:uppercase; letter-spacing:0.5px; color:#c084fc; }}
.mode-badge {{ font-size:9px; font-weight:600; text-transform:uppercase; letter-spacing:1px; margin-left:auto; }}
.risk-dot {{ width:8px; height:8px; border-radius:50%; display:inline-block; }}
.risk-dot.risk-high {{ background:#ff4d6a; }}
.risk-dot.risk-medium {{ background:#ffd166; }}
.risk-dot.risk-low {{ background:#06d6a0; }}
.action-detail {{ margin-bottom:8px; }}
.action-what {{ font-size:12px; color:#d0d0d8; margin-bottom:4px; }}
.action-meta {{ font-size:10px; color:#4a4a56; }}
.action-buttons {{ display:flex; gap:8px; margin-bottom:4px; }}
.action-preview {{ margin-top:8px; padding:8px 12px; background:#12121a; border:1px solid #1e1e28; border-radius:4px; }}
.preview-cmd {{ font-size:10px; color:#06d6a0; font-family:monospace; margin-bottom:2px; }}
.preview-cmd::before {{ content:"$ "; color:#4a4a56; }}
.preview-note {{ font-size:10px; color:#4a4a56; margin-top:4px; font-style:italic; }}
.action-row td {{ padding:0 !important; border:none !important; }}
.filter-bar {{ display:flex; gap:12px; align-items:center; margin:8px 0; }}
.filter-input {{ background:#1c1c22; border:1px solid #2a2a34; border-radius:6px; padding:6px 12px; font-size:11px; color:#d0d0d8; outline:none; font-family:inherit; width:200px; }}
.filter-input:focus {{ border-color:#e879f9; }}
.filter-input::placeholder {{ color:#4a4a56; }}
table th {{ cursor:pointer; user-select:none; }}
table th:hover {{ color:#e879f9; }}
@media print {{ body {{ background:#fff !important; color:#000 !important; }} .header,.footer,.stfu-nav,.action-buttons,.filter-bar {{ display:none !important; }} table {{ border:1px solid #ccc; }} td,th {{ color:#000 !important; border-color:#ccc !important; }} }}
</style>
</head><body>
  <div class="header">
    <h1><span class="brand">lfg</span> stfu <span class="dim">Source Tree Forensics & Unification</span></h1>
    <div style="display:flex;align-items:center;gap:12px">
        <span class="mode-badge" style="color:{mode_color};font-size:10px;font-weight:600;letter-spacing:1px">{mode_label}</span>
        <span class="meta">{meta.get('timestamp', '')}</span>
    </div>
  </div>
  <div class="summary">
    <div class="stat" data-tip="Total projects analyzed"><span class="label">Projects</span><span class="value">{summary.get('total_projects', 0)}</span></div>
    <div class="stat" data-tip="Near-identical project pairs"><span class="label">Duplicates</span><span class="value warn">{summary.get('duplicate_pairs', 0)}</span></div>
    <div class="stat" data-tip="Related project pairs"><span class="label">Relationships</span><span class="value">{summary.get('relationship_pairs', 0)}</span></div>
    <div class="stat" data-tip="Project clusters"><span class="label">Clusters</span><span class="value accent">{summary.get('cluster_count', 0)}</span></div>
    <div class="stat" data-tip="Code pattern duplicates"><span class="label">Code Dupes</span><span class="value" style="color:#ff8c42">{summary.get('code_duplicate_files', 0)}</span></div>
    <div class="stat" data-tip="Shared library opportunities"><span class="label">Libraries</span><span class="value" style="color:#4a9eff">{summary.get('library_candidates', 0)}</span></div>
    <div class="stat" data-tip="Estimated disk savings"><span class="label">Savings</span><span class="value good">{savings:.0f} MB</span></div>
  </div>

  <div class="filter-bar">
    <input class="filter-input" id="projectFilter" placeholder="Filter projects..." oninput="filterTables(this.value)">
  </div>

  <div class="stfu-nav">
    <a class="active" onclick="showSection('dupes', this)">Duplicates ({summary.get('duplicate_pairs', 0)})</a>
    <a onclick="showSection('rels', this)">Relationships</a>
    <a onclick="showSection('clusters', this)">Clusters ({summary.get('cluster_count', 0)})</a>
    <a onclick="showSection('codedupes', this)">Code Patterns ({summary.get('code_duplicate_files', 0)})</a>
    <a onclick="showSection('libs', this)">Libraries ({summary.get('library_candidates', 0)})</a>
    <a onclick="showSection('envs', this)">Environments ({summary.get('env_groups', 0)})</a>
    <a onclick="showSection('templates', this)">Templates</a>
    {'<a onclick="showSection(\'ai\', this)">AI Insights</a>' if ai_analysis else ''}
  </div>

  <div id="sec-dupes" class="stfu-section active">
    <div class="guidance" style="border-left-color:#ff4d6a"><strong>Duplicates</strong> - Project pairs with &gt;70% dependency overlap. {'Actions enabled - click Execute to proceed.' if execute_mode else 'Click Preview to see recommended actions. Use --execute to enable actions.'}</div>
    {'<table><thead><tr><th>Project A</th><th>Project B</th><th class="r">Overlap</th><th>Shared</th></tr></thead><tbody>' + dupe_rows + '</tbody></table>' if dupe_rows else '<div class="empty-state">No duplicates found (>70% overlap threshold)</div>'}
  </div>

  <div id="sec-rels" class="stfu-section">
    <div class="guidance" style="border-left-color:#c084fc"><strong>Relationships</strong> - All project pairs with measurable similarity (dep + structural + code).</div>
    {'<table><thead><tr><th>Project A</th><th>Project B</th><th>Combined</th><th class="r">Score</th><th>Deps</th></tr></thead><tbody>' + rel_rows + '</tbody></table>' if rel_rows else '<div class="empty-state">No relationships found</div>'}
  </div>

  <div id="sec-clusters" class="stfu-section">
    <div class="guidance" style="border-left-color:#06d6a0"><strong>Coalescence Clusters</strong> - Groups of projects that could share infrastructure, environments, or be merged into monorepos.</div>
    {cluster_html or '<div class="empty-state">No clusters found</div>'}
  </div>

  <div id="sec-codedupes" class="stfu-section">
    <div class="guidance" style="border-left-color:#ff8c42"><strong>Code Duplicates</strong> - Middleware, handlers, and utilities with high content similarity across projects.</div>
    {'<table><thead><tr><th>Project A</th><th>Project B</th><th>Pattern</th><th class="r">Similarity</th><th>Lines</th></tr></thead><tbody>' + code_dupe_rows + '</tbody></table>' if code_dupe_rows else '<div class="empty-state">No code duplicates found</div>'}
  </div>

  <div id="sec-libs" class="stfu-section">
    <div class="guidance" style="border-left-color:#4a9eff"><strong>Library Candidates</strong> - Recommended shared packages to extract from duplicate code and dep overlap. {'Scaffold enabled.' if execute_mode else 'Use --execute to enable scaffold creation.'}</div>
    {lib_html or '<div class="empty-state">No library candidates identified</div>'}
  </div>

  <div id="sec-envs" class="stfu-section">
    <div class="guidance" style="border-left-color:#ff8c42"><strong>Environment Groups</strong> - Projects with compatible dependencies that could share node_modules/venvs.</div>
    {env_html or '<div class="empty-state">No environment consolidation opportunities found</div>'}
  </div>

  <div id="sec-templates" class="stfu-section">
    <div class="guidance" style="border-left-color:#e879f9"><strong>Template Groups</strong> - Projects built from the same scaffolding or boilerplate.</div>
    {tpl_html or '<div class="empty-state">No template groups detected</div>'}
  </div>

  <div id="sec-ai" class="stfu-section">
    <div class="guidance" style="border-left-color:#ffd166"><strong>AI Insights</strong> - Semantic analysis of project purpose and merge risk.</div>
    {'<table><thead><tr><th>Project</th><th>Purpose</th><th>Category</th><th>Merge Risk</th></tr></thead><tbody>' + ai_html + '</tbody></table>' if ai_html else '<div class="empty-state">AI analysis not available. Check: lfg ai config show</div>'}
  </div>

  <div class="footer">lfg stfu v2.1.0 | {summary.get('total_projects', 0)} projects | {mode_label}</div>

  <script>{uijs}
  LFG.init({{
    module: "stfu", context: "Source Tree Forensics",
    moduleVersion: "2.1.0",
    welcome: "{summary.get('total_projects', 0)} projects, {summary.get('duplicate_pairs', 0)} duplicates, ~{savings:.0f} MB savings"
  }});
  function showSection(id, el) {{
    document.querySelectorAll('.stfu-section').forEach(function(s) {{ s.classList.remove('active'); }});
    document.querySelectorAll('.stfu-nav a').forEach(function(a) {{ a.classList.remove('active'); }});
    document.getElementById('sec-' + id).classList.add('active');
    if (el) el.classList.add('active');
  }}
  function togglePreview(btn, pa, pb) {{
    var card = btn.closest('.action-card');
    var preview = card.querySelector('.action-preview');
    preview.style.display = preview.style.display === 'none' ? 'block' : 'none';
    btn.textContent = preview.style.display === 'none' ? 'Preview' : 'Hide';
  }}
  function showResult(output) {{
    LFG.toast(output.substring(0, 300), {{type: 'info', duration: 8000}});
  }}
  function showScaffoldPreview(sectionId, cmd) {{
    LFG.toast('Preview: ' + cmd, {{type: 'info', duration: 5000}});
  }}
  function refreshReport() {{
    LFG.toast('Refreshing report...', {{type: 'info'}});
    LFG.exec('$HOME/tools/@yj/lfg/lfg stfu --json --no-ai', function(o) {{ location.reload(); }});
  }}
  function filterTables(query) {{
    var q = query.toLowerCase();
    document.querySelectorAll('table tbody tr:not(.action-row)').forEach(function(row) {{
      var text = row.textContent.toLowerCase();
      var show = !q || text.indexOf(q) !== -1;
      row.style.display = show ? '' : 'none';
      var next = row.nextElementSibling;
      if (next && next.classList.contains('action-row')) {{
        next.style.display = show ? '' : 'none';
      }}
    }});
  }}
  // Sortable columns
  document.querySelectorAll('table th').forEach(function(th, idx) {{
    th.addEventListener('click', function() {{
      var table = th.closest('table');
      var tbody = table.querySelector('tbody');
      var rows = Array.from(tbody.querySelectorAll('tr:not(.action-row)'));
      var asc = th.dataset.sort !== 'asc';
      th.dataset.sort = asc ? 'asc' : 'desc';
      rows.sort(function(a, b) {{
        var va = a.children[idx] ? a.children[idx].textContent.trim() : '';
        var vb = b.children[idx] ? b.children[idx].textContent.trim() : '';
        var na = parseFloat(va), nb = parseFloat(vb);
        if (!isNaN(na) && !isNaN(nb)) return asc ? na - nb : nb - na;
        return asc ? va.localeCompare(vb) : vb.localeCompare(va);
      }});
      rows.forEach(function(row) {{
        var actionRow = row.nextElementSibling;
        tbody.appendChild(row);
        if (actionRow && actionRow.classList.contains('action-row')) tbody.appendChild(actionRow);
      }});
    }});
  }});
  </script>
</body></html>'''
    return html


if __name__ == "__main__":
    output_path = sys.argv[1] if len(sys.argv) > 1 else ""
    execute_mode = "--execute" in sys.argv
    data = json.load(sys.stdin)
    lfg_dir = os.environ.get("LFG_DIR", os.path.expanduser("~/tools/@yj/lfg"))
    html = generate_html(data, lfg_dir, execute_mode=execute_mode)
    if output_path:
        with open(output_path, "w") as f:
            f.write(html)
    else:
        print(html)
