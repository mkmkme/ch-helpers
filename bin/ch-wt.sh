#!/usr/bin/env bash
#
# Create a ClickHouse git worktree with submodules hardlinked from the main repo.
# Gives each worktree independent submodule copies without network access or extra
# disk space for git objects.
#
# Usage: ch-wt.sh [-b|--base <ref>] <branch-name> [worktree-path]
#
# If the branch exists (locally or on origin), it is checked out.
# If it doesn't exist, a new branch is created from the current HEAD, or from
# the branch, tag, or commit given by -b/--base. The base must be available locally.
# Using --base with an existing branch is an error.
#
# The default worktree path is ../<repo-name>-<branch> (sibling directory).
# Slashes in branch names are replaced with dashes in the default path.
#
# Prerequisites: submodules must already be cloned in the main repo
# (git submodule update --init must have been run at least once).

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

# 1. Determine the source repo.
MAIN_REPO=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "not inside a git repository"
MAIN_REPO_NAME=$(basename "$MAIN_REPO")

# 2. Validate inputs.
BASE=HEAD
BASE_SET=false
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -b|--base)
            [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a ref"
            BASE="$2"
            BASE_SET=true
            shift 2
            ;;
        --)
            shift
            POSITIONAL+=("$@")
            break
            ;;
        -*) die "unknown option: $1" ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done

BRANCH="${POSITIONAL[0]:-}"
[ -n "$BRANCH" ] && [ "${#POSITIONAL[@]}" -le 2 ] \
    || die "usage: $0 [-b|--base <ref>] <branch-name> [worktree-path]"

SAFE_BRANCH="${BRANCH//\//-}"

if [ -n "${POSITIONAL[1]:-}" ]; then
    WORKTREE_PATH=$(realpath -m "${POSITIONAL[1]}")
else
    WORKTREE_PATH=$(realpath -m "$MAIN_REPO/../${MAIN_REPO_NAME}-${SAFE_BRANCH}")
fi

# 3. Check preconditions.
[ ! -e "$WORKTREE_PATH" ] \
    || die "worktree path already exists: $WORKTREE_PATH"

GIT_DIR=$(git -C "$MAIN_REPO" rev-parse --git-common-dir)
[ -d "$GIT_DIR/modules" ] \
    || die "no submodule data found in $GIT_DIR/modules — run 'git submodule update --init' in the main repo first"

LOCAL=$(git -C "$MAIN_REPO" branch --list "$BRANCH")
REMOTE=$(git -C "$MAIN_REPO" branch --list -r "origin/$BRANCH")

if [ "$BASE_SET" = true ]; then
    [ -z "$LOCAL" ] && [ -z "$REMOTE" ] \
        || die "--base cannot be used with existing branch '$BRANCH'"
    git -C "$MAIN_REPO" rev-parse --verify --end-of-options "${BASE}^{commit}" >/dev/null 2>&1 \
        || die "base does not resolve to a commit: $BASE"
fi

# 4. Create the worktree.
if [ -n "$LOCAL" ]; then
    echo "Branch '$BRANCH' exists locally — checking out."
    git -C "$MAIN_REPO" worktree add "$WORKTREE_PATH" "$BRANCH"
elif [ -n "$REMOTE" ]; then
    echo "Branch '$BRANCH' exists on remote — creating local tracking branch."
    git -C "$MAIN_REPO" worktree add "$WORKTREE_PATH" -b "$BRANCH" "origin/$BRANCH"
else
    echo "Branch '$BRANCH' does not exist — creating new branch from $BASE."
    git -C "$MAIN_REPO" worktree add -b "$BRANCH" "$WORKTREE_PATH" "$BASE"
fi

# 5. Set up submodules via hardlinks.
WORKTREE_ENTRY=$(basename "$WORKTREE_PATH")

echo "Hardlinking submodule data..."
cp -al "$GIT_DIR/modules" \
       "$GIT_DIR/worktrees/$WORKTREE_ENTRY/modules"

# Fix worktree pointers in submodule configs — they still reference the main repo.
find "$GIT_DIR/worktrees/$WORKTREE_ENTRY/modules" -name config -exec \
    sed -i "s|worktree = .*/contrib/|worktree = $WORKTREE_PATH/contrib/|" {} +

# Some submodules (e.g. contrib/boost) store core.worktree in config.worktree
# instead of config. Fix those too.
find "$GIT_DIR/worktrees/$WORKTREE_ENTRY/modules" -name config.worktree -exec \
    sed -i "s|worktree = .*/contrib/|worktree = $WORKTREE_PATH/contrib/|" {} +

echo "Registering submodules (fetching missing commits if needed)..."
git -C "$WORKTREE_PATH" submodule update --init

echo "Populating submodule working trees..."
git -C "$WORKTREE_PATH" submodule foreach \
    '(git read-tree HEAD && git checkout -- .) 2>/dev/null || echo "SKIP: $name"'

# 6. Report results.
echo ""
echo "Worktree created successfully."
echo "  Source repo:  $MAIN_REPO"
echo "  Worktree:     $WORKTREE_PATH"
echo "  Branch:       $BRANCH"
echo ""
echo "  cd $WORKTREE_PATH"
