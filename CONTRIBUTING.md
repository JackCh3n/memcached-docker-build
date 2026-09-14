# Contributing to memcached-docker-build

Thanks for taking the time to contribute! 🎉

## Development workflow

1. **Fork** the repository and create a feature branch:
   ```bash
   git checkout -b feat/your-feature
   ```
2. **Make your changes** — keep them focused and well-documented.
3. **Syntax-check** shell scripts:
   ```bash
   bash -n build-memcached.sh
   bash -n build.sh
   bash -n build-native.sh
   bash -n install.sh
   ```
4. **Test the build locally** if you have Docker:
   ```bash
   ./build.sh image
   ./build.sh build 1.6.45
   ```
5. **Commit** with a clear message and open a **Pull Request**.

## Versioning conventions

Unlike `redis-docker-build` (which keeps one branch per Redis major line), memcached's
build system is stable across the 1.5/1.6 lines, so **this repo keeps a single `main`
branch** and supports the whole 1.5.x / 1.6.x range via the version parameter.

| Trigger | Builds | Release |
|---|---|---|
| push to `main` / `master` | default version (`1.6.45`), both arches | `latest` (rolling) |
| tag `vMemcached-x.y.z` | that version only | tag-named release (frozen) |
| manual dispatch | any version / libevent mode / arch | `vMemcached-{version}` |

When bumping the default version, update **all** of:
`build.sh`, `build-native.sh`, `.github/workflows/build.yml`, `.cnb.yml`, `README.md`.

## memcached build system notes

memcached uses **autotools**, not a hand-written Makefile like Redis:

- The release tarball ships a pre-generated `configure` / `Makefile.in`. If we ever fall back
  to a GitHub source archive (which has neither), `build-memcached.sh` runs `./autogen.sh`,
  which is why the image also installs `autoconf automake libtool`.
- **Never use a bare `make`.** `Makefile.am` declares
  `noinst_PROGRAMS = memcached-debug sizes testapp timedrun`, so a bare `make` compiles the
  entire source tree a second time for `memcached-debug`. Build only the release binary:
  `make -j"$JOBS" memcached`.
- **Do not use `make install` either** — automake's `install-am` depends on `all-am`, which
  drags in those same `noinst_PROGRAMS`. `build-memcached.sh` collects the three artifacts it
  needs (`memcached`, `doc/memcached.1`, `scripts/memcached-tool`) directly from the build tree.

## libevent must stay statically linked

This is the single most important design decision in this repo:

- memcached's **only** external dependency is libevent, and the source tree does **not** vendor it.
- EL7 provides libevent 2.0.21, so a naive build links `libevent-2.0.so.5`.
- Kylin V10 SP3 / openEuler / UOS ship libevent 2.1.x (`libevent-2.1.so.6`) — or no libevent at all.
  Shipping the EL7 binary there fails with a missing `libevent-2.0.so.5`.

Therefore the Dockerfile builds libevent from source into `/opt/libevent` with
`--disable-shared --enable-static --with-pic` and `build-memcached.sh` configures memcached with
`--with-libevent=/opt/libevent`, so `-levent` can only resolve to the static archive.

- `--with-pic` is **required**: EL7's toolchain builds PIE executables by default, and a non-PIC
  static archive fails to link with `R_X86_64_32S` / `ADR_PREL_PG_HI21` relocation errors.
- `build-memcached.sh` appends `-levent_pthreads -lpthread` *after* `-levent` (static linking is
  order-sensitive: later libraries satisfy earlier undefined symbols).
- The artifact must keep shipping `LICENSE.libevent.txt`; statically linking BSD-3-Clause code
  into a distributed binary requires carrying its license text.
- `--libevent system` exists as an escape hatch, but the resulting artifact needs libevent 2.x on
  the target host. Keep the default `auto` → static behaviour.

## TLS is native-build-only

memcached's `configure.ac` hard-asserts `OPENSSL_VERSION_NUMBER >= 0x10101000L` (OpenSSL ≥ 1.1.0)
for `--enable-tls`. EL7 only has OpenSSL 1.0.2k, so **CI/container TLS builds are impossible**.
`build-memcached.sh` refuses `--tls yes` when OpenSSL < 1.1.0 with an actionable error, and the
GitHub workflow fails fast for the same reason. TLS must be built on the target host with
`build-native.sh <version> system yes`. Do not weaken these guards — silently producing a
TLS-less or unloadable binary is worse than a clear failure.

## Installer (`install.sh`) notes

- The installer is **strictly offline**: no network calls, no `curl`/`wget` dependency.
- Keep it **bash 4.2** compatible (CentOS 7) — no `mapfile`, no `${var,,}`, no associative arrays.
- Version gating order (must stay this way):
  not installed → install; pkg > installed → update; pkg == installed → skip; pkg < installed →
  **refuse** unless `--force`.
- Back up old binaries (`/var/backups/memcached-<timestamp>/`) before overwriting.
- **memcached has no config file.** Its parameters live in `/etc/sysconfig/memcached`
  (`EnvironmentFile` for the unit). Never overwrite an existing one — it holds the operator's
  `-l` / `-m` tuning. The installer only adjusts the `USER=` line to match `--user`.
- The unit template contains a `@BIN_DIR@` placeholder which the installer substitutes with the
  real install prefix, so `--prefix` works. If you add assets, keep that substitution in mind.
