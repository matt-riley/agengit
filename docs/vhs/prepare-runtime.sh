#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="${AGIT_BIN_OVERRIDE:-$ROOT/zig-out/bin/agit}"
WORKSPACE="$ROOT/docs/vhs/workspace"
RUNTIME_FILE="$ROOT/docs/vhs/runtime.env"

if [[ ! -x "$BIN" ]]; then
  echo "agit binary not found at $BIN (build first with zig build -Doptimize=ReleaseSafe)" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required to prepare VHS runtime metadata." >&2
  exit 1
fi

rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE/home" "$WORKSPACE/repo"

cd "$WORKSPACE/repo"
git init -q -b main
git config user.name "VHS Bot"
git config user.email "vhs@example.com"

mkdir -p .agit
cat > notes.txt <<'EOF'
hello
EOF
git add notes.txt
git commit -qm "seed fixture"

cat > "$WORKSPACE/observer-seed.jsonl" <<EOF
{"session_id":"sess-a","cwd":"$WORKSPACE/repo","role":"user","content":"Refactor notes to support factorial docs"}
{"session_id":"sess-a","cwd":"$WORKSPACE/repo","role":"tool","tool_name":"bash","args":"echo updated > notes.txt","result":"ok"}
{"session_id":"sess-a","cwd":"$WORKSPACE/repo","role":"assistant","content":"Updated notes successfully"}
{"session_id":"sess-b","cwd":"$WORKSPACE/repo","role":"user","content":"Review CLI status output"}
{"session_id":"sess-b","cwd":"$WORKSPACE/repo","role":"assistant","content":"Status output reviewed"}
EOF

cat > "$WORKSPACE/observer-extra.jsonl" <<EOF
{"session_id":"sess-c","cwd":"$WORKSPACE/repo","role":"user","content":"Capture extra observe tape run"}
{"session_id":"sess-c","cwd":"$WORKSPACE/repo","role":"assistant","content":"Observe run complete"}
EOF

HOME="$WORKSPACE/home" "$BIN" observe --once jsonl --input "$WORKSPACE/observer-seed.jsonl" >/dev/null

SESSION_ID="$(HOME="$WORKSPACE/home" "$BIN" sessions --json | jq -r '.data.sessions[] | select(.session_id == "sess-a") | .session_id' | head -n 1)"
STEP_HASH="$(HOME="$WORKSPACE/home" "$BIN" sessions --json | jq -r '.data.sessions[] | select(.session_id == "sess-a") | .head_hash' | head -n 1)"

if [[ -z "$SESSION_ID" || -z "$STEP_HASH" ]]; then
  echo "Failed to derive session/hash metadata for VHS tapes." >&2
  exit 1
fi

COMMIT_FROM="$(git rev-list --max-parents=0 HEAD)"
COMMIT_TO="$(git rev-parse HEAD)"

cat > "$RUNTIME_FILE" <<EOF
export AGIT_BIN="$BIN"
export AGIT_REPO_PATH="$WORKSPACE/repo"
export AGIT_HOME="$WORKSPACE/home"
export AGIT_SESSION_ID="$SESSION_ID"
export AGIT_STEP_HASH="$STEP_HASH"
export AGIT_COMMIT_FROM="$COMMIT_FROM"
export AGIT_COMMIT_TO="$COMMIT_TO"
export AGIT_OBSERVER_EXTRA="$WORKSPACE/observer-extra.jsonl"
export AGIT_BUNDLE_PATH="$WORKSPACE/bundle"
export AGIT_WATCH_SINCE="2000-01-01"
EOF

echo "Prepared VHS runtime at $RUNTIME_FILE"
