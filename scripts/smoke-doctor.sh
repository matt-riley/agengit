#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

HOME_DIR="${TMP_DIR}/home"
REPO_DIR="${TMP_DIR}/repo"
BIN_DIR="${TMP_DIR}/bin"
AGIT_BIN="${ROOT_DIR}/zig-out/bin/agit"
ORIG_PATH="${PATH}"

mkdir -p "${HOME_DIR}" "${REPO_DIR}" "${BIN_DIR}" "${REPO_DIR}/.agit" "${REPO_DIR}/src"

cat > "${BIN_DIR}/claude" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
cat > "${BIN_DIR}/codex" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
cat > "${BIN_DIR}/gemini" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod +x "${BIN_DIR}/claude" "${BIN_DIR}/codex" "${BIN_DIR}/gemini"

cat > "${REPO_DIR}/main.py" <<'EOF'
def factorial(n: int) -> int:
    if n < 0:
        raise ValueError("negative")
    if n in (0, 1):
        return 1
    return n * factorial(n - 1)
EOF

cat > "${REPO_DIR}/src/auth.py" <<'EOF'
def authenticate(user: str, token: str) -> bool:
    return bool(user) and bool(token)
EOF

cat > "${REPO_DIR}/src/main.go" <<'EOF'
package main

import "fmt"

func main() {
	fmt.Println("hello")
}
EOF

export HOME="${HOME_DIR}"
export PATH="${BIN_DIR}:${ORIG_PATH}"

# Keep smoke builds isolated from any pre-restored CI cache state.
export ZIG_GLOBAL_CACHE_DIR="${TMP_DIR}/zig-global-cache"
export ZIG_LOCAL_CACHE_DIR="${TMP_DIR}/zig-local-cache"
mkdir -p "${ZIG_GLOBAL_CACHE_DIR}" "${ZIG_LOCAL_CACHE_DIR}"

cd "${ROOT_DIR}"
zig build -Dsanitize-c=full >/dev/null

cd "${REPO_DIR}"
"${AGIT_BIN}" init >/dev/null

run_hook() {
    local cmd="$1"
    local payload="$2"
    printf '%s' "${payload}" | "${AGIT_BIN}" ${cmd} >/dev/null
}

CLAUDE_USER_PAYLOAD="$(cat <<EOF
{"session_id":"smoke-claude","transcript_path":"${HOME_DIR}/.claude/projects/smoke-claude.jsonl","cwd":"${REPO_DIR}","hook_event_name":"UserPromptSubmit","prompt":"Write factorial"}
EOF
)"
CLAUDE_TOOL_PAYLOAD="$(cat <<EOF
{"session_id":"smoke-claude","transcript_path":"${HOME_DIR}/.claude/projects/smoke-claude.jsonl","cwd":"${REPO_DIR}","hook_event_name":"PostToolBatch","tool_calls":[{"tool_name":"Read","tool_input":{"file_path":"${REPO_DIR}/main.py"},"tool_use_id":"toolu_smoke_1","tool_response":"def factorial(n: int) -> int:\\n    return 1\\n"},{"tool_name":"Bash","tool_input":{"command":"python3 -c 'print(120)'","timeout":5000},"tool_use_id":"toolu_smoke_2","tool_response":"120\\n"}]}
EOF
)"
CLAUDE_STOP_PAYLOAD="$(cat <<EOF
{"session_id":"smoke-claude","transcript_path":"${HOME_DIR}/.claude/projects/smoke-claude.jsonl","cwd":"${REPO_DIR}","hook_event_name":"Stop","last_assistant_message":"Done"}
EOF
)"

CODEX_USER_PAYLOAD="$(cat <<EOF
{"session_id":"smoke-codex","cwd":"${REPO_DIR}","hook_event_name":"UserPromptSubmit","prompt":"Refactor auth"}
EOF
)"
CODEX_TOOL_PAYLOAD="$(cat <<EOF
{"session_id":"smoke-codex","cwd":"${REPO_DIR}","hook_event_name":"PostToolUse","tool_name":"bash","tool_input":{"command":"cat src/auth.py"},"tool_use_id":"tool-001","tool_response":"def authenticate(user, token):\\n    return bool(user) and bool(token)\\n"}
EOF
)"
CODEX_STOP_PAYLOAD="$(cat <<EOF
{"session_id":"smoke-codex","cwd":"${REPO_DIR}","hook_event_name":"Stop","last_assistant_message":"JWT refactor complete"}
EOF
)"

GEMINI_TOOL_PAYLOAD="$(cat <<EOF
{"session_id":"smoke-gemini","cwd":"${REPO_DIR}","hook_event_name":"AfterTool","tool_name":"read_file","tool_input":{"path":"src/main.go"},"tool_response":"package main\\n"}
EOF
)"
GEMINI_AGENT_PAYLOAD="$(cat <<EOF
{"session_id":"smoke-gemini","cwd":"${REPO_DIR}","hook_event_name":"AfterAgent","response":"Updated the greeting"}
EOF
)"

run_hook "claude-hook user" "${CLAUDE_USER_PAYLOAD}"
run_hook "claude-tool-batch-hook" "${CLAUDE_TOOL_PAYLOAD}"
run_hook "claude-hook assistant" "${CLAUDE_STOP_PAYLOAD}"

run_hook "codex-hook" "${CODEX_USER_PAYLOAD}"
run_hook "codex-hook" "${CODEX_TOOL_PAYLOAD}"
run_hook "codex-hook" "${CODEX_STOP_PAYLOAD}"

run_hook "gemini-hook" "${GEMINI_TOOL_PAYLOAD}"
run_hook "gemini-hook" "${GEMINI_AGENT_PAYLOAD}"

DOCTOR_OUTPUT="$("${AGIT_BIN}" doctor)"
STATUS_OUTPUT="$("${AGIT_BIN}" status)"

printf '%s\n' "${DOCTOR_OUTPUT}" | grep -Fq "✓ .agit/ store: ok"
printf '%s\n' "${DOCTOR_OUTPUT}" | grep -Fq "✓ ref/index drift: none detected"
printf '%s\n' "${STATUS_OUTPUT}" | grep -Eq 'Sessions:[[:space:]]+3'
printf '%s\n' "${STATUS_OUTPUT}" | grep -Eq 'Steps:[[:space:]]+3'
