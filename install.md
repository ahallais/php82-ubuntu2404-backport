# Installing PHP 8.2.35-1~ubuntu24.04+1 (CVE-2026-109618 / CVE-2026-109619 fix)

These packages replace the `php8.2 8.2.7-1ubuntu1` packages on our Ubuntu 24.04 VMs with a
build that contains the fix for **CVE-2026-109618 / CVE-2026-109619** ("PHP2Shell",
GHSA-w8hw-w9fx-j79w, GHSA-6wmf-4rv5-p3rp). They upgrade in place: same package names, same
paths, same config files, same extension API (`20220829`).

## Who this is for

VMs running **Ubuntu 24.04 (noble)** with `php8.2-fpm 8.2.7-1ubuntu1`. That version comes from
the Ubuntu 23.10 (mantic) development archive, so those VMs also have mantic's `libicu72`.
Ubuntu's own `php8.3` (the default `php`) is not touched.

| Package    | Expected on the VM          |
|------------|-----------------------------|
| OS         | Ubuntu 24.04.x LTS          |
| libc6      | 2.39-0ubuntu8.x             |
| php-common | **2:93ubuntu1** (mantic)    |
| php8.2-*   | 8.2.7-1ubuntu1              |

Check a VM with:

```bash
. /etc/os-release; echo "$PRETTY_NAME"
dpkg -l libc6 libicu74 libssl3t64 libcurl4t64 php-common 'php8.2*' | awk '/^ii/{print $2, $3}'
apt-mark showhold
```

`php-common` must be `2:93ubuntu1`. Noble's `2:93ubuntu2` declares `Breaks: php8.2-common`
(Ubuntu dropped php8.2 in 24.04), so apt keeps it back on these VMs. **Never run
`apt full-upgrade` / `apt dist-upgrade` on them**: apt would take `php-common 2:93ubuntu2` and
remove every php8.2 package. To lock this in: `sudo apt-mark hold php-common`.

If the VM is a different setup (other Ubuntu release, php8.2 from the Sury PPA, ...) the dry
run below refuses to install. Don't force it; ask for a matching build.

## Contents of the bundle

```
php8.2-8.2.35-1-noble/
  *.deb               all php8.2 packages (fpm, cli, common, curl, gd, intl, pgsql, zip, ...)
                      + Ubuntu's libzip4t64 (noble universe), needed by php8.2-zip
  SHA256SUMS          checksums of the .deb files
  upgrade-php82.sh    install script
  install.md          this file
```

## 1. Copy the bundle to the VM

Nothing is compiled on the VM.

```bash
scp php8.2-8.2.35-1-noble.tar webadmin@target-vm:/tmp/
ssh webadmin@target-vm
cd /tmp && tar xf php8.2-8.2.35-1-noble.tar && cd php8.2-8.2.35-1-noble
```

## 2. Dry run (changes nothing)

```bash
sudo ./upgrade-php82.sh
```

The script:

1. Checks every `.deb` against `SHA256SUMS`.
2. Picks the php8.2 packages installed on this VM (`ii` or held `hi`) that have a rebuilt
   `.deb` in the bundle. Others are listed as `Keeping ...`: `php8.2-mongodb` (separate source
   package) is left as is and keeps working. If it finds none, it prints what dpkg reports.
