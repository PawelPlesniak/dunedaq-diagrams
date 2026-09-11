#!/usr/bin/env bash
# Renders src/**/*.drawio into a mirrored auto-images/**/*.svg tree using the
# draw.io desktop CLI. It exports each page in multi-page diagrams individually,
# stamps each render with its provenance, and removes any auto-images/ renders 
# whose source .drawio no longer exists.
#
# Usage:
#   scripts/render-images.sh --all              render every src/**/*.drawio
#   scripts/render-images.sh file1.drawio ...    render only these (repo-relative paths)
#   scripts/render-images.sh                     render nothing, just run orphan cleanup
#
# Requires the `drawio` desktop CLI on PATH (or $DRAWIO_BIN pointing at it):
# macOS: brew install --cask drawio
# Linux: install the matching drawio-desktop .deb release + xvfb, see
#        .github/workflows/sync-diagrams.yml for the pinned version.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

DRAWIO_BIN="${DRAWIO_BIN:-drawio}"
SRC_DIR="src"
OUT_DIR="auto-images"

files=()
if [ "${1:-}" = "--all" ]; then
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$SRC_DIR" -type f -name '*.drawio' | sort)
else
  files=("$@")
fi

# Determine xvfb prefix once to clean up the loop
XVFB_PREFIX=()
if command -v xvfb-run >/dev/null 2>&1; then
  XVFB_PREFIX=(xvfb-run -a)
fi

if [ "${#files[@]}" -gt 0 ]; then
  if ! command -v "$DRAWIO_BIN" >/dev/null 2>&1; then
    echo "error: '$DRAWIO_BIN' not found on PATH." >&2
    echo "  macOS: brew install --cask drawio" >&2
    echo "  Linux: install the pinned drawio-desktop .deb (see .github/workflows/sync-diagrams.yml)" >&2
    exit 1
  fi

  commit_sha="$(git rev-parse HEAD)"
  rendered_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  for src_file in "${files[@]}"; do
    rel="${src_file#"$SRC_DIR"/}"
    xml_file="${src_file}.xml"
    
    echo "Extracting page data from $src_file"
    "${XVFB_PREFIX[@]}" "$DRAWIO_BIN" -x -f xml --uncompressed -o "$xml_file" "$src_file" 2>/dev/null

    # Extract page names. Use 'Page-1' as a fallback if no <diagram name="..."> attribute exists
    page_names=$(grep -Eo '<diagram[^>]*name="[^"]+"' "$xml_file" | grep -Eo 'name="[^"]+"' | cut -d'"' -f2 || echo "Page-1")
    
    page_index=1 
    while IFS= read -r page_name; do
      if [ -z "$page_name" ]; then continue; fi

      # Sanitize the page name: replace invalid chars with underscores, collapse multiples, remove trailing/leading
      safe_name=$(echo "$page_name" | tr -c 'a-zA-Z0-9.\-' '_' | tr -s '_' | sed 's/^_//; s/_$//')
      dest="$OUT_DIR/${rel%.drawio}-${safe_name}.svg"
      mkdir -p "$(dirname "$dest")"

      echo "Rendering $src_file (Page: $page_name) -> $dest"
      
      "${XVFB_PREFIX[@]}" "$DRAWIO_BIN" -x -f svg -t --page-index "$page_index" -o "$dest" "$src_file" 2>/dev/null

      comment="<!-- rendered from ${src_file} at commit ${commit_sha} on ${rendered_at} -->"
      tmp="$(mktemp)"
      { head -n 2 "$dest"; echo "$comment"; tail -n +3 "$dest"; } > "$tmp"
      mv "$tmp" "$dest"

      ((page_index++))
    done <<< "$page_names"
    
    rm -f "$xml_file"
  done
fi

# Orphan cleanup reads the exact source file from the injected HTML comment
if [ -d "$OUT_DIR" ]; then
  while IFS= read -r f; do
    src_equiv=$(grep -m 1 -o '<!-- rendered from .* at commit' "$f" | sed 's/<!-- rendered from //; s/ at commit//' || true)
    
    if [ -n "$src_equiv" ]; then
      if [ ! -f "$src_equiv" ]; then
        echo "Removing orphaned render: $f (no matching $src_equiv)"
        rm -f "$f"
      fi
    else
      echo "Removing unstamped or legacy render: $f"
      rm -f "$f"
    fi
  done < <(find "$OUT_DIR" -type f -name '*.svg')
  find "$OUT_DIR" -mindepth 1 -type d -empty -delete
fi