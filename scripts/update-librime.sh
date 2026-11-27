#!/usr/bin/env bash
#
# Update the librime submodule to the tip of boomker/librime master and keep
# patches/librime.patch in sync, committing both in the same commit.
#
# Usage:
#   scripts/update-librime.sh [--fix-patch] [--push] [--dry-run]
#
#   --fix-patch  Try to adapt patches/librime.patch automatically with
#                `git apply --3way` and regenerate the patch file.  Conflicting
#                hunks that only add lines are re-anchored on the new upstream
#                side, so upstream refactors of the surrounding code do not
#                force a manual patch edit.
#   --push       Push the resulting commit to origin.
#   --dry-run    Only report whether an update is available; change nothing.
#
# The submodule and the patch must always be committed together: CI checks
# that the patch applies to the pinned librime revision, so a pointer bump
# without the matching patch (or vice versa) fails the build.

set -euo pipefail

SUBMODULE=librime
PATCH=patches/librime.patch
UPSTREAM_BRANCH=master

FIX_PATCH=0
DO_PUSH=0
DRY_RUN=0

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

for arg in "$@"; do
  case "$arg" in
    --fix-patch) FIX_PATCH=1 ;;
    --push) DO_PUSH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

info() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) ||
  die "not inside a git repository"
cd "$REPO_ROOT"

[ -f "$PATCH" ] || die "$PATCH not found"

# --- preconditions -----------------------------------------------------------

git rev-parse --verify -q HEAD >/dev/null || die "repository has no commits"

if [ ! -e "$SUBMODULE/.git" ]; then
  info "initializing $SUBMODULE submodule"
  git submodule update --init -- "$SUBMODULE"
fi

if [ -n "$(git -C "$SUBMODULE" status --porcelain)" ]; then
  die "$SUBMODULE has uncommitted changes; commit them or run 'git -C $SUBMODULE checkout .' first"
fi

if ! git diff --quiet -- "$PATCH" || ! git diff --cached --quiet -- "$PATCH"; then
  die "$PATCH has uncommitted changes; commit or discard them first"
fi

if ! git diff --cached --quiet -- "$SUBMODULE"; then
  die "$SUBMODULE pointer is already staged; commit or reset it first"
fi

OLD_SHA=$(git -C "$SUBMODULE" rev-parse HEAD)

info "fetching boomker/librime $UPSTREAM_BRANCH"
git -C "$SUBMODULE" fetch --quiet origin "$UPSTREAM_BRANCH"
NEW_SHA=$(git -C "$SUBMODULE" rev-parse "origin/$UPSTREAM_BRANCH")

if [ "$OLD_SHA" = "$NEW_SHA" ]; then
  info "librime already at ${NEW_SHA:0:7}"
  git -C "$SUBMODULE" apply --check "../$PATCH" ||
    die "librime is up to date but $PATCH does not apply; fix the patch first"
  exit 0
fi

info "librime: ${OLD_SHA:0:7} -> ${NEW_SHA:0:7}"
git -C "$SUBMODULE" log --oneline --no-decorate "$OLD_SHA..$NEW_SHA" | sed 's/^/    /'

if [ "$DRY_RUN" -eq 1 ]; then
  info "dry run: no changes made"
  exit 0
fi

# --- update pointer ----------------------------------------------------------

MUTATED=1
COMMITTED=0

rollback() {
  set +e
  git -C "$SUBMODULE" reset -q --hard
  git -C "$SUBMODULE" clean -qfd
  git -C "$SUBMODULE" checkout -q --detach "$OLD_SHA"
  git reset -q HEAD -- "$SUBMODULE" "$PATCH"
  git checkout -q -- "$PATCH"
}

on_exit() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ "$MUTATED" -eq 1 ] && [ "$COMMITTED" -eq 0 ]; then
    warn "rolling back librime pointer and $PATCH"
    rollback
  fi
}
trap on_exit EXIT

