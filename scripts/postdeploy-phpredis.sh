#!/bin/bash

# Install phpredis extension for Elastic Beanstalk deployment
# Supports Amazon Linux 2 (PHP 8.1) and Amazon Linux 2023 (PHP 8.1 / 8.5 and newer via version-derived packages)

set -e  # Exit on any error

detect_linux_platform() {
    if [ ! -f /etc/os-release ]; then
        echo "unknown"
        return 0
    fi

    # shellcheck source=/dev/null
    . /etc/os-release

    if [ "${VERSION_ID:-}" = "2023" ] || [ "${PLATFORM_ID:-}" = "platform:al2023" ]; then
        echo "al2023"
        return 0
    fi

    if [ "${VERSION_ID:-}" = "2" ]; then
        echo "al2"
        return 0
    fi

    echo "unknown"
}

LINUX_PLATFORM=$(detect_linux_platform)
PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "unknown")

echo "Starting phpredis installation (platform: $LINUX_PLATFORM, PHP $PHP_VERSION)..."

# Check if phpredis is already installed and properly loaded
echo "Checking current Redis extension status..."
REDIS_LOADED=$(php -m 2>/dev/null | grep -i redis || echo "")

if [ -n "$REDIS_LOADED" ]; then
    echo "Redis extension is already loaded: $REDIS_LOADED"

    if php -r "if (extension_loaded('redis')) { echo 'Redis extension is working properly'; exit(0); } else { echo 'Redis extension loaded but not functional'; exit(1); }" 2>/dev/null; then
        echo "phpredis is already installed and working properly"
        php --ri redis 2>/dev/null || echo "Redis extension info not available"
        exit 0
    else
        echo "Redis extension is loaded but not functional, proceeding with reinstallation..."
    fi
else
    echo "Redis extension not currently loaded, proceeding with installation..."
fi

redis_so_is_loadable() {
    local php_ext_dir
    # the runtime's ini_get is the load-path truth (php-config reflects build config, which can disagree with the runtime — amazonlinux/amazon-linux-2023 #328); php-config only as fallback
    php_ext_dir="$(php -r 'echo ini_get("extension_dir");' 2>/dev/null || php-config --extension-dir)"

    if [ -f "$php_ext_dir/redis.so" ]; then
        return 0
    fi

    local php_version
    php_version=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    if [ -f "/usr/lib64/php${php_version}/modules/redis.so" ]; then
        return 0
    fi

    return 1
}

ensure_redis_extension_symlink() {
    local php_ext_dir
    # the runtime's ini_get is the load-path truth (php-config reflects build config, which can disagree with the runtime — amazonlinux/amazon-linux-2023 #328); php-config only as fallback
    php_ext_dir="$(php -r 'echo ini_get("extension_dir");' 2>/dev/null || php-config --extension-dir)"
    echo "PHP extension directory: $php_ext_dir"

    if [ -f "$php_ext_dir/redis.so" ]; then
        return 0
    fi

    local php_version versioned_dir module
    php_version=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
    versioned_dir="/usr/lib64/php${php_version}/modules"

    # AL2023 pecl rpms lay modules in the versioned dir; EB's runtime may load from /usr/lib64/php/modules
    # (amazonlinux/amazon-linux-2023 #328) and redis.so needs its serializer companions (igbinary, msgpack)
    # resolvable there too, else it fails with undefined symbols.
    if [ -f "$versioned_dir/redis.so" ]; then
        for module in redis.so igbinary.so msgpack.so; do
            if [ -f "$versioned_dir/$module" ] && [ ! -e "$php_ext_dir/$module" ]; then
                echo "Linking $versioned_dir/$module -> $php_ext_dir/$module"
                sudo ln -sf "$versioned_dir/$module" "$php_ext_dir/$module" || echo "Warning: failed to link $module"
            fi
        done
        return 0
    fi

    return 1
}

install_redis_al2023() {
    echo "Using Amazon Linux 2023 install path..."

    local redis_pkg="php${PHP_VERSION}-pecl-redis6"
    local php_devel_pkg="php${PHP_VERSION}-devel"

    echo "Target packages for PHP $PHP_VERSION: $redis_pkg, $php_devel_pkg"

    echo "Updating dnf cache..."
    sudo dnf clean metadata
    sudo dnf makecache

    if ! rpm -q "$redis_pkg" >/dev/null 2>&1; then
        if ! redis_so_is_loadable; then
            echo "Installing $redis_pkg via dnf..."
            if ! sudo dnf install -y "$redis_pkg"; then
                echo "Warning: dnf install $redis_pkg failed or package not found; will try PECL fallback if needed"
            fi
        else
            echo "redis.so already present, skipping dnf install"
        fi
    else
        echo "$redis_pkg already installed via rpm"
    fi

    if ensure_redis_extension_symlink; then
        return 0
    fi

    echo "DNF install did not produce a loadable redis.so, trying PECL fallback..."
    sudo dnf install -y \
        "$php_devel_pkg" \
        php-pear \
        gcc \
        gcc-c++ \
        make \
        autoconf \
        libtool \
        pkgconfig \
        zlib-devel \
        redis6-devel || echo "Warning: failed to install build dependencies; PECL build will likely fail"

    # reach here only when dnf produced nothing loadable; install unconditionally —
    # pecl list reads the invoking user's registry while the install ran via sudo, so it can say "already installed" for a module that never loads
    echo "Installing phpredis via PECL..."
    /usr/bin/yes 'no' | sudo pecl install redis

    ensure_redis_extension_symlink || true
}

