#!/usr/bin/env bash
# Install the walkthrough skill and CLI.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failures=0

# Link $1 (a target path) to $2 (what it should point at). `ln -sfn` alone
# reports success in two ways that leave a broken install: pointed at a
# pre-existing real directory it links *inside* it instead of replacing it,
# and pointed at a pre-existing regular file it clobbers it with no warning.
# Refuse loudly instead - name the path, say what is there, say what to do -
# rather than claim success for a target that was actually skipped.
# A symlink already at $1 is safe to relink unconditionally: only this
# installer ever creates a symlink named "walkthrough" at these paths, so
# finding one there already is what a previous (or unmoved) install looks
# like, and relinking it is what keeps re-running this script idempotent.
link_or_refuse() {
  target="$1" src="$2"
  if [ -e "$target" ] && [ ! -L "$target" ]; then
    kind="a file"; [ -d "$target" ] && kind="a directory"
    echo "walkthrough: refusing to touch $target" >&2
    echo "  $kind already exists there and is not a symlink walkthrough made." >&2
    echo "  Remove or rename it yourself, then re-run install.sh." >&2
    failures=$((failures + 1))
    return 1
  fi
  err="$(ln -sfn "$src" "$target" 2>&1)" || {
    echo "walkthrough: failed to link $target -> $src" >&2
    echo "  $err" >&2
    failures=$((failures + 1))
    return 1
  }
  return 0
}

# A skill is a directory. Bundle the CLI, backends and renderer alongside
# SKILL.md so installing the skill installs the whole tool - the CLI adds the
# bundle to nvim's runtimepath itself, so no plugin install is required.
DEST=~/.agents/skills/walkthrough
mkdir -p "$DEST"
dest_ok=1
for part in skills/walkthrough/SKILL.md bin backends lua schema.json; do
  link_or_refuse "$DEST/$(basename "$part")" "$REPO/$part" || dest_ok=0
done
if [ "$dest_ok" -eq 1 ]; then
  echo "skill  -> $DEST (bundling CLI, backends, renderer)"
else
  echo "skill  -> $DEST incomplete; see refusals above" >&2
fi

# Older clients that only search their own directory.
for p in ~/.claude ~/.claude-personal ~/.claude-work ~/.claude-work-sub ~/.codex ~/.cursor; do
  [ -d "$p" ] || continue
  # Absent means this harness isn't installed - skip quietly. A failure here
  # (permissions, read-only mount, ...) is a different situation and must be
  # reported, not swallowed alongside the quiet case.
  err="$(mkdir -p "$p/skills" 2>&1)" || {
    echo "walkthrough: failed to create $p/skills" >&2
    echo "  $err" >&2
    failures=$((failures + 1))
    continue
  }
  if link_or_refuse "$p/skills/walkthrough" "../../.agents/skills/walkthrough"; then
    echo "skill  -> $p/skills/walkthrough"
  fi
done

echo
echo "Done. Ask your agent to walk you through your changes."
echo
echo "To drive it yourself, add the CLI to PATH:"
echo "  export PATH=\"$REPO/bin:\$PATH\""
echo
echo "This installs by symlink from $REPO - keep this checkout where it is."

if [ "$failures" -gt 0 ]; then
  echo
  echo "walkthrough: $failures target(s) could not be installed; see above." >&2
  exit 1
fi