git -C "$SUBMODULE" checkout -q --detach "$NEW_SHA"

# --- keep the patch applicable ----------------------------------------------

PATCH_CHANGED=0

# `git apply --3way` labels the checked-out revision ("ours") upstream and the
# patched result ("theirs") the patch.  Upstream routinely refactors the lines
# around the places we touch, which turns additive hunks into conflicts.  For
# those we keep the upstream side and re-attach only the added lines, anchored
# on the closest surviving context line.  Hunks that remove or rewrite upstream
# lines are never guessed at: they abort the script instead.

# Print the body of the patch section for a file relative to the submodule.
patch_section() {
  git show "HEAD:$PATCH" | awk -v f="$1" '
    /^diff --git / { inside = ($3 == "a/" f); next }
    inside && !/^(index |--- |\+\+\+ )/ { print }
  '
}

# Insert the added lines of a purely additive patch section into an existing
# file, anchoring each block after the last context line that precedes it.
resolve_additive_hunks() {
  local file=$1 section=$2
  local target="$SUBMODULE/$file" plan merged

  plan=$(mktemp)
  merged=$(mktemp)

  # one plan line per block: <anchor text><US><added line><US><added line>...
  if ! printf '%s\n' "$section" | awk -v plan="$plan" '
      function emit() {
        if (fail || inblock == 0) return
        if (anchor == "") { fail = 1; return }
        printf "%s", anchor >> plan
        n = split(block, parts, "\001")
        for (i = 1; i <= n; i++) printf "\001%s", parts[i] >> plan
        printf "\n" >> plan
        block = ""
        inblock = 0
      }
      BEGIN { fail = 0; inblock = 0; block = "" }
      /^@@/ { emit(); anchor = ""; inblock = 0; next }
      /^\+/ {
        block = block (inblock ? "\001" : "") substr($0, 2)
        inblock = 1
        next
      }
      /^ / { emit(); anchor = substr($0, 2); next }
      /^-/ { fail = 1; exit 1 }
      END { emit(); if (fail) exit 1 }
    '; then
    rm -f "$plan" "$merged"
    return 1
  fi

  if ! awk -v plan="$plan" '
      BEGIN {
        np = 0
        while ((getline line < plan) > 0) {
          np++
          m = split(line, parts, "\001")
          anchors[np] = parts[1]
          trimmed[np] = parts[1]
          sub(/^[ \t]+/, "", trimmed[np])
          cnt[np] = m - 1
          for (i = 2; i <= m; i++) body[np, i - 1] = parts[i]
        }
        close(plan)
        nlines = 0
      }
      { lines[++nlines] = $0 }
      END {
        for (i = 1; i <= np; i++) {
          if (anchors[i] == "") exit 1
          at[i] = 0
          hits = 0
          for (k = 1; k <= nlines; k++) {
            if (index(lines[k], anchors[i]) == 1 ||
                index(lines[k], trimmed[i]) == 1) {
              at[i] = k
              hits++
            }
          }
          if (hits == 0) {
            # Upstream may extend the anchor (extra arguments, flags, ...), so
            # fall back to the first word, which carries the target/identifier.
            tok = trimmed[i]
            sub(/[ \t].*/, "", tok)
            for (k = 1; k <= nlines; k++) {
              t = lines[k]
              sub(/^[ \t]+/, "", t)
              if (index(t, tok) == 1) {
                at[i] = k
                hits++
              }
            }
          }
          if (hits != 1) exit 1
        }
        for (k = 1; k <= nlines; k++) {
          print lines[k]
          for (i = 1; i <= np; i++)
            if (at[i] == k)
              for (j = 1; j <= cnt[i]; j++) print body[i, j]
        }
      }
    ' "$target" >"$merged"; then
    rm -f "$plan" "$merged"
    return 1
  fi

  mv "$merged" "$target"
  rm -f "$plan"
}

