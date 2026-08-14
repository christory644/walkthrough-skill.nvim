#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0

# Build the bundle the way install.sh publishes it
BUNDLE="$(mktemp -d)/walkthrough"
mkdir -p "$BUNDLE"
cp -R skills/walkthrough/SKILL.md bin backends lua schema.json "$BUNDLE"/

for want in SKILL.md bin/walkthrough backends/common.sh lua/walkthrough/init.lua schema.json; do
  [ -e "$BUNDLE/$want" ] || { echo "  FAIL: bundle missing $want"; fail=1; }
done

# the bundled CLI must work with no plugin installed anywhere
if out=$("$BUNDLE/bin/walkthrough" validate tests/fixtures/two_files.tour 2>&1); then
  :
else
  echo "  FAIL: bundled CLI cannot validate: $out"
  fail=1
fi

"$BUNDLE/bin/walkthrough" schema | grep -q '"steps"' \
  || { echo "  FAIL: bundled schema unreadable"; fail=1; }

rm -rf "$(dirname "$BUNDLE")"

# ---------------------------------------------------------------------------
# install.sh
#
# The first command every user runs, and until now covered by no test at all:
# the bundle checks above build their own copy with `cp -R` and never invoke the
# installer, so deleting its entire clobber refusal left this suite green.
#
# Every case below runs against a SCRATCH HOME. The installer writes symlinks
# into ~/.agents and ~/.claude and friends, so pointing it at the developer's
# real home to test it would mean rewriting their actual install — including the
# refusal cases, whose whole point is that something is already there.
#
# A scratch HOME is NOT sufficient on its own. The installer honours
# $CODEX_HOME and $CLAUDE_CONFIG_DIR wherever they point, which is the correct
# behaviour for a user and an escape hatch out of the sandbox for a test: this
# suite really did replace a developer's live ~/.claude-personal link with one
# into a temp directory that then got deleted. Clear both for every run, and
# set them deliberately in the cases that are about them.
# ---------------------------------------------------------------------------
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAIL: $1 (want $2, got $3)"; fail=1; fi }
install_scratch() { env -u CODEX_HOME -u CLAUDE_CONFIG_DIR HOME="$HOME_SCRATCH" "$@" ./install.sh; }

HOME_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/walkthrough-home.XXXXXX")" || exit 1
# Somewhere that is deliberately NOT under the scratch home, for the case where
# a harness home lives outside $HOME entirely.
OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/walkthrough-outside.XXXXXX")" || exit 1
trap 'rm -rf "$HOME_SCRATCH" "$OUTSIDE"' EXIT
DEST="$HOME_SCRATCH/.agents/skills/walkthrough"
# pwd -P so a $TMPDIR or checkout reached through a symlink compares equal to
# the physical path a resolved link lands on.
REPO_P="$(pwd -P)"

install_scratch >/dev/null 2>&1
check "install: a fresh install exits 0" "0" "$?"

# ---------------------------------------------------------------------------
# The installed SHAPE.
#
# Everything above this line asks what the bundle CONTAINS. Nothing asked how
# it is INSTALLED, which is exactly why we shipped a layout Codex will not
# discover: a real directory holding per-file symlinks. Codex documents support
# for a symlinked skill FOLDER, so its scanner skipped us, and a session could
# read SKILL.md while never being offered the skill. These assertions describe
# what a harness scanner sees.
# ---------------------------------------------------------------------------
check "install: the installed skill path is a symlink" "yes" \
  "$( [ -L "$DEST" ] && echo yes || echo no )"
check "install: ...resolving to a directory" "yes" \
  "$( [ -d "$DEST/" ] && echo yes || echo no )"
check "install: ...that holds a REGULAR SKILL.md, not another link" "yes" \
  "$( [ -f "$DEST/SKILL.md" ] && [ ! -L "$DEST/SKILL.md" ] && echo yes || echo no )"
check "install: ...and lands inside this checkout" "$REPO_P/skills/walkthrough" \
  "$( cd "$DEST" 2>/dev/null && pwd -P )"

# Self-contained THROUGH that one link: a scanner that opens the folder must
# find the whole tool, not just the instructions.
inside=0
for part in SKILL.md bin/walkthrough backends/common.sh lua/walkthrough/init.lua schema.json; do
  [ -e "$DEST/$part" ] || { echo "    $part unreachable through the installed link"; inside=1; }
done
check "install: the whole bundle resolves through that one link" "0" "$inside"

# The in-repo half of the bundle is linked relatively, so moving the checkout
# leaves it intact and only the ~/.agents link needs re-pointing.
check "install: the in-repo bundle links are relative" "../../bin" \
  "$(readlink skills/walkthrough/bin)"
check "install: ...and resolve to the checkout's own directories" "$REPO_P/bin" \
  "$( cd skills/walkthrough/bin 2>/dev/null && pwd -P )"

check "install: the bundled CLI runs from the installed path" "0" \
  "$( "$DEST/bin/walkthrough" validate tests/fixtures/two_files.tour >/dev/null 2>&1; echo $? )"

install_scratch >/dev/null 2>&1
check "install: re-running over its own symlinks is idempotent" "0" "$?"
check "install: ...and the link still lands inside this checkout" "$REPO_P/skills/walkthrough" \
  "$( cd "$DEST" 2>/dev/null && pwd -P )"

# An older client's own skills directory gets a relative link to the bundle.
mkdir -p "$HOME_SCRATCH/.claude"
install_scratch >/dev/null 2>&1
check "install: an older client directory is linked too" "0" "$?"
check "install: ...by a relative link to the bundle" "../../.agents/skills/walkthrough" \
  "$(readlink "$HOME_SCRATCH/.claude/skills/walkthrough")"

