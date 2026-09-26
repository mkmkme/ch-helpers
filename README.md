# ch-helpers

Collection of scripts I use to build and run ClickHouse

## `ch-conf`

This script is used to configure ClickHouse server.
Here's how it works: this repository has a `config` directory with everything
that I personally ever needed to change in the config. All of these changes are
split into parts and placed in the `config/parts` directory.

Then, there's a `config/config.xml` file that contains the default config
for the server and `config/users.xml` file that contains the default users for the
server.

`ch-conf` is used to enable/disable parts of the config via creating or removing
symlinks in the `config/config.d` directory.

Part can be a template if it ends with `.xml.in`. In such case, it can contain
variables in format `@@VARIABLE_NAME@@` that will be expanded during enable. For
now, only `@@CONFIG_DIR@@` is supported. Templates are written as plain files
rather than symlinks, so re-enable a template after editing it.

Similarly, there's a `config/users-available` directory with user configurations
and `config/users.d` directory for enabled users.

### Examples

`ch-conf list` or `ch-conf` will list all available parts and their status.  
`ch-conf enable 10-local-remote-replica` will enable the part `10-local-remote-replica`.
So will `ch-conf enable 10` or `ch-conf enable local-remote-replica`.  
`ch-conf disable 10-local-remote-replica` will disable the part `10-local-remote-replica`.

`ch-conf show 10-local-remote-replica` will print the contents of the part
`10-local-remote-replica`. So will `ch-conf show 10`.  
`ch-conf show` without a name will print the base `config/config.xml`.  
`ch-conf edit 10-local-remote-replica` will open that part in `$EDITOR`
(defaults to `vi`), and `ch-conf edit` without a name will open the base
`config/config.xml`.

`ch-conf user-list` will list all available users and their status.  
`ch-conf user-enable 10-mikhail` will enable the user `mikhail.lomonosov` that
is defined in the part `10-mikhail.xml`. So will `ch-conf user-enable 10`.  
`ch-conf user-show 10-mikhail` will print the contents of the user part
`10-mikhail.xml`, and `ch-conf user-show` without a name will print the base
`config/users.xml`.  
`ch-conf user-edit 10-mikhail` will open that user part in `$EDITOR`, and
`ch-conf user-edit` without a name will open the base `config/users.xml`.

## `ch-run`

This script is used to run an instance of ClickHouse server with the config
defined and configured in this repository. Its default purpose is to be run from
a git repository and use the ClickHouse binary from the repository.

It can also be run with a custom ClickHouse binary and a custom data directory.

### Examples

`ch-run` will run the server with the config defined and configured in this
repository.  
`ch-run -b /path/to/clickhouse-server` will run the
server with the custom ClickHouse binary.  
`ch-run -d /path/to/data` will run the server with the custom data directory.  
`ch-run -t` will run the server in a temporary data directory.  
`ch-run -l` will run the server in the local directory `chrun` in the current
working directory.  
`ch-run --release` will run the server with the release build of the ClickHouse
binary (located in the `build-release` directory).  
`ch-run --asan` will run the server with the ASAN build of the ClickHouse
binary (located in the `build-asan` directory).  
`ch-run --ubsan` will run the server with the UBSAN build of the ClickHouse
binary (located in the `build-ubsan` directory).  
`ch-run --tsan` will run the server with the TSAN build of the ClickHouse
binary (located in the `build-tsan` directory).  
`ch-run --msan` will run the server with the MSAN build of the ClickHouse
binary (located in the `build-msan` directory).  
`ch-run --daemon` will start the server in the background. It writes a PID
file named `ch-run.pid` in the selected data directory and prints the PID.
`ch-run --stop` will gracefully stop that instance (use `-d` or `-l` to
select a different data directory). It does not need a ClickHouse binary.

`--daemon` cannot be combined with `--tmp`: the temporary directory would
otherwise be removed when the launcher exits. `--stop` cannot be combined
with `--tmp` either. A successful daemon launch means the process has started;
it does not guarantee the server is ready to accept queries yet.

Default data directory is `$HOME/.clickhouse-server/shared`.  
Default ClickHouse binary is `$CWD/build/programs/clickhouse`.

## chbuild.sh

This is the script I use to build ClickHouse. It's a wrapper around the `cmake`
command that I use to build ClickHouse. It's also a wrapper around the `sccache`
command that I use to cache the build.

### Examples

`chbuild.sh` will build the ClickHouse server with the default settings.  

`chbuild.sh --release` will build the ClickHouse server with the release build.  
`chbuild.sh --asan` will build the ClickHouse server with the ASAN build.  
`chbuild.sh --ubsan` will build the ClickHouse server with the UBSAN build.  
`chbuild.sh --tsan` will build the ClickHouse server with the TSAN build.

`chbuild.sh --clang-version 21` will build the ClickHouse server with the Clang 21 compiler.

`chbuild.sh --no-rust` will build the ClickHouse server without the Rust dependencies.

`chbuild.sh --clean` will clean the build directory before building.

`chbuild.sh --configure` will configure the build directory without building.  
`chbuild.sh --reconfigure` will reconfigure the build directory if it already exists.

`chbuild.sh --cmake-compat` will set the CMAKE_POLICY_VERSION_MINIMUM to 3.5 (for old versions).

`chbuild.sh --dry-run` will print the commands that would be executed without executing them.
