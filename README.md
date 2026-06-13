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

Similarly, there's a `config/users-available` directory with user configurations
and `config/users.d` directory for enabled users.

### Examples

`ch-conf list` or `ch-conf` will list all available parts and their status.  
`ch-conf enable 10-local-remote-replica` will enable the part `10-local-remote-replica`.
So will `ch-conf enable 10` or `ch-conf enable local-remote-replica`.  
`ch-conf disable 10-local-remote-replica` will disable the part `10-local-remote-replica`.

`ch-conf user-list` will list all available users and their status.  
`ch-conf user-enable 10-mikhail` will enable the user `mikhail.lomonosov` that
is defined in the part `10-mikhail.xml`. So will `ch-conf user-enable 10`.

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

Default data directory is `$HOME/.clickhouse-server/shared`.  
Default ClickHouse binary is `$CWD/build/programs/clickhouse`.

## chbuild.sh

TBD
