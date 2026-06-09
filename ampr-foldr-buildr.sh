#!/usr/bin/env bash
# Ampr Foldr Buildr — stage ampr_emu libSceAmpr.sprx into ShadowMount backport folders.
# Default: fetch game list from https://apr-tracker.netlify.app/games.csv
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: ampr-foldr-buildr.sh [options]

Options:
  -a, --apr <path>         ampr_emu folder or libSceAmpr.sprx (required)
  -g, --games <path>       scan local dump folder(s) instead of tracker
  -t, --tracker <url>      tracker CSV URL (default: apr-tracker games.csv)
  -s, --status <filter>    all | working | issues | crash (default: all)
  -o, --out <path>         output root (default: ./export)
  -m, --mode <mode>        copy | hardlink | symlink (default: copy)
  -d, --debug              use debug/libSceAmpr.sprx
  -n, --dry-run            print actions only
  -h, --help               show this help

Examples:
  ./ampr-foldr-buildr.sh -a ~/Downloads/ampr_emu_0.2b
  ./ampr-foldr-buildr.sh -a ~/ampr_emu_0.2b -s working -m hardlink
  ./ampr-foldr-buildr.sh -a ~/ampr_emu_0.2b -g ./PS5/dumps
EOF
}

GAMES_ROOT=""
APR_SOURCE=""
TRACKER_URL="https://apr-tracker.netlify.app/games.csv"
STATUS_FILTER="all"
OUTPUT_ROOT="./export"
LINK_MODE="copy"
USE_DEBUG=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	-a|--apr) APR_SOURCE="$2"; shift 2 ;;
	-g|--games) GAMES_ROOT="$2"; shift 2 ;;
	-t|--tracker) TRACKER_URL="$2"; shift 2 ;;
	-s|--status) STATUS_FILTER="${2,,}"; shift 2 ;;
	-o|--out) OUTPUT_ROOT="$2"; shift 2 ;;
	-m|--mode) LINK_MODE="$2"; shift 2 ;;
	-d|--debug) USE_DEBUG=1; shift ;;
	-n|--dry-run) DRY_RUN=1; shift ;;
	-h|--help) usage; exit 0 ;;
	-*) echo "Unknown option: $1" >&2; usage; exit 1 ;;
	*) echo "Unexpected argument: $1 (use -g for local dumps)" >&2; usage; exit 1 ;;
	esac
done

if [[ -z "$APR_SOURCE" ]]; then
	usage >&2
	exit 1
fi

resolve_apr() {
	local src="${1%/}"
	if [[ -f "$src" ]]; then
		echo "$src"
		return
	fi
	if [[ ! -d "$src" ]]; then
		echo "APR source not found: $src" >&2
		exit 1
	fi
	if [[ "$USE_DEBUG" -eq 1 && -f "$src/debug/libSceAmpr.sprx" ]]; then
		echo "$src/debug/libSceAmpr.sprx"
		return
	fi
	if [[ -f "$src/libSceAmpr.sprx" ]]; then
		echo "$src/libSceAmpr.sprx"
		return
	fi
	echo "No libSceAmpr.sprx under: $src" >&2
	exit 1
}

install_apr() {
	local canonical="$1"
	local dest_dir="$2"
	local dest="$dest_dir/libSceAmpr.sprx"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		echo "[dry-run] $LINK_MODE -> $dest"
		return
	fi
	mkdir -p "$dest_dir"
	rm -f "$dest"
	case "$LINK_MODE" in
	copy) cp -f "$canonical" "$dest" ;;
	hardlink) ln "$canonical" "$dest" ;;
	symlink) ln -s "$canonical" "$dest" ;;
	*) echo "Invalid mode: $LINK_MODE" >&2; exit 1 ;;
	esac
}

fetch_tracker_entries() {
	python3 - "$TRACKER_URL" "$STATUS_FILTER" "$OUTPUT_ROOT" "$DRY_RUN" <<'PY'
import csv
import io
import sys
import urllib.request

url, status_filter, output_root, dry_run = sys.argv[1:5]
status_filter = status_filter.lower()

print(f"Fetching tracker: {url}", flush=True)
with urllib.request.urlopen(url, timeout=60) as resp:
    text = resp.read().decode("utf-8")

rows = list(csv.DictReader(io.StringIO(text)))
by_id = {}
skipped = []

for row in rows:
    game = (row.get("Game") or "").strip()
    status = (row.get("Status") or "").strip()
    ppsa = (row.get("PPSA ID") or "").strip()

    if status_filter != "all" and status.lower() != status_filter:
        continue

    if not ppsa or ppsa in {"-", "\u2013"}:
        skipped.append((game, status, "no PPSA ID in tracker"))
        continue

    import re
    m = re.match(r"^(PPSA\d{5}|CUSA\d{5})", ppsa)
    if not m:
        skipped.append((game, status, f"unrecognized PPSA ID: {ppsa!r}"))
        continue

    title_id = m.group(1)
    if title_id not in by_id:
        by_id[title_id] = (title_id, game, status)

if not by_id:
    raise SystemExit("No tracker entries with PPSA IDs matched the filter.")

if dry_run == "0":
    import os
    meta_root = os.path.join(output_root, ".buildr")
    os.makedirs(meta_root, exist_ok=True)
    manifest = os.path.join(meta_root, "tracker-manifest.csv")
    with open(manifest, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["TitleId", "Game", "Status", "Source"])
        for title_id, game, status in sorted(by_id.values()):
            w.writerow([title_id, game, status, "apr-tracker"])
    if skipped:
        skip_path = os.path.join(meta_root, "skipped-no-ppsa.csv")
        with open(skip_path, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["Game", "Status", "Reason"])
            w.writerows(skipped)
        print(f"Skipped {len(skipped)} tracker game(s) without PPSA ID -> {skip_path}", flush=True)

for title_id, game, status in sorted(by_id.values()):
    print(f"ENTRY\t{title_id}\t{game}\t{status}", flush=True)

print(f"TRACKER_SUMMARY\t{len(by_id)}\t{len(skipped)}", flush=True)
PY
}

