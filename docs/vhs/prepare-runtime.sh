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

# The seed observe run writes a checkpoint keyed to observer-seed.jsonl. The
# demo tape runs observe against observer-extra.jsonl (a different input path),
# which would trip the instance-mismatch guard. Drop the checkpoint so the
# tape's observe pass processes observer-extra.jsonl cleanly.
rm -f "$WORKSPACE/repo/.agit/observers/jsonl.json"

USER_PAYLOAD="$(jq -nc --arg cwd "$WORKSPACE/repo" '{"session_id":"sess-a","turn_id":"turn-1","cwd":$cwd,"hook_event_name":"UserPromptSubmit","model":"gpt-5-codex","prompt":"Refactor notes to support factorial docs"}')"
STOP_PAYLOAD="$(jq -nc --arg cwd "$WORKSPACE/repo" '{"session_id":"sess-a","turn_id":"turn-1","cwd":$cwd,"hook_event_name":"Stop","model":"gpt-5-codex","last_assistant_message":"Updated notes successfully"}')"

printf '%s\n' "$USER_PAYLOAD" | HOME="$WORKSPACE/home" "$BIN" codex-hook >/dev/null
printf "hello from model" > notes.txt
printf '%s\n' "$STOP_PAYLOAD" | HOME="$WORKSPACE/home" "$BIN" codex-hook >/dev/null

SESSION_ID="codex/sess-a"
STEP_HASH="$(HOME="$WORKSPACE/home" "$BIN" log --json "$SESSION_ID" | jq -r '.data.steps[0].hash' | head -n 1)"

if [[ -z "$SESSION_ID" || -z "$STEP_HASH" ]]; then
  echo "Failed to derive session/hash metadata for VHS tapes." >&2
  exit 1
fi

COMMIT_FROM="$(git rev-list --max-parents=0 HEAD)"
COMMIT_TO="$(git rev-parse HEAD)"

# Start an in-process fake S3 so the push/pull tapes demo a real round-trip
# instead of "no remotes configured". The server only listens on 127.0.0.1
# (agit rejects non-local HTTP endpoints), and is killed at the end of the
# render-all run by prepare-runtime's caller (see render-all.sh).
FAKE_S3_STORAGE="$WORKSPACE/fake-s3"
FAKE_S3_READY="$WORKSPACE/fake-s3.port"
FAKE_S3_SCRIPT="$ROOT/tests/e2e/support/fake_s3_server.py"
rm -rf "$FAKE_S3_STORAGE" "$FAKE_S3_READY"
python3 "$FAKE_S3_SCRIPT" "$FAKE_S3_STORAGE" "$FAKE_S3_READY" >/dev/null 2>&1 &
FAKE_S3_PID=$!
disown "$FAKE_S3_PID" || true

FAKE_S3_PORT=""
for _ in $(seq 1 200); do
  if [[ -f "$FAKE_S3_READY" ]]; then
    FAKE_S3_PORT="$(tr -d ' \r\n' < "$FAKE_S3_READY")"
    break
  fi
  sleep 0.01
done

if [[ -z "$FAKE_S3_PORT" ]]; then
  echo "fake S3 server failed to start for VHS push/pull tapes." >&2
  kill "$FAKE_S3_PID" 2>/dev/null || true
  exit 1
fi

FAKE_S3_ENDPOINT="http://127.0.0.1:$FAKE_S3_PORT"
cat > "$WORKSPACE/repo/.agit/config.json" <<EOF
{
  "version": 1,
  "remotes": [
    {
      "name": "backup",
      "endpoint": "$FAKE_S3_ENDPOINT",
      "bucket": "agit-demo",
      "region": "us-east-1",
      "access_key_env": "AGIT_S3_ACCESS_KEY",
      "secret_key_env": "AGIT_S3_SECRET_KEY"
    }
  ]
}
EOF

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
export AGIT_S3_ACCESS_KEY="test-access"
export AGIT_S3_SECRET_KEY="test-secret"
export AGIT_FAKE_S3_PID="$FAKE_S3_PID"
EOF

echo "Prepared VHS runtime at $RUNTIME_FILE (fake S3 on $FAKE_S3_ENDPOINT, pid $FAKE_S3_PID)"
