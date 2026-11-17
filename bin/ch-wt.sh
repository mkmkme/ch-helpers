#!/usr/bin/env bash
#
# Create a ClickHouse git worktree whose submodule git data is hardlinked from
# the main repo: no network access and no extra disk space for git objects.
# Run with --help for usage.

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

Environment:
  SUBMODULE_CHECKOUT_WORKERS  Checkout workers per submodule (default min(8, nproc)).
  SUBMODULE_JOBS              Submodules checked out at once
                              (default 2 x nproc / SUBMODULE_CHECKOUT_WORKERS).
EOF
}

# Replace each file with a copy of itself, so it no longer shares an inode
# with the hardlinked source.
unshare_files() {
    local f
    for f; do
        cp -p "$f" "$f.tmp" && mv -f "$f.tmp" "$f" || return 1
    done
}

# Check out one submodule at the given commit, using only the hardlinked
# module data. Reads WORKTREE_PATH, MODULES_DIR, SOURCE_MODULES_DIR and
# CHECKOUT_WORKERS from the environment.
checkout_submodule() {
    local commit=$1 path=$2
    local git_dir=$MODULES_DIR/$path work_tree=$WORKTREE_PATH/$path
    mkdir -p "$work_tree" || return 1
    printf 'gitdir: %s\n' "$git_dir" > "$work_tree/.git" || return 1
    if ! git --git-dir="$git_dir" --work-tree="$work_tree" \
        -c advice.detachedHead=false \
        -c checkout.workers="$CHECKOUT_WORKERS" \
        -c core.fsync=none \
        checkout -q -f --detach "$commit"
    then
        echo "error: $path: commit $commit is missing from the local module data." >&2
        echo "Fetch it into the source module data, then create the worktree again:" >&2
        echo "    git --git-dir=$SOURCE_MODULES_DIR/$path fetch origin $commit" >&2
        return 1
    fi
}

# 1. Parse arguments.
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
    || die "usage: $0 [options] <branch-name> [worktree-path] (see --help)"

if [ "$EXISTING_ONLY" = true ] && [ "$BASE_SET" = true ]; then
    die "--existing cannot be combined with --base"
fi

# 2. Work out the source repo and the worktree path. The source repo is the
# current checkout, which may itself be a worktree; submodule data always
# comes from the main repo's common git dir.
SOURCE_REPO=$(git rev-parse --show-toplevel 2>/dev/null) \
    || die "not inside a git repository"
SOURCE_REPO_NAME=$(basename "$SOURCE_REPO")
COMMON_DIR=$(git -C "$SOURCE_REPO" rev-parse --path-format=absolute --git-common-dir)
SOURCE_MODULES_DIR=$COMMON_DIR/modules

if [ -n "${POSITIONAL[1]:-}" ]; then
    WORKTREE_PATH=$(realpath -m "${POSITIONAL[1]}")
else
    WORKTREE_PATH=$(realpath -m "$SOURCE_REPO/../${SOURCE_REPO_NAME}-${BRANCH//\//-}")
fi

# 3. Check preconditions.
[ ! -e "$WORKTREE_PATH" ] \
    || die "worktree path already exists: $WORKTREE_PATH"

[ "$SKIP_SUBMODULES" = true ] || [ -d "$SOURCE_MODULES_DIR" ] \
    || die "no submodule data found in $SOURCE_MODULES_DIR;" \
           "run 'git submodule update --init' in the main repo first"

LOCAL=$(git -C "$SOURCE_REPO" branch --list "$BRANCH")
REMOTE=$(git -C "$SOURCE_REPO" branch --list -r "origin/$BRANCH")

if [ "$EXISTING_ONLY" = true ]; then
    [ -n "$LOCAL" ] || [ -n "$REMOTE" ] \
        || die "branch '$BRANCH' does not exist locally or on origin"
fi

if [ "$BASE_SET" = true ]; then
    [ -z "$LOCAL" ] && [ -z "$REMOTE" ] \
        || die "--base cannot be used with existing branch '$BRANCH'"
    git -C "$SOURCE_REPO" rev-parse --verify --end-of-options "${BASE}^{commit}" >/dev/null 2>&1 \
        || die "base does not resolve to a commit: $BASE"
fi

# 4. Create the worktree. Its files are checked out in step 5.
if [ -n "$LOCAL" ]; then
    echo "Branch '$BRANCH' exists locally — checking out."
    git -C "$SOURCE_REPO" worktree add --no-checkout "$WORKTREE_PATH" "$BRANCH"
elif [ -n "$REMOTE" ]; then
    echo "Branch '$BRANCH' exists on remote — creating local tracking branch."
    git -C "$SOURCE_REPO" worktree add --no-checkout "$WORKTREE_PATH" -b "$BRANCH" "origin/$BRANCH"
else
    echo "Branch '$BRANCH' does not exist — creating new branch from $BASE."
    git -C "$SOURCE_REPO" worktree add --no-checkout -b "$BRANCH" "$WORKTREE_PATH" "$BASE"
fi

# Git names the worktree's admin dir after the path's basename, but adds a
# number when that name is taken, so ask git where it is.
MODULES_DIR=$(git -C "$WORKTREE_PATH" rev-parse --absolute-git-dir)/modules

