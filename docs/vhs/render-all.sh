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

mkdir -p "$TAPES_DIR" "$IMAGES_DIR"
rm -f "$TAPES_DIR"/*.tape "$IMAGES_DIR"/*.gif
cd "$ROOT"

while IFS=$'\t' read -r slug command mode; do
  [[ -z "${slug:-}" ]] && continue

  tape_file="$TAPES_DIR/$slug.tape"
  image_file="./docs/vhs/images/$slug.gif"

  cat > "$tape_file" <<EOF
Output "$image_file"
Set Shell "bash"
Set Width 1200
Set Height 720
Set FontSize 16
Set TypingSpeed 65ms

Type "source $RUNTIME_FILE"
Enter
Sleep 800ms
Type "cd \$AGIT_REPO_PATH"
Enter
Sleep 700ms
Type "HOME=\$AGIT_HOME $command"
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

echo "Rendered $(ls -1 "$IMAGES_DIR"/*.gif | wc -l | tr -d ' ') GIFs to $IMAGES_DIR"
