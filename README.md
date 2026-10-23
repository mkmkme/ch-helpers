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

Runs one ClickHouse server in the background as the systemd user service
`ch-run.service`, using this repository's configuration and enabled fragments.
Requires a running systemd user manager and systemd 254 or newer.

Data is temporary by default: a directory under `/var/tmp` is removed after the
service stops or fails. Pass `-d/--datadir` to keep data instead. An abrupt system
crash can leave temporary directories behind.

### Examples

- `ch-run` uses `<git-repository-root>/build/programs/clickhouse`.
- `ch-run -b /path/to/clickhouse` selects a custom binary. `CH_BINARY` also sets
  the default binary.
- `ch-run -d /path/to/data` uses a persistent data directory.
- `ch-run --stop` stops the server.
- `ch-run --status` shows `systemctl --user status ch-run.service`.
- `ch-run --logs` shows `journalctl --user -u ch-run.service`.

Stop, status, and logs do not require a binary or data directory. Only one
instance can run per user; stop it before starting another. Remaining arguments
are passed to ClickHouse, for example `ch-run -- --http_port=8124`.

Console output goes to journald. Logs remain after the service and temporary
data are removed, and include earlier runs under the same unit name. Follow
them with `journalctl --user -u ch-run.service -f`; on systemd 257 or newer,
add `-I` to select only the latest run.

A successful launch means the executable started, not that ClickHouse is ready
for queries. Completed and failed transient units are automatically collected,
so `--status` may report that the unit is not found after it exits. User services
can stop after the last logout unless lingering is enabled (`loginctl enable-linger`).

## `ch-s3`

Runs SeaweedFS mini as `ch-s3.service` with ClickHouse's stateless-test S3 setup.
Requires `weed` on `PATH` (tested with 4.48), curl, flock, and systemd 254+
with a running user manager. The standard `linux_amd64.tar.gz` release is enough
on Linux x86-64.

- `ch-s3` starts the server and uploads the current ClickHouse
  checkout's `tests/queries/0_stateless/data_minio/` fixtures.
- `ch-s3 --test-dir /path/to/ClickHouse/tests` selects tests explicitly.
- `ch-s3 -b /path/to/weed -d /path/to/data` selects the binary and storage.
- `ch-s3 stop`, `ch-s3 status`, and `ch-s3 logs` work from any directory.

Endpoint: `http://localhost:11111`, public bucket: `test`, credentials:
`clickhouse/clickhouse` (admin) and `test/testtest` (read/write). Start waits for
setup and fixture upload. Only one instance runs per user; stop any MinIO on
port 11111 first. `ch-minio` is unchanged.

Data persists under `${XDG_DATA_HOME:-~/.local/share}/ch-s3/<checkout-id>`.
Restart reuploads fixtures without deleting other objects. MinIO data directories
cannot be reused.

For older `aws`-based tests, creates a default profile in
`${AWS_SHARED_CREDENTIALS_FILE:-~/.aws/credentials}` if missing. Existing defaults
are preserved; override other credentials when running tests with
`AWS_ACCESS_KEY_ID=clickhouse AWS_SECRET_ACCESS_KEY=clickhouse AWS_DEFAULT_REGION=us-east-1`.

Local testing only: all services bind to loopback, the filer API is unauthenticated,
and writes do not fsync by default. Ports: 11111–11115 and 21111–21115.
WebDAV, Iceberg/Lance catalogs, and the admin UI are disabled; mini's admin
service and maintenance worker still run.
Logs go to journald; unit collection and logout behavior are the same as `ch-run`.

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
