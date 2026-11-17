#!/usr/bin/env bash
#
# Create a ClickHouse git worktree with submodules hardlinked from the main repo.
# Gives each worktree independent submodule copies without network access or extra
# disk space for git objects.
#
# Usage: ch-wt.sh [-e|--existing] [-b|--base <ref>] <branch-name> [worktree-path]
#
# If the branch exists (locally or on origin), it is checked out.
# If it doesn't exist, a new branch is created from the current HEAD, or from
# the branch, tag, or commit given by -b/--base. The base must be available locally.
# Using --base with an existing branch is an error.
# Use -e/--existing to require a branch that exists locally or on origin.
# It cannot be combined with -b/--base.
#
# The default worktree path is ../<repo-name>-<branch> (sibling directory).
# Slashes in branch names are replaced with dashes in the default path.
#
# Prerequisites: submodules must already be cloned in the main repo
# (git submodule update --init must have been run at least once). Submodules
# are checked out at the commits the branch records, without network access.

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: ch-wt.sh [options] <branch-name> [worktree-path]

Create a Git worktree with submodule data hardlinked from the source repository.
Run from inside the source repository or one of its worktrees.

Options:
  -b, --base <ref>  Create a new branch from a local branch, remote-tracking ref,
                    tag, or commit instead of HEAD. Does not fetch the base ref.
  -e, --existing    Require a branch that exists locally or on origin; fail if
                    neither exists. Cannot be combined with --base.
  -h, --help        Show this help and exit.
  --                End option parsing.

Existing local branches are checked out. Branches found only on origin get a
local tracking branch. Otherwise, a new branch starts at the current HEAD.
Using --base with an existing branch is an error.

The default path is ../<source-repo-name>-<branch>, with branch slashes replaced
by dashes. An explicit worktree path is relative to the current directory.

Prerequisites: submodules must already be initialized in the source repository
(git submodule update --init), and hardlinks require the same filesystem.
Submodule setup never fetches; it fails if a recorded commit is missing.
EOF
}

# 1. Validate inputs.
BASE=HEAD
BASE_SET=false
EXISTING_ONLY=false
POSITIONAL=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -b|--base)
            [ "$#" -ge 2 ] && [ -n "$2" ] || die "$1 requires a ref"
            BASE="$2"
            BASE_SET=true
            shift 2
            ;;
        -e|--existing)
            EXISTING_ONLY=true
            shift
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
    || die "usage: $0 [-e|--existing] [-b|--base <ref>] <branch-name> [worktree-path]"

if [ "$EXISTING_ONLY" = true ] && [ "$BASE_SET" = true ]; then
    die "--existing cannot be combined with --base"
fi

# 2. Determine the source repo.
MAIN_REPO=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "not inside a git repository"
MAIN_REPO_NAME=$(basename "$MAIN_REPO")

SAFE_BRANCH="${BRANCH//\//-}"

if [ -n "${POSITIONAL[1]:-}" ]; then
    WORKTREE_PATH=$(realpath -m "${POSITIONAL[1]}")
else
    WORKTREE_PATH=$(realpath -m "$MAIN_REPO/../${MAIN_REPO_NAME}-${SAFE_BRANCH}")
fi

# 3. Check preconditions.
[ ! -e "$WORKTREE_PATH" ] \
    || die "worktree path already exists: $WORKTREE_PATH"

GIT_COMMON_DIR=$(git -C "$MAIN_REPO" rev-parse --git-common-dir)
case "$GIT_COMMON_DIR" in
    /*) GIT_DIR=$GIT_COMMON_DIR ;;
    *) GIT_DIR=$MAIN_REPO/$GIT_COMMON_DIR ;;
esac
[ -d "$GIT_DIR/modules" ] \
    || die "no submodule data found in $GIT_DIR/modules — run 'git submodule update --init' in the main repo first"

LOCAL=$(git -C "$MAIN_REPO" branch --list "$BRANCH")
REMOTE=$(git -C "$MAIN_REPO" branch --list -r "origin/$BRANCH")

if [ "$EXISTING_ONLY" = true ]; then
    [ -n "$LOCAL" ] || [ -n "$REMOTE" ] \
        || die "branch '$BRANCH' does not exist locally or on origin"
fi

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

echo "Registering submodules..."
git -C "$WORKTREE_PATH" submodule init

# Check out each submodule at the commit the superproject records, using only
# the hardlinked module data. A missing commit fails instead of fetching.
GITLINKS=$(git -C "$WORKTREE_PATH" ls-files -s |
    sed -n 's/^160000 \([0-9a-f]*\) 0\t\(.*\)$/\1 \2/p')

# The checkout below works from the gitlinks, not from .gitmodules as
# git submodule does. Stop if the two disagree.
GITLINK_COUNT=$(printf '%s' "$GITLINKS" | grep -c '^' || true)
SUBMODULE_COUNT=$(git -C "$WORKTREE_PATH" config --file .gitmodules \
    --get-regexp '^submodule\..*\.path$' | grep -c '^' || true)
[ "$GITLINK_COUNT" = "$SUBMODULE_COUNT" ] \
    || die "gitlink count $GITLINK_COUNT does not match .gitmodules count $SUBMODULE_COUNT"

echo "Checking out submodules..."
printf '%s\n' "$GITLINKS" |
    while read -r expected_commit submodule_path; do
        [ -n "$submodule_path" ] || continue
        module_git_dir="$GIT_DIR/worktrees/$WORKTREE_ENTRY/modules/$submodule_path"
        module_worktree="$WORKTREE_PATH/$submodule_path"
        mkdir -p "$module_worktree"
        printf 'gitdir: %s\n' "$module_git_dir" > "$module_worktree/.git"
        if ! git --git-dir="$module_git_dir" --work-tree="$module_worktree" \
            -c advice.detachedHead=false \
            checkout -q -f --detach "$expected_commit"
        then
            echo "error: $submodule_path: commit $expected_commit is missing from the local module data." >&2
            echo "Fetch it into the main repo, then create the worktree again:" >&2
            echo "    git -C $MAIN_REPO/$submodule_path fetch origin $expected_commit" >&2
            exit 1
        fi
    done \
    || die "a submodule could not be checked out at the recorded commit"

# 6. Report results.
echo ""
echo "Worktree created successfully."
echo "  Source repo:  $MAIN_REPO"
echo "  Worktree:     $WORKTREE_PATH"
echo "  Branch:       $BRANCH"
echo ""
echo "  cd $WORKTREE_PATH"
