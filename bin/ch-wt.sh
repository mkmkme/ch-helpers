#!/usr/bin/env bash
#
# Create a ClickHouse git worktree with submodules hardlinked from the main repo.
# Gives each worktree independent submodule copies without network access or extra
# disk space for git objects.
#
# Usage: ch-wt.sh [-e|--existing] [-b|--base <ref>] [-n|--no-submodules]
#                 <branch-name> [worktree-path]
#
# If the branch exists (locally or on origin), it is checked out.
# If it doesn't exist, a new branch is created from the current HEAD, or from
# the branch, tag, or commit given by -b/--base. The base must be available locally.
# Using --base with an existing branch is an error.
# Use -e/--existing to require a branch that exists locally or on origin.
# It cannot be combined with -b/--base.
# Use -n/--no-submodules to skip submodule setup for work that won't be built
# or tested, such as docs or comments.
#
# The default worktree path is ../<repo-name>-<branch> (sibling directory).
# Slashes in branch names are replaced with dashes in the default path.
#
# Prerequisites: submodules must already be cloned in the main repo
# (git submodule update --init must have been run at least once). Submodules
# are checked out at the commits the branch records, without network access.

set -euo pipefail

# Work from the current directory only. Inherited GIT_DIR, GIT_WORK_TREE and
# the like (e.g. when run from a hook) would point every git call below at
# the source repo instead of the new worktree.
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)

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
  -n, --no-submodules
                    Skip submodule setup. Much faster; use it when the worktree
                    won't be built or tested.
  -h, --help       Show this help and exit.
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
SKIP_SUBMODULES=false
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
        -n|--no-submodules)
            SKIP_SUBMODULES=true
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
    || die "usage: $0 [-e|--existing] [-b|--base <ref>] [-n|--no-submodules] <branch-name> [worktree-path]"

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

COMMON_DIR=$(git -C "$MAIN_REPO" rev-parse --path-format=absolute --git-common-dir)
[ "$SKIP_SUBMODULES" = true ] || [ -d "$COMMON_DIR/modules" ] \
    || die "no submodule data found in $COMMON_DIR/modules — run 'git submodule update --init' in the main repo first"

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

# 4. Create the worktree. Files are checked out in step 5, together with the
# submodule data copy.
if [ -n "$LOCAL" ]; then
    echo "Branch '$BRANCH' exists locally — checking out."
    git -C "$MAIN_REPO" worktree add --no-checkout "$WORKTREE_PATH" "$BRANCH"
elif [ -n "$REMOTE" ]; then
    echo "Branch '$BRANCH' exists on remote — creating local tracking branch."
    git -C "$MAIN_REPO" worktree add --no-checkout "$WORKTREE_PATH" -b "$BRANCH" "origin/$BRANCH"
else
    echo "Branch '$BRANCH' does not exist — creating new branch from $BASE."
    git -C "$MAIN_REPO" worktree add --no-checkout -b "$BRANCH" "$WORKTREE_PATH" "$BASE"
fi

# 5. Set up submodules via hardlinks.
# Git names the worktree's admin dir after the path's basename, but adds a
# number when that name is taken, so ask git where it is.
WORKTREE_GIT_DIR=$(git -C "$WORKTREE_PATH" rev-parse --absolute-git-dir)

# The module copy and the main checkout write disjoint paths, so run them
# at the same time.
cp_pid=
if [ "$SKIP_SUBMODULES" = true ]; then
    echo "Checking out files (skipping submodules)..."
else
    echo "Checking out files and hardlinking submodule data..."
    cp -al "$COMMON_DIR/modules" "$WORKTREE_GIT_DIR/modules" &
    cp_pid=$!
fi
checkout_status=0
git -C "$WORKTREE_PATH" \
    -c checkout.workers=0 \
    -c core.fsync=none \
    -c gc.auto=0 \
    checkout -q -f HEAD -- . || checkout_status=$?
cp_status=0
[ -z "$cp_pid" ] || wait "$cp_pid" || cp_status=$?
[ "$checkout_status" -eq 0 ] || die "checkout of the worktree files failed"
[ "$cp_status" -eq 0 ] || die "copying submodule data failed"

