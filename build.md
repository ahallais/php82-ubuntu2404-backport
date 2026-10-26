# Building PHP 8.2.35-1~ubuntu24.04+1 for the Ubuntu 24.04 VMs

How the packages in `release/php8.2-8.2.35-1-noble.tar` were built, and how to rebuild them.
The result is a set of `.deb` files that upgrade `php8.2 8.2.7-1ubuntu1` in place with the fix
for **CVE-2026-109618 / CVE-2026-109619**. Nothing is compiled on the VMs.

## Approach

| Choice | Why |
|---|---|
| Source: Ondřej Surý's PPA `php8.2 8.2.35-1+ubuntu24.04.1+deb.sury.org+1` | PHP 8.2.35 is the upstream release with the CVE fix ("Avoid state corruption via bailout") plus every earlier 8.2 security fix. The PPA source is already adapted to noble. |
| Build system: **Ubuntu 24.04 (noble)** from `snapshot.ubuntu.com` at `20261020T000000Z` | Same libraries as an up-to-date 24.04.5 VM (libc6 2.39, libicu74, libssl3t64, libcurl4t64). The snapshot pins the build so it is reproducible. |
| Drop patch `0048` (DNS telemetry) and the `TELEMETRY_*` defines in `debian/rules` | It makes php-fpm and mod_php send the package version to `telemetry.sury.org` (DNS, port 53) at startup. Not wanted on our servers. |
| `php-common` dependency kept as is | Sury requires `php-common (>= 1:81~)`. Noble has `2:93`, so no change needed (unlike the php7.1 build). |
| Version `8.2.35-1~ubuntu24.04+1` | Sorts above `8.2.7-1ubuntu1`, so dpkg treats it as an upgrade, and is easy to recognise on the hosts. Sorts below Sury's own `8.2.35-1+ubuntu24.04.1+deb.sury.org+1`. |

About the VMs: `8.2.7-1ubuntu1` is a mantic (23.10) development build. On noble its only
unsatisfied dependency is `libicu72`, which the VMs still have from mantic. The new
`php8.2-intl` uses noble's `libicu74` instead (installed from the normal Ubuntu repositories
if missing).

**`php-common`:** noble's `php-common 2:93ubuntu2` has an unversioned `Breaks: php8.2-common`
(Ubuntu dropped php8.2 in 24.04). Mantic's `2:93ubuntu1` doesn't. The VMs can only have php8.2
installed with mantic's `php-common 2:93ubuntu1` (noble's update held back by apt). Our packages
need that too: with `2:93ubuntu2` on a VM, apt refuses them and the dry run aborts.

`php8.2-mongodb` is a separate source package and isn't rebuilt: the extension
API (`20220829`) is the same for all 8.2.x.

## Requirements

- Linux x86_64 with Docker (tested with Docker 28.5) and internet access
- ~5 GB free disk, about 60 min on 16 cores (8 SAPI builds: apache2, phpdbg, embed, fpm, ...)
- `curl`, `python3`

All commands below run from the project directory:

```bash
cd ~/phpubuntu/php82
```

## 1. Download the Sury source package

```bash
mkdir -p sury && cd sury
curl -fsSL https://ppa.launchpadcontent.net/ondrej/php/ubuntu/dists/noble/main/source/Sources.xz -o Sources-noble-ppa.xz
xzcat Sources-noble-ppa.xz | awk '/^Package: php8.2$/{p=1} p&&/^Version:/{print} p&&/^$/{p=0}'
# -> Version: 8.2.35-1+ubuntu24.04.1+deb.sury.org+1

xzcat Sources-noble-ppa.xz \
 | awk '/^Package: php8.2$/{p=1} p&&/^Files:/{f=1;next} p&&f&&/^ /{print $3} p&&f&&!/^ /{f=0} p&&/^$/{p=0}' \
 | while read f; do curl -fsSLO https://ppa.launchpadcontent.net/ondrej/php/ubuntu/pool/main/p/php8.2/$f; done
sha256sum php8.2_8.2.35*
```

Expected checksums of the files used for the released build:

```
fc253d9870d1d7d11dbd30c0aea76a5be0684fedd0330aba44c133fb86b249dc  php8.2_8.2.35-1+ubuntu24.04.1+deb.sury.org+1.dsc
90f150389cdc2a7938f96333aee6a6d1bcd9463312d5b87e044414a8ad08210a  php8.2_8.2.35-1+ubuntu24.04.1+deb.sury.org+1.debian.tar.xz
5737b98601fe5ab1b8c5db0c82ed3158acb9283ed3081ffe2faffb9ac81455e6  php8.2_8.2.35.orig.tar.xz
```

The PPA replaces packages in place. If a newer `8.2.x` is listed, read its `debian/changelog`
and patch list before using it (check again for telemetry or other unexpected patches). If
the old version is gone, the files above are kept in `~/phpubuntu/php82/sury/`.

## 2. Prepare the source tree

```bash
mkdir -p build deb
tar -xJf php8.2_*.debian.tar.xz -C deb
tar -xJf php8.2_8.2.35.orig.tar.xz -C build      # -> build/php-8.2.35
mv build/php-8.2.35 build/php8.2-8.2.35
cp -a deb/debian build/php8.2-8.2.35/
cd build/php8.2-8.2.35/debian

# The CVE fix is upstream in 8.2.35 (no separate patch)
head -12 changelog          # 8.2.35-1: (CVE-2026-109618, CVE-2026-109619): Avoid state corruption via bailout

# a) drop the DNS telemetry patch
sed -i '/^0048-Add-minimal-privacy-preserving-secure-DNS-telemetry/d' patches/series

# b) don't pull TELEMETRY_* defines (php-common.mk include + -DTELEMETRY_*)
sed -i 's|^-include /usr/lib/php/php-common.mk|# telemetry include removed for internal noble build|' rules
sed -i "/^# Secure DNS Telemetry/,/^\t-DTELEMETRY_VERSION/{/^DEB_CFLAGS_MAINT_APPEND += \\\\\$/s/^/# /;/^\t-DTELEMETRY/s/^/# /}" rules
grep -n -i telemetry rules   # only commented lines left

cd ~/phpubuntu/php82
```