# Resolve the conflicts `git apply --3way` left behind, or fail.
resolve_conflicts() {
  local conflicted file section
  conflicted=$(git -C "$SUBMODULE" diff --name-only --diff-filter=U)
  [ -n "$conflicted" ] || return 1

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    section=$(patch_section "$file")
    [ -n "$section" ] || { warn "no patch section for $file"; return 1; }

    if ! printf '%s\n' "$section" | awk '/^-/ { exit 1 }'; then
      warn "$file conflicts on lines the patch rewrites; refusing to guess"
      return 1
    fi

    git -C "$SUBMODULE" checkout --ours -- "$file" ||
      { warn "cannot restore the upstream version of $file"; return 1; }
    if ! resolve_additive_hunks "$file" "$section"; then
      warn "cannot re-anchor the added lines of $file"
      return 1
    fi
    if awk '/^(<<<<<<<|=======|>>>>>>>)/ { found = 1 } END { exit !found }' \
      "$SUBMODULE/$file"; then
      warn "$file still contains conflict markers"
      return 1
    fi
    git -C "$SUBMODULE" add -- "$file"
    info "resolved $file: kept upstream and re-applied the added lines"
  done <<<"$conflicted"
}

if git -C "$SUBMODULE" apply --check "../$PATCH" 2>/dev/null; then
  info "$PATCH applies cleanly"
else
  if [ "$FIX_PATCH" -eq 0 ]; then
    git -C "$SUBMODULE" apply --check "../$PATCH" || true
    die "$PATCH no longer applies at ${NEW_SHA:0:7}; re-run with --fix-patch or update the patch manually"
  fi

  info "$PATCH no longer applies; attempting a 3-way merge"
  set +e
  git -C "$SUBMODULE" apply --3way "../$PATCH"
  merge_status=$?
  set -e
  if [ "$merge_status" -ne 0 ]; then
    resolve_conflicts ||
      die "3-way merge failed; resolve the conflicts manually and regenerate $PATCH"
  fi

  git -C "$SUBMODULE" diff HEAD >"$PATCH"
  git -C "$SUBMODULE" reset -q --hard
  git -C "$SUBMODULE" clean -qfd
  PATCH_CHANGED=1

  # Make sure no hunk/file was silently dropped by the 3-way merge.
  old_files=$(git show "HEAD:$PATCH" |
    sed -n 's|^diff --git a/\(.*\) b/.*|\1|p' | sort)
  new_files=$(sed -n 's|^diff --git a/\(.*\) b/.*|\1|p' "$PATCH" | sort)
  [ -n "$new_files" ] || die "regenerated patch is empty"
  if [ "$old_files" != "$new_files" ]; then
    die "regenerated patch touches a different set of files than the original:
--- old ---
$old_files
--- new ---
$new_files"
  fi

  git -C "$SUBMODULE" apply --check "../$PATCH" ||
    die "regenerated patch does not apply cleanly; review $PATCH manually"

  info "regenerated $PATCH; review it with: git diff -- $PATCH"
fi

# --- commit ------------------------------------------------------------------

BRANCH=$(git branch --show-current)
[ -n "$BRANCH" ] || die "not on a branch; refusing to commit"

git add -- "$SUBMODULE" "$PATCH"

if [ "$PATCH_CHANGED" -eq 1 ]; then
  git commit -q -m "chore: update librime to ${NEW_SHA:0:7}" \
    -m "Adapt $PATCH to the new revision."
else
  git commit -q -m "chore: update librime to ${NEW_SHA:0:7}"
fi
COMMITTED=1

info "committed: $(git log -1 --format='%h %s')"

# --- push --------------------------------------------------------------------

if [ "$DO_PUSH" -eq 1 ]; then
  info "pushing to origin/$BRANCH"
  git push origin "HEAD:$BRANCH"
else
  info "not pushed; run 'git push origin $BRANCH' when ready"
fi