APR_FILE="$(resolve_apr "$APR_SOURCE")"
META_ROOT="$OUTPUT_ROOT/.buildr"
CANONICAL="$META_ROOT/libSceAmpr.sprx"
BACKPORTS="$OUTPUT_ROOT/data/homebrew/backports"

mkdir -p "$META_ROOT" "$BACKPORTS"
if [[ "$DRY_RUN" -eq 1 ]]; then
	echo "[dry-run] canonical APR -> $CANONICAL"
else
	cp -f "$APR_FILE" "$CANONICAL"
	echo "Staged canonical APR -> $CANONICAL"
fi

created=0
if [[ -n "$GAMES_ROOT" ]]; then
	echo "Mode: local dumps"
	# Delegate local mode to a minimal inline path via python for parity
	while IFS=$'\t' read -r title_id game status; do
		[[ "$title_id" == ENTRY ]] || continue
		echo "[$title_id] $game ($status)"
		install_apr "$CANONICAL" "$BACKPORTS/$title_id/fakelib"
		created=$((created + 1))
	done < <(
		python3 - "$GAMES_ROOT" <<'PY'
import json, os, re, sys

root = sys.argv[1]

def norm(v):
    if not v:
        return None
    v = v.strip()
    if v in {"", "-", "\u2013"}:
        return None
    m = re.match(r"^(PPSA\d{5}|CUSA\d{5})", v)
    return m.group(1) if m else None

def find_param(d):
    direct = os.path.join(d, "sce_sys", "param.json")
    if os.path.isfile(direct):
        return direct
    for name in os.listdir(d):
        p = os.path.join(d, name, "sce_sys", "param.json")
        if os.path.isfile(p):
            return p
    return None

def is_dump(d):
    return os.path.isfile(os.path.join(d, "eboot.bin")) or find_param(d)

candidates = [root] if is_dump(root) else [
    os.path.join(root, n) for n in os.listdir(root)
    if os.path.isdir(os.path.join(root, n)) and is_dump(os.path.join(root, n))
]

for dump in candidates:
    param = find_param(dump)
    title_id = None
    if param:
        with open(param, encoding="utf-8") as f:
            title_id = norm(json.load(f).get("titleId", ""))
    if not title_id:
        title_id = norm(os.path.basename(dump))
    if not title_id:
        print(f"warning: skip {os.path.basename(dump)}: no title ID", file=sys.stderr)
        continue
    print(f"ENTRY\t{title_id}\t{os.path.basename(dump)}\tlocal")
PY
	)
else
	echo "Mode: APR tracker (status filter: $STATUS_FILTER)"
	tracker_summary=""
	while IFS=$'\t' read -r kind a b c; do
		case "$kind" in
		ENTRY)
			echo "[$a] $b ($c)"
			install_apr "$CANONICAL" "$BACKPORTS/$a/fakelib"
			created=$((created + 1))
			;;
		TRACKER_SUMMARY)
			tracker_summary="with PPSA: $a, skipped: $b"
			;;
		esac
	done < <(fetch_tracker_entries)
fi

if [[ "$created" -eq 0 ]]; then
	echo "No backport folders were created." >&2
	exit 1
fi

echo ""
echo "Done. Created/updated $created title(s) under:"
echo "  $BACKPORTS"
[[ -n "$tracker_summary" ]] && echo "Tracker: $tracker_summary"
echo ""
if [[ "$DRY_RUN" -eq 0 ]]; then
	cat >"$OUTPUT_ROOT/DEPLOY.txt" <<'EOF'
Copy this folder to the PS5:
  export/data/  ->  /data/

ShadowMount reads:
  /data/homebrew/backports/PPSAxxxxx/fakelib/libSceAmpr.sprx

Do not upload .buildr/ - PC build metadata only.
EOF
fi
echo "Deploy: $OUTPUT_ROOT/data/ -> /data/ on PS5"
if [[ "$LINK_MODE" != "copy" ]]; then
	echo "Note: re-run with -m copy before FTP if links are not preserved."
fi
