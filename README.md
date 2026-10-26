# php82-ubuntu2404-backport

Docker build recipe, in-place upgrade script and pre-built `.deb` packages that bring the PHP 8.2
security fix for **CVE-2026-109618 / CVE-2026-109619** ("PHP2Shell") to **Ubuntu 24.04 (noble)**
VMs that run `php8.2 8.2.7-1ubuntu1`. Nothing is compiled on the VMs.

## Overview

Ubuntu 24.04 ships PHP 8.3 only. The VMs' php8.2 (`8.2.7-1ubuntu1`) is a mantic (23.10)
development build that gets no security updates. Sury's PPA packages can't be used as is:

1. They include patch `0048`, which sends telemetry queries to `telemetry.sury.org` over DNS
   (port 53) when php-fpm / mod_php start.
2. Adding the PPA would also replace other packages on the VMs (php-common, php8.3, libraries).

This project rebuilds **Sury's `php8.2 8.2.35-1` noble source** in an Ubuntu 24.04 container
pinned to `snapshot.ubuntu.com` (2026-10-20), producing `8.2.35-1~ubuntu24.04+1` packages that
upgrade `8.2.7-1ubuntu1` in place.

| Feature | Upstream Sury 8.2.35-1 (PPA) | Rebuilt `8.2.35-1~ubuntu24.04+1` |
|---|---|---|
| **Security fix** | in upstream 8.2.35 | **Preserved** |
| **DNS telemetry** | Patch `0048` | **Removed** (patch dropped, `TELEMETRY_*` defines removed) |
| **Base libraries** | noble | noble @ 2026-10-20 (`libc6 (>= 2.38)`, `libicu74`, `libssl3t64`, `libcurl4t64`) |
| **Version** | `8.2.35-1+ubuntu24.04.1+deb.sury.org+1` | `8.2.35-1~ubuntu24.04+1` (sorts above `8.2.7-1ubuntu1`) |

## Repository contents

```
.
├── Dockerfile.noble      # reproducible Docker build (ubuntu:24.04 + snapshot 20261020T000000Z)
├── build.md              # build instructions and checksums
├── install.md            # host installation / upgrade / rollback
├── upgrade-php82.sh      # in-place host upgrade script (dry run by default, --apply)
├── test-upgrade.sh       # integration test: 8.2.7-1ubuntu1 (+php8.3, +mongodb) -> 8.2.35
├── test-upgrade.log      # its result for the released build
├── sury/                 # PPA source package + patched tree
├── extra/                # noble's libzip4t64 (universe), shipped in the release for php8.2-zip
└── release/              # php8.2-8.2.35-1-noble.tar (debs, SHA256SUMS, script, install.md)
```

## Quick start: upgrading a host

```bash
scp release/php8.2-8.2.35-1-noble.tar webadmin@target-vm:/tmp/
ssh webadmin@target-vm
cd /tmp && tar xf php8.2-8.2.35-1-noble.tar && cd php8.2-8.2.35-1-noble
sudo ./upgrade-php82.sh            # dry run: checksums + apt simulation, changes nothing
sudo ./upgrade-php82.sh --apply    # backup /etc/php/8.2, install, php-fpm8.2 -t, restart
php-fpm8.2 -v | head -1            # PHP 8.2.35 (fpm-fcgi)
```

Details, prerequisites (`php-common 2:93ubuntu1`) and rollback: [`install.md`](install.md).

## Critical behaviour change: OOM handling

With the fix, a script that exhausts `memory_limit` **terminates the FPM worker immediately**:
the web server returns **502** for that request, and `/var/log/php8.2-fpm.log` shows
`child <PID> exited with code 1`.

## Building from source

See [`build.md`](build.md). In short:

```bash
docker build -f Dockerfile.noble -t php82-noble-build . > build-docker.log 2>&1
mkdir -p out && docker run --rm -v $PWD/out:/out php82-noble-build sh -c 'cp /src/*.deb /src/build.log /out/'
```

## License

Packaging and helper scripts: MIT. PHP itself: [PHP License](https://www.php.net/license/3_01.txt).
