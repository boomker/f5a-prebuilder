#!/usr/bin/env bash
#
# Update the librime submodule to the tip of boomker/librime master and keep
# patches/librime.patch in sync, committing both in the same commit.
#
# Usage:
#   scripts/update-librime.sh [--fix-patch] [--push] [--dry-run]
#
#   --fix-patch  Try to adapt patches/librime.patch automatically with
#                `git apply --3way` and regenerate the patch file.
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

if git -C "$SUBMODULE" apply --check "../$PATCH" 2>/dev/null; then
  info "$PATCH applies cleanly"
else
  if [ "$FIX_PATCH" -eq 0 ]; then
    git -C "$SUBMODULE" apply --check "../$PATCH" || true
    die "$PATCH no longer applies at ${NEW_SHA:0:7}; re-run with --fix-patch or update the patch manually"
  fi

  info "$PATCH no longer applies; attempting a 3-way merge"
  if ! git -C "$SUBMODULE" apply --3way "../$PATCH"; then
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
