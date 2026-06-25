#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VHS_DIR="$ROOT/docs/vhs"
TAPES_DIR="$VHS_DIR/tapes"
IMAGES_DIR="$VHS_DIR/images"
COMMANDS_FILE="$VHS_DIR/commands.tsv"
RUNTIME_FILE="./docs/vhs/runtime.env"

if ! command -v vhs >/dev/null 2>&1; then
  echo "vhs is required. Install with: brew install vhs" >&2
  exit 1
fi

"$VHS_DIR/prepare-runtime.sh"
# prepare-runtime.sh starts a background fake S3 server for the push/pull
# tapes; ensure it is always cleaned up, even if rendering fails.
cleanup_fake_s3() {
  if [[ -f "$ROOT/docs/vhs/runtime.env" ]]; then
    # shellcheck disable=SC1090
    source "$ROOT/docs/vhs/runtime.env"
    if [[ -n "${AGIT_FAKE_S3_PID:-}" ]]; then
      kill "$AGIT_FAKE_S3_PID" 2>/dev/null || true
    fi
  fi
}
trap cleanup_fake_s3 EXIT

mkdir -p "$TAPES_DIR" "$IMAGES_DIR"
rm -f "$TAPES_DIR"/*.tape "$IMAGES_DIR"/*.gif "$IMAGES_DIR"/*.mp4
cd "$ROOT"

while IFS=$'\t' read -r slug command mode; do
  [[ -z "${slug:-}" ]] && continue

  tape_file="$TAPES_DIR/$slug.tape"
  video_file="./docs/vhs/images/$slug.mp4"

  cat > "$tape_file" <<EOF
Output "$video_file"
Set Shell "bash"
Set Width 1200
Set Height 720
Set FontSize 16
Set TypingSpeed 65ms

Hide
Type "source $RUNTIME_FILE"
Enter
Type "cd \$AGIT_REPO_PATH"
Enter
Sleep 500ms
Show
Type "$command"
Sleep 500ms
Enter
EOF

  if [[ "$mode" == "interrupt" ]]; then
    cat >> "$tape_file" <<'EOF'
Sleep 3s
Ctrl+C
Sleep 1s
EOF
  else
    cat >> "$tape_file" <<'EOF'
Sleep 3s
EOF
  fi

  vhs "$tape_file" >/dev/null
  echo "Rendered $slug"
done < "$COMMANDS_FILE"

cleanup_fake_s3
trap - EXIT

echo "Rendered $(ls -1 "$IMAGES_DIR"/*.mp4 | wc -l | tr -d ' ') videos to $IMAGES_DIR"
