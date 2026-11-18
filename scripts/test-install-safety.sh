#!/usr/bin/env bash
# Regression tests for installer safety fixes:
#   - copy mode backs up a destination the user edited instead of overwriting it
#   - re-installing over the installer's own copy makes no backup
#   - the wizard refuses an empty team selection instead of installing everything
#   - --parallel keeps arguments containing spaces intact
#   - an all-blank --tool value is reported, not a crash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$REPO_ROOT/scripts/install.sh"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export HOME="$scratch/home" TMPDIR="$scratch/tmp"
mkdir -p "$HOME" "$TMPDIR"
fail() { echo "FAIL: $*" >&2; exit 1; }

agent="$HOME/.claude/agents/engineering-frontend-developer.md"

# 1. Fresh install, then a re-install over our own copy: no backup.
bash "$INSTALL" --tool claude-code --agent frontend-developer --no-interactive > "$scratch/1.log" 2>&1
[[ -f "$agent" ]] || fail "agent not installed"
bash "$INSTALL" --tool claude-code --agent frontend-developer --no-interactive > "$scratch/2.log" 2>&1
compgen -G "$agent.bak-*" > /dev/null && fail "backup made for the installer's own unchanged copy"

# 2. A stale copy written by this installer (upstream changed) is replaced without a backup.
printf 'older upstream version\n' > "$scratch/old.md"
sum="$(cksum < "$scratch/old.md" | awk '{print $1" "$2}')"
cp "$scratch/old.md" "$agent"
manifest="$HOME/.claude/agents/.agency-agents-installed"
awk -F'\t' '$2 != "engineering-frontend-developer.md"' "$manifest" > "$manifest.tmp"
printf '%s\t%s\n' "$sum" engineering-frontend-developer.md >> "$manifest.tmp"
mv "$manifest.tmp" "$manifest"
bash "$INSTALL" --tool claude-code --agent frontend-developer --no-interactive > "$scratch/3.log" 2>&1
compgen -G "$agent.bak-*" > /dev/null && fail "backup made for a stale installer-owned copy"
cmp -s "$agent" "$REPO_ROOT/engineering/engineering-frontend-developer.md" || fail "stale copy not refreshed"

# 3. A user edit is backed up before the file is replaced.
printf 'MY CUSTOM EDITS\n' >> "$agent"
bash "$INSTALL" --tool claude-code --agent frontend-developer --no-interactive > "$scratch/4.log" 2>&1
backup="$(compgen -G "$agent.bak-*" | head -n 1)" || fail "user edit was overwritten without a backup"
grep -q 'MY CUSTOM EDITS' "$backup" || fail "backup does not hold the user's edit"
grep -q 'Backed up 1 existing file' "$scratch/4.log" || fail "backup not reported"

# 4. Wizard: deselecting every team must not install everything.
rm -rf "$HOME/.claude/agents"; mkdir -p "$HOME/.claude/agents"
status=0
printf '\nn\n\n' | AGENCY_TUI_FORCE=1 bash "$INSTALL" --interactive > "$scratch/5.log" 2>&1 || status=$?
n="$(find "$HOME/.claude/agents" -name '*.md' | wc -l | tr -d ' ')"
[[ "$n" == 0 ]] || fail "empty team selection installed $n agents"

# 5. --parallel keeps a display name and a path with spaces intact.
dest="$scratch/my dir"
bash "$INSTALL" --tool claude-code --agent "Frontend Developer" --path "$dest" \
  --no-convert --parallel --jobs 2 > "$scratch/6.log" 2>&1 || { cat "$scratch/6.log"; fail "--parallel with spaces failed"; }
grep -q "in parallel" "$scratch/6.log" || fail "parallel path not exercised"
[[ -f "$dest/engineering-frontend-developer.md" ]] || fail "--parallel did not install into a path with spaces"

# 6. An all-blank --tool value reports "No tools selected" (bash 3.2 used to
#    die with "unbound variable" expanding the empty tool list).
bash "$INSTALL" --tool "," --no-interactive > "$scratch/7.log" 2>&1 || true
grep -q 'unbound variable' "$scratch/7.log" && fail "--tool ',' crashed with unbound variable"
grep -q 'No tools selected' "$scratch/7.log" || fail "--tool ',' did not report an empty selection"

[[ -z "$(ls -A "$TMPDIR")" ]] || fail "temp files leaked: $(ls -A "$TMPDIR")"
echo 'PASS: installer keeps user edits, refuses empty team selection, and passes parallel args intact'
