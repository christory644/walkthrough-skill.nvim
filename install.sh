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

# An install this script made before the bundle became self-contained: a real
# directory at $1 whose every entry is one of our own symlinks. That shape is
# the bug we are fixing (harness scanners want a symlinked folder, not a real
# folder of links), it is unambiguously ours, and refusing it would strand
# every existing user behind a manual `rm`. So replace it - but only when
# nothing in it could belong to anyone else, and never quietly: an installer
# that deletes a directory says which one and why.
shed_legacy_bundle() {
  target="$1"
  [ -d "$target" ] && [ ! -L "$target" ] || return 0
  entries=0
  for e in "$target"/* "$target"/.[!.]* "$target"/..?*; do
    # An unmatched glob stays literal; a broken symlink fails -e but not -L.
    [ -e "$e" ] || [ -L "$e" ] || continue
    [ -L "$e" ] || return 0
    case "${e##*/}" in
      SKILL.md|bin|backends|lua|schema.json) entries=$((entries + 1)) ;;
      *) return 0 ;;
    esac
  done
  [ "$entries" -gt 0 ] || return 0
  echo "walkthrough: replacing the previous per-file bundle at $target" >&2
  echo "  It was a real directory of symlinks, which some harnesses skip;" >&2
  echo "  a single symlinked folder is the shape they all discover." >&2
  rm -rf "$target"
}

# A skill is a directory, and a harness discovers it by scanning for one. The
# parts that make up this one live at the repository root (bin/, backends/,
# lua/, schema.json) with SKILL.md under skills/walkthrough/, so step one is to
# make that one directory self-contained - by symlink, so nothing is copied and
# editing the checkout still edits the installed skill. These links are
# RELATIVE, so moving the checkout leaves the bundle intact and only the
# ~/.agents link below needs re-pointing.
BUNDLE="$REPO/skills/walkthrough"
bundle_ok=1
for part in bin backends lua schema.json; do
  link_or_refuse "$BUNDLE/$part" "../../$part" || bundle_ok=0
done

# Step two: publish the whole bundle as ONE symlink. Codex documents support
# for a symlinked skill folder and skips a real folder of per-file links, so
# the old shape let a session read SKILL.md while never being offered the skill.
DEST=~/.agents/skills/walkthrough
mkdir -p "$(dirname "$DEST")"
shed_legacy_bundle "$DEST"
if [ "$bundle_ok" -eq 1 ] && link_or_refuse "$DEST" "$BUNDLE"; then
  echo "skill  -> $DEST -> $BUNDLE (CLI, backends, renderer)"
elif [ "$bundle_ok" -ne 1 ]; then
  echo "skill  -> not published; the bundle is incomplete, see refusals above" >&2
fi

# Harness config directories, for the older clients that search only their own.
#
# $CODEX_HOME and $CLAUDE_CONFIG_DIR are the authoritative statement of where a
# harness lives, so they are honoured outright and created when absent - a user
# who set one has told us the answer. Everything else must already exist: the
# named-profile variants are globbed (~/.codex-work, ~/.claude-personal) rather
# than enumerated, so a new profile needs no change here, but a guess never
# conjures a directory. `-d` also keeps the glob off ~/.claude.json and its
# backups.
harness_dirs() {
  for v in "${CODEX_HOME:-}" "${CLAUDE_CONFIG_DIR:-}"; do
    [ -n "$v" ] || continue
    case "$v" in
      /*) printf '%s\n' "${v%/}" ;;
      *)  echo "walkthrough: ignoring a relative harness path: $v" >&2 ;;
    esac
  done
  for p in ~/.claude ~/.claude-* ~/.codex ~/.codex-* ~/.cursor ~/.cursor-*; do
    [ -d "$p" ] && printf '%s\n' "$p"
  done
  return 0
}

# awk dedupes: $CLAUDE_CONFIG_DIR is usually also matched by the glob.
while IFS= read -r p; do
  # A failure here (permissions, read-only mount, ...) is not the quiet
  # "this harness isn't installed" case and must be reported, not swallowed.
  err="$(mkdir -p "$p/skills" 2>&1)" || {
    echo "walkthrough: failed to create $p/skills" >&2
    echo "  $err" >&2
    failures=$((failures + 1))
    continue
  }
  # Relative for a direct child of $HOME, so the link survives the whole home
  # directory moving. Anywhere else - an explicit $CODEX_HOME under /opt, a
  # nested config path - ../.. does not lead to ~/.agents, so use the real one.
  case "$p" in
    "$HOME"/*/*) src="$DEST" ;;
    "$HOME"/*)   src="../../.agents/skills/walkthrough" ;;
    *)           src="$DEST" ;;
  esac
  if link_or_refuse "$p/skills/walkthrough" "$src"; then
    echo "skill  -> $p/skills/walkthrough"
  fi
done < <(harness_dirs | awk '!seen[$0]++')

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