install_redis_al2() {
    echo "Using Amazon Linux 2 install path..."

    echo "Enabling Amazon Linux Extras for PHP 8.1..."
    sudo amazon-linux-extras enable php8.1

    echo "Updating yum cache..."
    sudo yum clean metadata
    sudo yum makecache

    echo "Installing development dependencies..."
    sudo yum groupinstall -y "Development Tools" || echo "Development Tools already installed"
    sudo yum install -y \
        php-devel \
        php-pear \
        gcc \
        gcc-c++ \
        make \
        autoconf \
        libtool \
        pkgconfig \
        zlib-devel || echo "Warning: failed to install AL2 build dependencies; PECL build will likely fail"

    # see the AL2023 fallback note: nothing loadable exists here, so install unconditionally
    echo "Installing phpredis via PECL..."
    /usr/bin/yes 'no' | sudo pecl install redis

    ensure_redis_extension_symlink || true
}

install_redis() {
    case "$LINUX_PLATFORM" in
        al2023)
            install_redis_al2023
            ;;
        al2)
            install_redis_al2
            ;;
        *)
            echo "Error: unsupported platform '$LINUX_PLATFORM' (expected al2 or al2023)"
            if [ -f /etc/os-release ]; then
                echo "OS release details:"
                grep -E '^(NAME|VERSION|VERSION_ID|PLATFORM_ID)=' /etc/os-release || true
            fi
            exit 1
            ;;
    esac
}

install_redis

if ! redis_so_is_loadable; then
    echo "Error: redis.so not found after install attempts on platform $LINUX_PLATFORM"
    exit 1
fi

# Check if redis extension is already configured
REDIS_INI_FILE="/etc/php.d/20-redis.ini"
REDIS_ALREADY_CONFIGURED=false
PHP_MODS_DIR="/etc/php/${PHP_VERSION}/mods-available"

if [ -f "$REDIS_INI_FILE" ]; then
    echo "Redis configuration file already exists: $REDIS_INI_FILE"
    if grep -q "extension=redis.so" "$REDIS_INI_FILE"; then
        echo "Redis extension already configured in $REDIS_INI_FILE"
        REDIS_ALREADY_CONFIGURED=true
    fi
fi

for php_dir in /etc/php.d "$PHP_MODS_DIR" /usr/local/etc/php/conf.d; do
    if [ -d "$php_dir" ]; then
        # match bare and spaced forms: AL2023 rpm ships /etc/php.d/50-redis.ini as "extension = redis.so"
        if grep -lqE "extension[[:space:]]*=[[:space:]]*redis" "$php_dir"/*.ini 2>/dev/null; then
            echo "Redis extension already configured in $php_dir"
            REDIS_ALREADY_CONFIGURED=true
            break
        fi
    fi
done

if [ "$REDIS_ALREADY_CONFIGURED" = false ]; then
    echo "Creating phpredis configuration..."
    sudo tee "$REDIS_INI_FILE" > /dev/null <<EOF
; Enable Redis extension module
extension=redis.so

; Redis session handler
; session.save_handler = redis
; session.save_path = "tcp://127.0.0.1:6379"

; Redis configuration
; redis.arrays.autorehash = 1
; redis.clusters.cache_slots = 1
; redis.clusters.timeout = 0
; redis.clusters.read_timeout = 0
; redis.clusters.failover_mode = 0
EOF
    echo "Created Redis configuration file: $REDIS_INI_FILE"
else
    echo "Skipping Redis configuration creation - already configured"
fi

if sudo systemctl is-active --quiet php-fpm; then
    echo "Restarting PHP-FPM..."
    sudo systemctl restart php-fpm
fi

if sudo systemctl is-active --quiet httpd; then
    echo "Restarting Apache..."
    sudo systemctl restart httpd
elif sudo systemctl is-active --quiet nginx; then
    echo "Restarting Nginx..."
    sudo systemctl restart nginx
fi

echo "Verifying phpredis installation..."

REDIS_TEST_RESULT=$(php -d error_reporting=0 -m 2>/dev/null | grep -i redis || echo "")

if [ -n "$REDIS_TEST_RESULT" ]; then
    echo "phpredis successfully installed and loaded!"
    echo "Loaded Redis extension: $REDIS_TEST_RESULT"

    echo "phpredis version information:"
    php -d error_reporting=0 --ri redis 2>/dev/null || echo "Redis extension info not available (this may be normal)"

    echo "Testing basic Redis functionality..."
    php -d error_reporting=0 -r "
        if (class_exists('Redis')) {
            echo 'Redis class is available' . PHP_EOL;
            echo 'Redis extension version: ' . phpversion('redis') . PHP_EOL;
        } else {
            echo 'Redis class not available' . PHP_EOL;
        }
    " 2>/dev/null || echo "Could not test Redis functionality"

else
    echo "phpredis installation failed!"
    echo "Available PHP modules:"
    php -d error_reporting=0 -m 2>/dev/null | sort
    exit 1
fi

echo "PHP configuration files:"
php --ini

echo "phpredis installation completed successfully!"