3. Simulates the install with apt. It **aborts** if apt would also need to upgrade or remove
   any other package. It may install new libraries, which it lists:
   - `libzip4t64` for `php8.2-zip`, from the bundle. It's Ubuntu's own noble package, in the
     universe component, which the VMs don't have enabled. It replaces mantic's `libzip4` (the
     same library, renamed by Ubuntu's 64-bit time transition).
   - other noble libraries (e.g. `libicu74`) from the VM's normal Ubuntu repositories.

Expected end of output: `Dry run OK. Re-run with --apply.`

## 3. Install

Pick a quiet moment. php8.2-fpm restarts, so in-flight requests are dropped.

```bash
sudo ./upgrade-php82.sh --apply
```

What it does:

1. Backs up `/etc/php/8.2` to `/root/etc-php-8.2.bak.<date>`.
2. Installs the packages and **keeps your local config edits** (`pool.d/*.conf`, `php.ini`,
   `conf.d/*`).
3. Runs `php-fpm8.2 -t` (configuration test).
4. Restarts `php8.2-fpm` and prints the new version.

## 4. Verify

```bash
php-fpm8.2 -v | head -1                 # PHP 8.2.35-1~ubuntu24.04+1 (fpm-fcgi)
php8.2 -v | head -1                     # PHP 8.2.35-1~ubuntu24.04+1 (cli)
systemctl status php8.2-fpm --no-pager  # active (running)
dpkg -l 'php8.2*' | awk '/^ii/{print $2, $3}'   # all 8.2.35-1~ubuntu24.04+1 except php8.2-mongodb
php8.2 -m | grep -i mongodb             # still loaded
```

Then load the application through the web server and check `/var/log/php8.2-fpm.log` and the
web server error log.

## 5. After the upgrade: temporary mitigations

- If `pm.max_requests = 1` was set in `/etc/php/8.2/fpm/pool.d/*.conf` as a mitigation, it is
  no longer needed. Set it back to e.g. `500`, then `sudo systemctl restart php8.2-fpm`.
- **Keep** `session.upload_progress.enabled = 0` (e.g.
  `/etc/php/8.2/fpm/conf.d/99-mitigate-php2shell.ini`) unless the application needs upload
  progress. The advisory recommends this even after patching.

## 6. Optional: remove php8.3

Ubuntu's php8.3 (the default `php`) is not needed if everything runs on php8.2. Do this
**after** the upgrade, so `libicu74` is already used by the new `php8.2-intl`.

First check that nothing uses php8.3:

```bash
grep -rnE 'php8\.3|php-fpm\.sock' /etc/nginx /etc/apache2 2>/dev/null   # web server -> which FPM socket
ls -l /run/php/                                  # php-fpm.sock may point to php8.3-fpm.sock
systemctl is-active php8.3-fpm
grep -rn 'php8\.3\|/usr/bin/php ' /etc/cron* /var/spool/cron 2>/dev/null
```

If the web server uses `/run/php/php-fpm.sock`, point it at `/run/php/php8.2-fpm.sock`
explicitly first. Then:

```bash
sudo apt-get -s purge 'php8.3*'   # simulate: only php8.3-* and php / php-cli / php-fpm meta packages
sudo apt-get purge 'php8.3*'
sudo apt-mark hold php-common     # keep mantic's 2:93ubuntu1 (see "Who this is for")
php -v | head -1                  # PHP 8.2.35 (cli): /usr/bin/php now points to php8.2
```

`php-common` and the php8.2 packages stay, and `apt autoremove` has nothing to remove (tested).
Scripts and cron jobs that call `php` now run php8.2.

## Behaviour change to know about

When a script exceeds `memory_limit` ("Allowed memory size ... exhausted"), the patched PHP
**kills the worker immediately** instead of running the normal error handling. This is
intended: it is how the fix removes out-of-memory as an attack path.

- The web server returns **502** for that request instead of 500.
- Shutdown functions and destructors don't run for that request.
- The message no longer appears in PHP's `error_log`. The FPM log shows
  `child NNNN exited with code 1`. Look for that line when investigating 502s.

Other fatal errors (uncaught exceptions, undefined functions, ...) behave as before.

## Rollback

Ubuntu removed `8.2.7-1ubuntu1` from its archive, so download the packages before upgrading
and keep them. From a machine with internet access:

```bash
sp=$(curl -fsS 'https://api.launchpad.net/1.0/ubuntu/+archive/primary?ws.op=getPublishedSources&source_name=php8.2&version=8.2.7-1ubuntu1&exact_match=true' \
     | python3 -c 'import sys,json;print(json.load(sys.stdin)["entries"][0]["self_link"])')
for p in bcmath cli common curl dev fpm gd imap intl ldap mbstring opcache pgsql readline soap xml zip; do
  curl -fsS "$sp?ws.op=binaryFileUrls" | python3 -c 'import sys,json;print("\n".join(json.load(sys.stdin)))' \
    | grep "/php8.2-${p}_8.2.7-1ubuntu1_amd64.deb$" | xargs curl -fsSLO
done
```

Then on the VM:

```bash
sudo dpkg --force-confold -i ./*_8.2.7-1ubuntu1_amd64.deb   # downgrade (dpkg warns, that's expected)
sudo cp -a /root/etc-php-8.2.bak.<date>/. /etc/php/8.2/        # if config needs restoring
sudo systemctl restart php8.2-fpm
```

Rolling back reopens the vulnerability. Put the temporary mitigations back
(`pm.max_requests = 1`, `session.upload_progress.enabled = 0`).