if [ "$SKIP_SUBMODULES" = false ]; then
    # Fix worktree pointers in submodule configs — they still reference the main
    # repo. Some submodules (e.g. contrib/boost) keep core.worktree in
    # config.worktree instead of config. submodule init only writes the
    # superproject config, so it runs alongside.
    echo "Registering submodules..."
    git -C "$WORKTREE_PATH" submodule init &
    init_pid=$!
    find "$WORKTREE_GIT_DIR/modules" \
        \( -name config -o -name config.worktree \) -exec \
        sed -i "s|worktree = .*/contrib/|worktree = $WORKTREE_PATH/contrib/|" {} +
    # Git appends to reflogs and rewrites FETCH_HEAD in place, so hardlinked
    # copies would leak into the main repo and every other worktree. Give
    # this worktree its own copies.
    find "$WORKTREE_GIT_DIR/modules" -type f \
        \( -path '*/logs/*' -o -name FETCH_HEAD \) -print0 |
        xargs -0 -r -n 32 -P "$(nproc)" sh -c 'for f; do cp -p "$f" "$f.tmp" && mv -f "$f.tmp" "$f" || exit 1; done' sh \
        || die "copying submodule reflogs failed"
    wait "$init_pid" || die "submodule init failed"

    GITLINKS=$(git -C "$WORKTREE_PATH" ls-files -s |
        sed -n 's/^160000 \([0-9a-f]*\) 0\t\(.*\)$/\1 \2/p')

    # The checkout below works from the gitlinks, not from .gitmodules as
    # git submodule does. Stop if the two disagree.
    GITLINK_COUNT=$(printf '%s' "$GITLINKS" | grep -c '^' || true)
    SUBMODULE_COUNT=$(git -C "$WORKTREE_PATH" config --file .gitmodules \
        --get-regexp '^submodule\..*\.path$' | grep -c '^' || true)
    [ "$GITLINK_COUNT" = "$SUBMODULE_COUNT" ] \
        || die "gitlink count $GITLINK_COUNT does not match .gitmodules count $SUBMODULE_COUNT"

    # nproc is the total budget: each job checks out one submodule with up to
    # SUBMODULE_CHECKOUT_WORKERS parallel workers (default min(8, nproc)), and
    # SUBMODULE_JOBS (default nproc / workers) submodules run at once.
    CPU_COUNT=$(nproc)
    CHECKOUT_WORKERS=${SUBMODULE_CHECKOUT_WORKERS:-$(( CPU_COUNT < 8 ? CPU_COUNT : 8 ))}
    [ "$CHECKOUT_WORKERS" -ge 1 ] || die "SUBMODULE_CHECKOUT_WORKERS must be positive"
    JOBS=${SUBMODULE_JOBS:-$(( CPU_COUNT / CHECKOUT_WORKERS ))}
    [ "$JOBS" -ge 1 ] || JOBS=1

    # Check out each submodule at the commit the superproject records, using only
    # the hardlinked module data. A missing commit fails instead of fetching.
    # Known heavy submodules go first so they don't finish last on their own.
    echo "Checking out submodules ($JOBS jobs x $CHECKOUT_WORKERS workers)..."
    {
        for submodule_path in \
            contrib/llvm-project \
            contrib/google-cloud-cpp \
            contrib/aws \
            contrib/openssl \
            contrib/icu \
            contrib/boost \
            contrib/rust_vendor \
            contrib/sysroot \
            contrib/grpc \
            contrib/arrow \
            contrib/curl \
            contrib/rocksdb \
            contrib/postgres \
            contrib/wasmtime
        do
            printf '%s\n' "$GITLINKS" | awk -v p="$submodule_path" '$2 == p { print; exit }'
        done
        printf '%s\n' "$GITLINKS"
    } |
        awk 'NF == 2 && !seen[$2]++' |
        while read -r expected_commit submodule_path; do
            printf '%s\0%s\0' "$expected_commit" "$submodule_path"
        done |
        xargs -0 -r -n2 -P "$JOBS" sh -c '
            source_modules_dir=$1 worktree_path=$2 modules_dir=$3 checkout_workers=$4
            expected_commit=$5 submodule_path=$6
            module_git_dir="$modules_dir/$submodule_path"
            module_worktree="$worktree_path/$submodule_path"
            mkdir -p "$module_worktree" || exit 1
            printf "gitdir: %s\n" "$module_git_dir" > "$module_worktree/.git" || exit 1
            if ! git --git-dir="$module_git_dir" --work-tree="$module_worktree" \
                -c advice.detachedHead=false \
                -c checkout.workers="$checkout_workers" \
                -c checkout.thresholdForParallelism=100 \
                -c index.threads=true \
                -c core.fsync=none \
                -c gc.auto=0 \
                checkout -q -f --detach "$expected_commit"
            then
                echo "error: $submodule_path: commit $expected_commit is missing from the local module data." >&2
                echo "Fetch it into the module data worktrees are copied from, then create the worktree again:" >&2
                echo "    git --git-dir=$source_modules_dir/$submodule_path fetch origin $expected_commit" >&2
                exit 1
            fi
        ' sh "$COMMON_DIR/modules" "$WORKTREE_PATH" "$WORKTREE_GIT_DIR/modules" "$CHECKOUT_WORKERS" \
        || die "a submodule could not be checked out at the recorded commit"
fi

# 6. Report results.
echo ""
echo "Worktree created successfully."
echo "  Source repo:  $MAIN_REPO"
echo "  Worktree:     $WORKTREE_PATH"
echo "  Branch:       $BRANCH"
if [ "$SKIP_SUBMODULES" = true ]; then
    echo "  Submodules:   skipped"
fi
echo ""
echo "  cd $WORKTREE_PATH"
