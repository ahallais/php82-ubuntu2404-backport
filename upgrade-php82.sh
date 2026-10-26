#!/bin/bash
# Upgrade the php8.2 packages installed on this host to 8.2.35-1~ubuntu24.04+1
# (fix for CVE-2026-109618 / CVE-2026-109619). Run from this directory as root.
#   ./upgrade-php82.sh          -> dry run only
#   ./upgrade-php82.sh --apply  -> install + restart php8.2-fpm
set -euo pipefail
cd "$(dirname "$0")"
sha256sum --quiet -c SHA256SUMS

# Every installed (ii, or hi = held) php8.2 package that has a rebuilt .deb in this bundle.
# Extension packages from other sources (php8.2-mongodb, ...) have none and are left alone:
# they keep working, the PHP API (20220829) is unchanged.
installed=$(dpkg-query -W -f '${db:Status-Abbrev}|${Package}|${Version}\n' 'php8.2*' 'libapache2-mod-php8.2' 'libphp8.2-embed' 2>/dev/null || true)
debs=()
for p in $(echo "$installed" | awk -F'|' '$1 ~ /^[ih]i/ {print $2}'); do
    f=$(ls ./"${p}"_8.2.35-1~ubuntu24.04+1_*.deb 2>/dev/null || true)
    if [ -n "$f" ]; then debs+=("$f"); else echo "Keeping $p (not part of the php8.2 source package)"; fi
done
if [ ${#debs[@]} -eq 0 ]; then
    echo "no installed php8.2 package found. dpkg reports:" >&2
    echo "${installed:-  (nothing matching php8.2*)}" >&2
    exit 1
fi
echo "Will upgrade: ${debs[*]}"

# php8.2-zip needs libzip4t64, which is in noble's universe component (often not enabled).
# The bundle ships Ubuntu's own libzip4t64; it replaces mantic's libzip4 (t64 rename).
pkgs=("${debs[@]}")
case " ${debs[*]} " in *" ./php8.2-zip_"*) pkgs+=(./libzip4t64_*_amd64.deb) ;; esac

# Dry run: abort (without touching anything) if apt would have to upgrade or remove
# anything besides the php8.2 packages above. Newly installed libraries (e.g. noble's
# libicu74 next to mantic's libicu72) are allowed; "Inst pkg [oldver]" means an upgrade.
# The only removal allowed is libzip4, replaced by libzip4t64.
sim=$(apt-get -s install "${pkgs[@]}" 2>&1) || { echo "$sim" >&2; exit 1; }
extra=$(echo "$sim" | grep -E '^(Inst|Remv) ' | grep -v -E '^Inst (php8\.2|libapache2-mod-php8\.2|libphp8\.2-embed)' | grep -v -E '^Remv libzip4 ' || true)
new_libs=$(echo "$extra" | grep -E '^Inst lib[^ ]+ \(' || true)
extra=$(echo "$extra" | grep -v -E '^Inst lib[^ ]+ \(' || true)
[ -z "$extra" ] || { echo "Aborting, apt would also change:" >&2; echo "$extra" >&2; exit 1; }
[ -z "$new_libs" ] || { echo "Will also install new libraries:"; echo "$new_libs"; }
[ "${1:-}" = "--apply" ] || { echo "Dry run OK. Re-run with --apply."; exit 0; }

cp -a /etc/php/8.2 "/root/etc-php-8.2.bak.$(date +%F-%H%M)"
# keep local edits of dpkg conffiles (pool.d/www.conf) and ucf-managed php.ini files
UCF_FORCE_CONFFOLD=1 apt-get install -y -o Dpkg::Options::=--force-confold "${pkgs[@]}"
php-fpm8.2 -t
if systemctl is-enabled --quiet php8.2-fpm 2>/dev/null; then systemctl restart php8.2-fpm; fi
php-fpm8.2 -v | head -1
