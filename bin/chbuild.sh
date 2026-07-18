#!/bin/bash

set -efu
set -o pipefail

CLANG_VERSION=${CLANG_VERSION:-21}
COMPILER_LAUNCHER=sccache

function is_pwd_a_git_repo() {
    git rev-parse --is-inside-work-tree 2>/dev/null >/dev/null
}

if ! is_pwd_a_git_repo; then
    echo "fatal: Not a git repository" >&2
    exit 1
fi

function git_root() {
    git rev-parse --show-toplevel
}

function usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [-- configure-option ...]

Basic options:
    -h, --help        Show this help message and exit
    -d, --dir         Directory to build in
    -C, --clean       Remove the build directory if exists
    -c, --configure   Only configure the build directory, do not build
    -r, --reconfigure Reconfigure the build directory if exists
    --dry-run         Do not do anything, just print the commands

Configure options:
    --clang-version   Use specified compiler version (default: 21)
    --cmake-compat    Set CMAKE_POLICY_VERSION_MINIMUM to 3.5 (for old versions)
    --no-rust         Disable Rust dependencies
    --                Pass remaining arguments as configure options

Options that change the build directory:
    --release         Build in release mode
    --asan            Use address sanitizer
    --ubsan           Use undefined behavior sanitizer
    --tsan            Use thread sanitizer
    --msan            Use memory sanitizer
EOF
}

function require_arg() {
    local opt="$1"
    local value="${2-}"

    if [[ -z "$value" ]]; then
        echo "Option ${opt} requires an argument" >&2
        exit 1
    fi
}

function print_command() {
    local arg_idx

    echo "Command: $*"
    for (( arg_idx = 1; arg_idx <= $#; ++arg_idx )); do
        printf "    argv[%d]: \"%q\"\n" "$(( arg_idx - 1 ))" "${!arg_idx}"
    done
}

function configure() {
    local dry_run="$1"
    local dir="$2"
    local build_opts=("${@:3}")

    if [[ "$dry_run" == 1 ]]; then
        print_command cmake "-S$(git_root)" "-B${dir}" "${build_opts[@]}"
    else
        echo "Options: ${build_opts[*]}"
        cmake -S"$(git_root)" -B"${dir}" "${build_opts[@]}"
    fi
}

function build() {
    local dry_run="$1"
    local dir="$2"
    local build_opts=("${@:3}")

    if [[ "$dry_run" == 1 ]]; then
        print_command "$COMPILER_LAUNCHER" -z
        print_command cmake --build "$dir" "-j$(nproc)" "${build_opts[@]}"
        print_command "$COMPILER_LAUNCHER" -s
    else
        if [[ "$COMPILER_LAUNCHER" == sccache ]]; then
            echo "Starting sccache server..."
            sccache --start-server || true
        fi
        "$COMPILER_LAUNCHER" -z
        cmake --build "${dir}" -j"$(nproc)" "${build_opts[@]}"
        "$COMPILER_LAUNCHER" -s
    fi
}

function main() {
    local dir no_rust release dry_run reconfigure configure clean cmake_compat sanitizer

    dir=$(git_root)/build
    clean=0
    release=0
    no_rust=0
    dry_run=0
    sanitizer=""
    reconfigure=0
    configure=0
    cmake_compat=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
            ;;
            -d|--dir)
                require_arg "$1" "${2-}"
                dir="$2"
                shift 2
            ;;
            -C|--clean)
                clean=1
                shift
            ;;
            -r|--reconfigure)
                reconfigure=1
                shift
            ;;
            -c|--configure)
                configure=1
                reconfigure=1
                shift
            ;;
            --clang-version)
                require_arg "$1" "${2-}"
                CLANG_VERSION="$2"
                shift 2
            ;;
            --cmake-compat)
                cmake_compat=1
                shift
            ;;
            --no-rust)
                no_rust=1
                shift
            ;;
            --release)
                release=1
                dir=$(git_root)/build-release
                shift
            ;;
            --asan|--ubsan|--tsan|--msan)
                if [[ -n "$sanitizer" ]]; then
                    echo "Only one of sanitizers can be specified" >&2
                    exit 1
                fi

                case $1 in
                    --asan)
                        sanitizer=address
                        dir=$(git_root)/build-asan
                    ;;
                    --ubsan)
                        sanitizer=undefined
                        dir=$(git_root)/build-ubsan
                    ;;
                    --tsan)
                        sanitizer=thread
                        dir=$(git_root)/build-tsan
                    ;;
                    --msan)
                        sanitizer=memory
                        dir=$(git_root)/build-msan
                    ;;
                esac

                shift
            ;;
            --dry-run)
                dry_run=1
                shift
            ;;
            --)
                shift
                [[ $# -gt 0 ]] && reconfigure=1
                break
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
        esac
    done

    local build_opts=(
        -DCMAKE_C_COMPILER_LAUNCHER="$COMPILER_LAUNCHER"
        -DCMAKE_CXX_COMPILER_LAUNCHER="$COMPILER_LAUNCHER"
        -DCMAKE_C_COMPILER="clang-${CLANG_VERSION}"
        -DCMAKE_CXX_COMPILER="clang++-${CLANG_VERSION}"
    )

    [[ "$cmake_compat" == 1 ]] && build_opts+=(
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    )

    if [[ "$release" == 1 && -n "$sanitizer" ]]; then
        echo "Only one of --release and sanitizers can be specified" >&2
        exit 1
    fi

    if [[ "$release" == 1 ]]; then
        build_opts+=(
            -DCMAKE_BUILD_TYPE=RelWithDebInfo
        )
    elif [[ -z "$sanitizer" ]]; then
        build_opts+=(
            -DCMAKE_BUILD_TYPE=Debug
            -DDEBUG_O_LEVEL=0
        )
    fi

    [[ "$no_rust" == 1 ]] && build_opts+=(-DENABLE_RUST=0)

    if [[ -n "$sanitizer" ]]; then
        build_opts+=(
            -DCMAKE_BUILD_TYPE=None
            -DSANITIZE="$sanitizer"
            -DENABLE_CHECK_HEAVY_BUILDS=1
            -DENABLE_BUILD_PROFILING=1
            -DENABLE_TESTS=1
            -DENABLE_LEXER_TEST=1
            -DENABLE_UTILS=0
            -DCMAKE_SKIP_INSTALL_ALL_DEPENDENCY=ON
        )
    fi

    build_opts+=("$@")

    if [[ "$clean" == 1 ]]; then
        if [[ "$dry_run" == 1 ]]; then
            echo "rm -rf ${dir}"
            reconfigure=1 # cleanest way to trigger configure in dry run
        else
            rm -rf "${dir}"
        fi
    fi

    if [[ "$reconfigure" == 1 || ! -d "$dir" ]]; then
        configure "$dry_run" "$dir" "${build_opts[@]}"
    fi

    if [[ "$configure" == 0 ]]; then
        build "$dry_run" "$dir"
    fi

}

main "$@"
