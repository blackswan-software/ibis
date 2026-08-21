#!/usr/bin/env bash
# cmd_render.sh — regenerate graph.html from .ibis/GRAPH.dot.
#
# graph.html is a self-contained @viz-js/viz (WASM) viewer that renders
# the DOT source client-side. This command re-embeds the current GRAPH.dot
# so the rendered view stays in sync.
#
#   ibis render              update graph.html
#   ibis render --open       update and open in browser

ibis_render() {
  require_init
  local html="$REPO_ROOT/graph.html"
  local tmpl="$IBIS_HOME/templates/graph.html"
  local open_after=false

  [[ "${1:-}" == "--open" ]] && open_after=true

  # If no graph.html exists yet, copy from template
  if [[ ! -f "$html" ]]; then
    [[ -f "$tmpl" ]] || die "no graph.html template at $tmpl"
    cp "$tmpl" "$html"
    ok "created graph.html from template"
  fi

  "$PYTHON" - "$GRAPH" "$html" <<'PY'
import json, re, sys, pathlib

dot_path, html_path = sys.argv[1], sys.argv[2]
dot = pathlib.Path(dot_path).read_text()
html = pathlib.Path(html_path).read_text()

# Re-embed the dot as a JSON string
payload = json.dumps(dot)
pat = re.compile(
    r'(<script id="dotData" type="application/json">).*?(</script>)',
    re.DOTALL
)
if not pat.search(html):
    sys.exit('ibis render: <script id="dotData"> block not found in graph.html')
html = pat.sub(lambda m: m.group(1) + payload + m.group(2), html, count=1)

# Build node attributes JSON for click-to-inspect
attrs = {}
for m in re.finditer(r'(\w+)\s*\[(.*?)\];', dot, re.DOTALL):
    name = m.group(1)
    if name in ('node', 'edge', 'graph', 'digraph', 'subgraph'):
        continue
    attrs[name] = m.group(2).strip()
attr_payload = json.dumps(attrs)
attr_pat = re.compile(
    r'(<script id="attrData" type="application/json">).*?(</script>)',
    re.DOTALL
)
if attr_pat.search(html):
    html = attr_pat.sub(lambda m: m.group(1) + attr_payload + m.group(2), html, count=1)

pathlib.Path(html_path).write_text(html)
print(f"graph.html regenerated — embedded {len(dot)} bytes of GRAPH.dot")
PY

  if $open_after; then
    if command -v xdg-open &>/dev/null; then xdg-open "$html"
    elif command -v open &>/dev/null; then open "$html"
    else warn "can't detect browser — open $html manually"
    fi
  fi
}