- memcached refuses to run as root without `-u`; the user is created by the installer and the
  sysconfig `USER=` value must always name an existing account. Note that
  `--static yes` (fully static) is *not* the default for this reason: a static glibc can break
  `getpwnam`/NSS lookups on hosts whose glibc differs from the build host.
- Detect the package by **content** (`memcached` + `BUILD-INFO.txt`), not by the presence of the
  exec bit — some filesystems lose it, and `install -m 0755` fixes it anyway.

## Windows: do not add a native build path

memcached has **no upstream Windows support** (no Windows build files; `fork`/`setsid`,
`pthread_create`, `sys/un.h`, `getpwnam` in the core), so **do not add an MSVC / Cygwin / MinGW
build path** to this repo. It cannot be verified in CI, and shipping an unverifiable binary is
worse than declaring it unsupported. Windows users are served by running the existing Linux
artifacts under WSL2 or Docker — see `windows/README.md`.

If you touch the Windows helpers, two traps matter:

- `windows/memcached-wsl.ps1` **must keep its UTF-8 BOM**. Windows PowerShell 5.1 reads BOM-less
  `.ps1` files using the ANSI code page, which mangles the Chinese text into stray braces and quotes
  and makes the script fail to parse. After editing, verify with the PowerShell parser:
  ```powershell
  powershell -NoProfile -Command "$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile('windows\memcached-wsl.ps1',[ref]$null,[ref]$e); $e"
  ```
  (rewrite with a BOM via `[System.IO.File]::WriteAllText($p,$c,[System.Text.UTF8Encoding]::new($true))`)
- `windows/` is copied into every package by all three packagers, like `assets/` — keep that in sync.
  `wsl-install.sh` deliberately re-implements the protocol probe (subshell-isolated `/dev/tcp`, CR
  stripping); if you change that pattern in `build-memcached.sh`, change it here too.

## CI notes

- GitHub Actions and CNB pipelines must stay in sync for the **default version** — change both
  together. Both produce **x86_64 + aarch64**.
- **CNB is a two-pipeline setup.** `runner` (tags/cpus) can only be set at the **pipeline** level,
  so `.cnb.yml` defines two parallel pipelines per trigger (`cnb:arch:amd64` +
  `cnb:arch:arm64:v8`) that **share one stage list** via a YAML anchor. aarch64 uses CNB's native
  ARM nodes — no QEMU.
- **Publishing must stay idempotent and race-safe.** Both arch pipelines publish into the *same*
  release, so `ensure-release` does GET-then-create, tolerates `409/422` (the other pipeline won
  the race) and PATCHes an existing release instead of recreating it. Upload only globs the local
  `dist/`, so the two arches never overwrite each other.
- CNB API calls need `Accept: application/vnd.cnb.api+json` on GET/POST/PATCH (Content-Type alone
  returns 406). Do not introduce raw `\n` inside a JSON body — escape it (see `ensure-release`).
- The GitHub release job requires `contents: write`; CNB needs `CNB_TOKEN` (already in the env).
- The tarballs must stay **self-contained**: the packaging step copies `install.sh`,
  `assets/memcached.service`, `assets/memcached.sysconfig` and `LICENSE` into each `dist/<pkg>/`
  before `tar`. If you add a new asset file, add it to all three packagers (`.cnb.yml`,
  `build.yml`, `build.sh`).
- Release titles must be **English**; notes use `--notes-file` (a plain `\n` passed to `--notes`
  is treated literally).
- The in-container smoke test (`version` handshake + `set`/`get` round-trip) must pass; a failing
  smoke test fails the build on purpose. It talks to memcached over bash's built-in `/dev/tcp`, so
  no `nc`/`telnet` dependency is needed.

## Architecture notes

- `Dockerfile` serves **both** architectures via `--build-arg BASE_IMAGE`:
  - x86_64 → `centos:7.6.1810` (vault path `7.6.1810`)
  - aarch64 → `arm64v8/centos:7` (vault path `altarch/7`)
  The `VAULT_PREFIX` build arg is auto-derived when left empty.
- CentOS 7 is EOL; `vault.centos.org` is unreachable from many networks. Use a domestic
  archive mirror (`OS_MIRROR`) rather than hardcoding vault.centos.org.
- The devtoolset repo **must** point at the CDN host `buildlogs.cdn.centos.org`, not the origin
  `buildlogs.centos.org`. The origin 302-redirects RPM requests to the CDN, and CentOS 7's yum
  does not follow 302 → `HTTP Error 302 - Found` / `No more mirrors to try`. The redirect is
  intermittent, which makes this a hard-to-reproduce failure.
- memcached itself compiles fine with EL7's stock GCC 4.8.5 (it only needs `__sync_*` builtins,
  not C11 atomics). devtoolset-10 is used for consistency with `redis-docker-build` and for
  noticeably better aarch64 (Kunpeng 920) code generation. Artifacts still only require glibc 2.17.

## Reporting issues

Open an issue with:
- Target environment (`uname -m`, `cat /etc/os-release` or `cat /etc/.productinfo`, `getconf PAGESIZE`)
- Whether the target host has libevent installed (`ldd $(command -v memcached)`)
- The exact command that failed
- Full error output (log snippet), plus `dist/*/BUILD-INFO.txt` if the artifact was produced

Thank you for helping make this project better!
