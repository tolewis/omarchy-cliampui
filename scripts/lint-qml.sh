#!/usr/bin/env bash
# Lint every *.qml at the repo root with qmllint.
# Not recursive: .worktrees and subdirs are out of scope.
set -u

cd "$(dirname "$0")/.."

SHELL_INC=""
if [ -d /usr/share/omarchy/shell ]; then
  SHELL_INC="-I /usr/share/omarchy/shell"
fi

ALLOWLIST=".qml-lint-allowlist"
failed=0
status=0
qfiles=0

shopt -s nullglob
for f in *.qml; do
  qfiles=$((qfiles + 1))

  if [ -f "$ALLOWLIST" ]; then
    skip=""
    while IFS= read -r entry; do
      case "$entry" in
        ""|\#*) continue ;;
      esac
      case "$f" in
        *"$entry"*) skip=1 ;;
      esac
    done < "$ALLOWLIST"
    [ -n "${skip:-}" ] && continue
  fi

  # shellcheck disable=SC2086
  if out=$(qmllint $SHELL_INC "$f" 2>&1); then
    [ -n "$out" ] && printf '%s: %s\n' "$f" "$out"
  else
    failed=$((failed + 1))
    printf 'FAIL: %s\n' "$f"
    printf '%s\n' "$out"
    status=1
  fi
done
shopt -u nullglob

if [ "$qfiles" -eq 0 ]; then
  echo "lint-qml: no *.qml files found at repo root" >&2
  exit 2
fi

echo "lint-qml: $((qfiles - failed))/$qfiles clean, $failed failed"
exit "$status"