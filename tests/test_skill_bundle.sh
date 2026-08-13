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
# ---------------------------------------------------------------------------
check() { if [ "$2" = "$3" ]; then echo "  ok: $1"; else echo "  FAIL: $1 (want $2, got $3)"; fail=1; fi }

HOME_SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/walkthrough-home.XXXXXX")" || exit 1
trap 'rm -rf "$HOME_SCRATCH"' EXIT
DEST="$HOME_SCRATCH/.agents/skills/walkthrough"

HOME="$HOME_SCRATCH" ./install.sh >/dev/null 2>&1
check "install: a fresh install exits 0" "0" "$?"

linked=0
for part in SKILL.md bin backends lua schema.json; do
  [ -L "$DEST/$part" ] || { echo "    $part is not a symlink"; linked=1; }
done
check "install: every part of the bundle is a symlink" "0" "$linked"
check "install: the symlinks point into this checkout" "$PWD/bin" \
  "$(readlink "$DEST/bin")"
check "install: the bundled CLI runs from the installed path" "0" \
  "$( "$DEST/bin/walkthrough" validate tests/fixtures/two_files.tour >/dev/null 2>&1; echo $? )"

HOME="$HOME_SCRATCH" ./install.sh >/dev/null 2>&1
check "install: re-running over its own symlinks is idempotent" "0" "$?"
check "install: ...and the link still points into this checkout" "$PWD/bin" \
  "$(readlink "$DEST/bin")"

# An older client's own skills directory gets a relative link to the bundle.
mkdir -p "$HOME_SCRATCH/.claude"
HOME="$HOME_SCRATCH" ./install.sh >/dev/null 2>&1
check "install: an older client directory is linked too" "0" "$?"
check "install: ...by a relative link to the bundle" "../../.agents/skills/walkthrough" \
  "$(readlink "$HOME_SCRATCH/.claude/skills/walkthrough")"

# The refusal. `ln -sfn` pointed at a pre-existing real DIRECTORY links *inside*
# it rather than replacing it, and pointed at a pre-existing real FILE clobbers
# it without a word — both of which report success while leaving an install that
# does not work (or a file the user wanted). The installer must refuse by name.
rm -f "$DEST/bin"
mkdir -p "$DEST/bin"
printf 'do not touch me\n' > "$DEST/bin/sentinel.txt"
inst_err="$(HOME="$HOME_SCRATCH" ./install.sh 2>&1 >/dev/null)"
check "install: a real directory in the way makes the install fail" "1" "$?"
printf %s "$inst_err" | grep -q 'refusing to touch'
check "install: ...saying it refuses to touch it" "0" "$?"
printf %s "$inst_err" | grep -qF "$DEST/bin"
check "install: ...and naming the path" "0" "$?"
check "install: ...leaving what was there alone" "do not touch me" \
  "$(cat "$DEST/bin/sentinel.txt" 2>/dev/null)"
check "install: ...and never nesting the link inside it" "no" \
  "$( [ -e "$DEST/bin/bin" ] && echo yes || echo no )"
# ${DEST:?} so a DEST that somehow came out empty deletes nothing at all.
rm -rf "${DEST:?}/bin"

# The same refusal for a real FILE, on the older-client path, where the clobber
# would have been silent.
rm -f "$HOME_SCRATCH/.claude/skills/walkthrough"
printf 'someone elses skill\n' > "$HOME_SCRATCH/.claude/skills/walkthrough"
inst_err="$(HOME="$HOME_SCRATCH" ./install.sh 2>&1 >/dev/null)"
check "install: a real file in the way makes the install fail" "1" "$?"
printf %s "$inst_err" | grep -q 'refusing to touch'
check "install: ...saying it refuses to touch it" "0" "$?"
check "install: ...leaving the file exactly as it was" "someone elses skill" \
  "$(cat "$HOME_SCRATCH/.claude/skills/walkthrough" 2>/dev/null)"

[ "$fail" -eq 0 ] && echo "SKILL BUNDLE PASSED"
exit "$fail"
