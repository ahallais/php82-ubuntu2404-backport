#!/bin/bash
# Runs inside ubuntu:24.04. /old = Ubuntu 8.2.7-1ubuntu1 debs (+ /oldlibs: mantic libicu72),
# /new = release dir with the rebuilt 8.2.35-1~ubuntu24.04+1 debs, SHA256SUMS and upgrade-php82.sh.
set -e
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends libfcgi-bin procps >/dev/null

echo "== 1. install Ubuntu 8.2.7-1ubuntu1 + php8.3 (state of the server)"
apt-get install -y -qq --no-install-recommends /oldlibs/*.deb /old/*.deb php8.3-cli php8.3-fpm >/tmp/old.log 2>&1 || { tail -20 /tmp/old.log; exit 1; }
php-fpm8.2 -v | head -1
php -v | head -1

# Simulate the hardening already applied on the hosts + a local edit to a conffile
echo "session.upload_progress.enabled = 0" > /etc/php/8.2/fpm/conf.d/99-mitigate-php2shell.ini
sed -i 's/^;*pm\.max_requests\s*=.*/pm.max_requests = 1/' /etc/php/8.2/fpm/pool.d/www.conf
sed -i 's/^memory_limit = .*/memory_limit = 256M/' /etc/php/8.2/fpm/php.ini

# Like the server: no universe component (libzip4t64 then comes from the bundle)
sed -i 's/^Components: .*/Components: main restricted/' /etc/apt/sources.list.d/ubuntu.sources
apt-get update -qq >/dev/null
dpkg -l libzip4 libzip4t64 libc-client2007e 2>/dev/null | awk '/^ii/{print $2, $3}'

echo "== 2. dry run, then upgrade with upgrade-php82.sh"
# no systemd in the container: make the script's "systemctl restart" a no-op
printf '#!/bin/sh\necho "systemctl $*"\n' > /usr/local/bin/systemctl && chmod +x /usr/local/bin/systemctl
cp -a /new /tmp/rel
/tmp/rel/upgrade-php82.sh | grep -v "^Will upgrade"
/tmp/rel/upgrade-php82.sh --apply >/tmp/new.log 2>&1 || { tail -30 /tmp/new.log; exit 1; }
tail -1 /tmp/new.log
dpkg -l 'php8.2*' | awk '/^ii/{print $2, $3}'

echo "== 3. config preserved?"
grep -n '^pm.max_requests' /etc/php/8.2/fpm/pool.d/www.conf
grep -n '^memory_limit' /etc/php/8.2/fpm/php.ini
cat /etc/php/8.2/fpm/conf.d/99-mitigate-php2shell.ini
echo -n "default php still: "; php -v | head -1

echo "== 4. binary checks"
php-fpm8.2 -t 2>&1 | tail -1
echo -n "telemetry strings in php-fpm: "; grep -a -c 'telemetry' /usr/sbin/php-fpm8.2 || true
php-fpm8.2 -i | grep -E '^session.upload_progress.enabled'
php8.2 -m | tr '\n' ' '; echo
dpkg -l php8.2-mongodb | awk '/^ii/{print $2, $3}'; php8.2 -r 'echo "mongodb ext: ", phpversion("mongodb"), "\n";'
echo -n "php-common: "; dpkg-query -W -f '${Version}\n' php-common
php8.2 -r 'echo "intl icu: ", INTL_ICU_VERSION, "\n";'

echo "== 5. serve requests through FPM"
mkdir -p /run/php /var/www && echo '<?php echo "OK ", PHP_VERSION, " pid=", getmypid(), "\n";' > /var/www/t.php
php-fpm8.2 -D; sleep 1
for i in 1 2 3; do SCRIPT_FILENAME=/var/www/t.php REQUEST_METHOD=GET cgi-fcgi -bind -connect /run/php/php8.2-fpm.sock | tail -1; done
echo -n "libzip: "; dpkg -l 'libzip4*' | awk '/^ii/{print $2, $3}' | tr '\n' ' '; echo
php8.2 -r '$z = new ZipArchive; var_dump($z->open("/tmp/t.zip", ZipArchive::CREATE) && $z->addFromString("a", "b") && $z->close());'