# 5. Check out the worktree files. Copying the submodule data writes disjoint
# paths, so it runs at the same time.
cp_pid=
if [ "$SKIP_SUBMODULES" = true ]; then
    echo "Checking out files (skipping submodules)..."
else
    echo "Checking out files and hardlinking submodule data..."
    cp -al "$SOURCE_MODULES_DIR" "$MODULES_DIR" &
    cp_pid=$!
fi
checkout_status=0
git -C "$WORKTREE_PATH" \
    -c checkout.workers=0 \
    -c core.fsync=none \
    checkout -q -f HEAD -- . || checkout_status=$?
cp_status=0
[ -z "$cp_pid" ] || wait "$cp_pid" || cp_status=$?
[ "$checkout_status" -eq 0 ] || die "checkout of the worktree files failed"
[ "$cp_status" -eq 0 ] || die "copying submodule data failed"

# 6. Set up submodules.
if [ "$SKIP_SUBMODULES" = false ]; then
    CPU_COUNT=$(nproc)
    export -f unshare_files checkout_submodule

    # submodule init only writes the superproject config, so it runs while
    # the copied module data is fixed up.
    echo "Registering submodules..."
    git -C "$WORKTREE_PATH" submodule init &
    init_pid=$!

    # The copied configs still point core.worktree at the main repo. Some
    # submodules (e.g. contrib/boost) keep it in config.worktree instead.
    find "$MODULES_DIR" \( -name config -o -name config.worktree \) -exec \
        sed -i "s|worktree = .*/contrib/|worktree = $WORKTREE_PATH/contrib/|" {} +

    # Git appends to reflogs and rewrites FETCH_HEAD in place, so hardlinked
    # copies would leak into the main repo and every other worktree.
    find "$MODULES_DIR" -type f \( -path '*/logs/*' -o -name FETCH_HEAD \) -print0 |
        xargs -0 -r -n 32 -P "$CPU_COUNT" bash -c 'unshare_files "$@"' _ \
        || die "copying submodule reflogs failed"

    wait "$init_pid" || die "submodule init failed"

    # Submodules are checked out from the gitlinks, not from .gitmodules as
    # git submodule does. Stop if the two disagree.
    GITLINKS=$(git -C "$WORKTREE_PATH" ls-files -s |
        sed -n 's/^160000 \([0-9a-f]*\) 0\t\(.*\)$/\1 \2/p')
    GITLINK_COUNT=$(printf '%s' "$GITLINKS" | grep -c '^' || true)
    SUBMODULE_COUNT=$(git -C "$WORKTREE_PATH" config --file .gitmodules \
        --get-regexp '^submodule\..*\.path$' | grep -c '^' || true)
    [ "$GITLINK_COUNT" = "$SUBMODULE_COUNT" ] \
        || die "gitlink count $GITLINK_COUNT does not match .gitmodules count $SUBMODULE_COUNT"

    # Run 2 x nproc threads in total, split between submodules checked out at
    # once and checkout workers within each. Checkouts mostly wait on the
    # filesystem, so nproc alone leaves CPUs idle.
    CHECKOUT_WORKERS=${SUBMODULE_CHECKOUT_WORKERS:-$(( CPU_COUNT < 8 ? CPU_COUNT : 8 ))}
    [ "$CHECKOUT_WORKERS" -ge 1 ] || die "SUBMODULE_CHECKOUT_WORKERS must be positive"
    JOBS=${SUBMODULE_JOBS:-$(( 2 * CPU_COUNT / CHECKOUT_WORKERS ))}
    [ "$JOBS" -ge 1 ] || JOBS=1
    export WORKTREE_PATH MODULES_DIR SOURCE_MODULES_DIR CHECKOUT_WORKERS

    # Known heavy submodules go first, slowest first, so they don't finish
    # last on their own. Some are slow for their file count (llvm-project,
    # aws), others for their size in a few files (icudata, MeCab, cld2).
    echo "Checking out submodules ($JOBS jobs x $CHECKOUT_WORKERS workers)..."
    {
        for submodule_path in \
            contrib/llvm-project \
            contrib/aws \
            contrib/rust_vendor \
            contrib/boost \
            contrib/google-cloud-cpp \
            contrib/icudata \
            contrib/MeCab \
            contrib/cld2 \
            contrib/openssl \
            contrib/croaring \
            contrib/sysroot \
            contrib/icu \
            contrib/postgres \
            contrib/grpc \
            contrib/arrow \
            contrib/curl \
            contrib/rocksdb \
            contrib/wasmtime
        do
            printf '%s\n' "$GITLINKS" | awk -v p="$submodule_path" '$2 == p { print; exit }'
        done
        printf '%s\n' "$GITLINKS"
    } |
        awk 'NF == 2 && !seen[$2]++' |
        tr ' \n' '\0\0' |
        xargs -0 -r -n 2 -P "$JOBS" bash -c 'checkout_submodule "$@"' _ \
        || die "a submodule could not be checked out at the recorded commit"
fi

# 7. Report results.
echo ""
echo "Worktree created successfully."
echo "  Source repo:  $SOURCE_REPO"
echo "  Worktree:     $WORKTREE_PATH"
echo "  Branch:       $BRANCH"
if [ "$SKIP_SUBMODULES" = true ]; then
    echo "  Submodules:   skipped"
fi
echo ""
echo "  cd $WORKTREE_PATH"
