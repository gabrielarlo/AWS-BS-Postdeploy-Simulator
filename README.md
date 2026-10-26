# phpredis postdeploy test harness — Elastic Beanstalk PHP 8.4

Target platform: **PHP 8.4 running on 64bit Amazon Linux 2023 / Elastic Beanstalk platform version 4.13.13**.

AWS's PHP platform history documents this platform branch. The exact PHP patch level can vary with platform release; verify the actual instance with `php -v`.

## What this project does

- Runs Bash syntax validation.
- Runs ShellCheck when available in the lint image.
- Runs safe harness checks and writes a report to `logs/test-report.txt`.
- Sets test metadata to PHP 8.4 / EB AL2023 4.13.13.

## Safety limitation

The harness intentionally does **not** execute the full installer. Your postdeploy script uses `sudo`, DNF/YUM, PECL, writes under `/etc`, and can restart services. Executing the unmodified script with superficial command mocks is not sufficient: it reads `/etc/os-release`, uses absolute paths, and can invoke commands in ways a mock PATH may not intercept.

The `TEST_PLATFORM` variable is scenario metadata only. It does not transform the Amazon Linux 2023 Docker image into the Elastic Beanstalk 4.13.13 AMI or reproduce EB's installed PHP runtime.

## 1. Add the script

Place the complete script you want to test at:

```text
scripts/postdeploy-phpredis.sh
```

If this project still has the placeholder file, replace it with your full postdeploy script before running tests.

## 2. Run checks

From the project root:

```bash
docker compose build
docker compose run --rm lint
docker compose run --rm mock-test
```

The lint service performs `bash -n` and ShellCheck. The mock-test service performs safe static checks only.

## 3. Platform details to verify

On an actual disposable Elastic Beanstalk instance using the target platform, run:

```bash
cat /etc/os-release
php -v
php --ini
php -i | grep -E '^(PHP API|PHP Extension Build|extension_dir)'
command -v php
command -v php-fpm || true
systemctl status php-fpm --no-pager || true
systemctl status nginx --no-pager || true
systemctl status httpd --no-pager || true
```

The platform supports nginx by default and Apache as an alternative, so the service checks should reflect the selected proxy configuration. Do not assume PHP-FPM has the same executable name or configuration paths as a generic container without checking the instance.

## 4. Verify package availability on the target platform

The original script constructs this package name for PHP 8.4:

```text
php8.4-pecl-redis6
```

Do not assume that package exists just because the name is constructed. On the disposable EB instance, inspect the configured repositories and query the exact package:

```bash
sudo dnf clean metadata
sudo dnf makecache
dnf list --available 'php8.4*redis*'
dnf search redis
```

If the package is unavailable, validate whether the PECL fallback is compatible with the exact PHP 8.4 build and its development headers. Do not make production changes until the package route and fallback have been verified.

## 5. Real integration test

For reliable end-to-end validation:

1. Create a separate Elastic Beanstalk staging environment.
2. Select the exact `PHP 8.4 running on 64bit Amazon Linux 2023/4.13.13` platform.
3. Deploy your application and hook to staging only.
4. Inspect deployment events and `/var/log/eb-engine.log`.
5. Verify extension loading:

   ```bash
   php --ri redis
   php -r 'var_dump(extension_loaded("redis"), class_exists("Redis"));'
   ```

6. Test connectivity to a non-production Redis endpoint separately. Extension loading does not prove that network access, TLS, authentication, or ElastiCache connectivity works.
7. If PHP-FPM is used, test the web runtime too; CLI success alone does not prove the application runtime loads Redis.
8. Real integration test completed in sim:

```bash
# CLI
php -r 'new Redis(); echo (new Redis())->connect("redis",6379) ? "PING:PONG" : "FAIL";'
# FPM web runtime (via cgi-fcgi + /run/php-fpm/www.sock)
php-fpm  # started
SCRIPT_FILENAME=/workspace/fpm_redis_test.php REQUEST_METHOD=GET \
  /usr/bin/cgi-fcgi -connect /run/php-fpm/www.sock /workspace/fpm_redis_test.php
# Result: {"loaded":true,"version":"6.2.0","ping":true,"value":"ok_from_php_fpm"}
```

9. Real EB staging deploy (skipped): deploy to EB staging env using `eb create`, verify `eb-engine.log`.

10. Live Redis service (`redis` container) verified: `redis:7-alpine`; extension connects, pings (`PONG`), and reads/writes keys (`set/get` → `pong`).

## Issues to review in the original installer

- `redis_so_is_loadable()` only checks whether `redis.so` exists; it does not prove PHP can load it.
- `ensure_redis_extension_symlink()` can return success even after a failed `ln -sf`.
- The script assumes the CLI and web runtime use compatible PHP installations/configuration.
- A fixed `/etc/php.d/20-redis.ini` may not be the correct configuration location for the EB runtime.
- `dnf` package names and the PECL fallback need verification against this exact platform.

## Completed live tests (simulation)

- Postdeploy script installed `php8.4-pecl-redis6` 6.2.0 (+ igbinary, msgpack) via dnf; `redis.so` loaded.
- CLI: `php --ri redis` shows 6.2.0; `new Redis()` works; `ping()` → `PONG`; `set/get` → value returned.
- FPM web runtime (`php-fpm` + `/run/php-fpm/www.sock` + `cgi-fcgi`): `fpm_redis_test.php` returns `{"loaded":true,"version":"6.2.0","ping":true,"value":"ok_from_php_fpm"}`.
- Real EB staging deploy (skipped): requires AWS EB staging env + `eb create`. Not simulated — needs live AWS resources.

## References

- AWS Elastic Beanstalk PHP platform history: https://docs.aws.amazon.com/elasticbeanstalk/latest/platforms/platform-history-php.html
- AWS supported platforms: https://docs.aws.amazon.com/elasticbeanstalk/latest/platforms/platforms-supported.html

## Full Test Command

```bash
docker compose run --rm eb-php84 bash -lc '
  mkdir -p /run/php-fpm
  /workspace/scripts/postdeploy-phpredis.sh || exit 1
  php-fpm > /dev/null 2>&1 &
  sleep 2
  SCRIPT_FILENAME=/workspace/fpm_redis_test.php REQUEST_METHOD=GET /usr/bin/cgi-fcgi -connect /run/php-fpm/www.sock /workspace/fpm_redis_test.php
'
```