# ---------------------------------------------------------------------------
# WHICH harness directories.
#
# The list used to be six hardcoded paths. A real machine has ~/.codex,
# ~/.codex-work and ~/.codex-personal, and only the first was on it — so a user
# running Codex under a named profile got no link at all, and $CODEX_HOME, the
# one authoritative answer to "where does this harness live", was never read.
# ---------------------------------------------------------------------------
mkdir -p "$HOME_SCRATCH/.codex-personal"
install_scratch >/dev/null 2>&1
check "install: a named profile home is found by glob, not by list" \
  "../../.agents/skills/walkthrough" \
  "$(readlink "$HOME_SCRATCH/.codex-personal/skills/walkthrough")"

# A guess never conjures a directory; only an explicit env var does.
check "install: ...but an absent harness directory is not created" "no" \
  "$( [ -e "$HOME_SCRATCH/.codex-imaginary" ] && echo yes || echo no )"

# $CODEX_HOME is a statement, not a guess: honour it even before it exists.
install_scratch CODEX_HOME="$HOME_SCRATCH/.codex-work" >/dev/null 2>&1
check "install: \$CODEX_HOME is honoured, and created if absent" \
  "../../.agents/skills/walkthrough" \
  "$(readlink "$HOME_SCRATCH/.codex-work/skills/walkthrough")"
install_scratch CLAUDE_CONFIG_DIR="$HOME_SCRATCH/.claude-elsewhere" >/dev/null 2>&1
check "install: \$CLAUDE_CONFIG_DIR is honoured too" \
  "../../.agents/skills/walkthrough" \
  "$(readlink "$HOME_SCRATCH/.claude-elsewhere/skills/walkthrough")"

# A harness home outside $HOME cannot use the ../../ relative form — that walks
# out of somewhere else entirely. It gets the real path instead.
install_scratch CODEX_HOME="$OUTSIDE/codex" >/dev/null 2>&1
check "install: a harness home outside \$HOME gets an absolute link" "$DEST" \
  "$(readlink "$OUTSIDE/codex/skills/walkthrough")"
check "install: ...which actually resolves" "yes" \
  "$( [ -f "$OUTSIDE/codex/skills/walkthrough/SKILL.md" ] && echo yes || echo no )"

# A relative $CODEX_HOME would have mkdir'd against the cwd — the checkout.
inst_err="$(install_scratch CODEX_HOME=relative-please 2>&1 >/dev/null)"
printf %s "$inst_err" | grep -q 'relative harness path'
check "install: a relative harness path is refused by name" "0" "$?"
check "install: ...and creates nothing in the checkout" "no" \
  "$( [ -e relative-please ] && echo yes || echo no )"

# An install made by an older version of this script: a real directory whose
# every entry is one of our own symlinks. That is the broken shape, it is
# unambiguously ours, and refusing it would strand every existing user behind a
# manual `rm`. Replace it — and say so, because silently deleting a directory
# is not something an installer should do quietly.
# ${DEST:?} so a DEST that somehow came out empty deletes nothing at all.
rm -rf "${DEST:?}"
mkdir -p "$DEST"
for part in skills/walkthrough/SKILL.md bin backends lua schema.json; do
  ln -s "$REPO_P/$part" "$DEST/$(basename "$part")"
done
inst_err="$(install_scratch 2>&1 >/dev/null)"
check "install: a legacy per-file install is upgraded, not refused" "0" "$?"
check "install: ...leaving a symlink where the directory was" "yes" \
  "$( [ -L "$DEST" ] && echo yes || echo no )"
printf %s "$inst_err" | grep -q 'replacing the previous'
check "install: ...and saying what it replaced" "0" "$?"

# The refusal. `ln -sfn` pointed at a pre-existing real DIRECTORY links *inside*
# it rather than replacing it, and pointed at a pre-existing real FILE clobbers
# it without a word — both of which report success while leaving an install that
# does not work (or a file the user wanted). The installer must refuse by name.
# A directory holding anything that is not one of our links is not ours, and
# the migration above must not become a licence to delete it.
rm -rf "${DEST:?}"
mkdir -p "$DEST"
printf 'do not touch me\n' > "$DEST/sentinel.txt"
inst_err="$(install_scratch 2>&1 >/dev/null)"
check "install: a foreign directory at the skill path fails the install" "1" "$?"
printf %s "$inst_err" | grep -q 'refusing to touch'
check "install: ...saying it refuses to touch it" "0" "$?"
printf %s "$inst_err" | grep -qF "$DEST"
check "install: ...and naming the path" "0" "$?"
check "install: ...leaving what was there alone" "do not touch me" \
  "$(cat "$DEST/sentinel.txt" 2>/dev/null)"
check "install: ...and never nesting the link inside it" "no" \
  "$( [ -e "$DEST/walkthrough" ] && echo yes || echo no )"
rm -rf "${DEST:?}"

# The same refusal for a real FILE, on the older-client path, where the clobber
# would have been silent.
rm -f "$HOME_SCRATCH/.claude/skills/walkthrough"
printf 'someone elses skill\n' > "$HOME_SCRATCH/.claude/skills/walkthrough"
inst_err="$(install_scratch 2>&1 >/dev/null)"
check "install: a real file in the way makes the install fail" "1" "$?"
printf %s "$inst_err" | grep -q 'refusing to touch'
check "install: ...saying it refuses to touch it" "0" "$?"
check "install: ...leaving the file exactly as it was" "someone elses skill" \
  "$(cat "$HOME_SCRATCH/.claude/skills/walkthrough" 2>/dev/null)"

[ "$fail" -eq 0 ] && echo "SKILL BUNDLE PASSED"
exit "$fail"