## 3. Build the packages

Files used: `Dockerfile.noble` and `.dockerignore` (both in `~/phpubuntu/php82`). No separate
base image is needed: `Dockerfile.noble` starts from `ubuntu:24.04` and installs everything
with `apt-get --snapshot 20261020T000000Z`.

To target VMs with an older library set, pass another date
(`--build-arg SNAPSHOT=YYYYMMDDTHHMMSSZ`). **The build's libc6 must not be newer than the VM's.**

Build and extract:

```bash
docker build -f Dockerfile.noble -t php82-noble-build . > build-docker.log 2>&1 \
  || tail -40 build-docker.log
mkdir -p out
docker run --rm -v $PWD/out:/out php82-noble-build sh -c 'cp /src/*.deb /src/build.log /out/'
grep -c "dpkg-source: info: applying" out/build.log   # 47 (0001..0047, no 0048)
ls out/*.deb | wc -l                                   # 36 (debug symbols are separate .ddeb, not copied)
```

## 4. Check the result

Dependencies must be satisfiable on the VMs:

```bash
for p in common fpm cli curl intl gd zip pgsql imap ldap soap; do
  echo "$p: $(dpkg-deb -f out/php8.2-${p}_8.2.35-*_amd64.deb Depends)"
done
# expect: libc6 (>= 2.38) at most, libicu74, libssl3t64, libcurl4t64, php-common (>= 1:81~)
```

No telemetry in the binary:

```bash
docker run --rm -v $PWD/out:/d:ro ubuntu:24.04 bash -c \
  'dpkg-deb -x /d/php8.2-fpm_*.deb /x && grep -a -c telemetry /x/usr/sbin/php-fpm8.2'   # 0
```

Upgrade test on a copy of a VM: get the `8.2.7-1ubuntu1` debs into `old/` (command in
`install.md`, "Rollback") plus `php8.2-mongodb_1.15.0+1.11.1+1.9.2+1.7.5-1build1_amd64.deb`, and
mantic's `libicu72_72.1-3ubuntu3_amd64.deb`, `libzip4_1.7.3-1ubuntu2_amd64.deb` and
`php-common_93ubuntu1_all.deb` into `oldlibs/`
(all from Launchpad),
build the release directory (step 5), then:

```bash
docker run --rm -v $PWD/old:/old:ro -v $PWD/oldlibs:/oldlibs:ro \
  -v $PWD/release/php8.2-8.2.35-1-noble:/new:ro -v $PWD/test-upgrade.sh:/t.sh:ro \
  ubuntu:24.04 bash /t.sh | tee test-upgrade.log
```

`test-upgrade.sh` installs 8.2.7-1ubuntu1 next to Ubuntu's php8.3, applies the mitigation
edits, disables the universe component (like on the VMs), runs `upgrade-php82.sh` (dry run, then `--apply`), then checks that config edits
survived, that php8.3 is still the default `php`, that the FPM config test passes, that FPM
serves requests, that `php8.2-mongodb` still loads and that the binary contains no telemetry.
Result for the released build: `test-upgrade.log`.

## 5. Package the release

```bash
rm -rf release && mkdir -p release/php8.2-8.2.35-1-noble
cp out/*.deb release/php8.2-8.2.35-1-noble/
rm -f release/php8.2-8.2.35-1-noble/*-dbgsym_*
cp upgrade-php82.sh install.md release/php8.2-8.2.35-1-noble/   # keep master copies outside release/
# php8.2-zip needs libzip4t64 from noble universe, which the VMs don't have: ship Ubuntu's .deb
mkdir -p extra && docker run --rm -v $PWD/extra:/out ubuntu:24.04 bash -c \
  'apt-get update -qq && cd /tmp && apt-get download libzip4t64 && cp libzip4t64_*.deb /out/'
sha256sum extra/libzip4t64_*.deb   # d7484efd8d9968ecab9e488fde59980fc633e0eb2bbf7f1ea8e33bf71c9ff1fb (1.7.3-1.1ubuntu2)
cp extra/libzip4t64_*.deb release/php8.2-8.2.35-1-noble/
(cd release/php8.2-8.2.35-1-noble && sha256sum *.deb > SHA256SUMS)
(cd release && tar -cf php8.2-8.2.35-1-noble.tar php8.2-8.2.35-1-noble && sha256sum php8.2-8.2.35-1-noble.tar)
```

## Files in `~/phpubuntu/php82`

| Path | Purpose |
|---|---|
| `Dockerfile.noble` | the build (used for the release) |
| `sury/` | downloaded PPA source + patched tree in `sury/build/php8.2-8.2.35` |
| `out/` | build output (all .debs incl. dbgsym, `build.log`) |
| `old/`, `oldlibs/` | Ubuntu 8.2.7-1ubuntu1 + php8.2-mongodb debs, mantic libicu72 + libzip4 + php-common, used for upgrade tests |
| `extra/` | noble's `libzip4t64`, shipped in the release for php8.2-zip |
| `test-upgrade.sh`, `test-upgrade.log` | upgrade test and its result |
| `release/` | what gets shipped to the VMs |
