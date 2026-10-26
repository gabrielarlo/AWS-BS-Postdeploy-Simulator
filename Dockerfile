FROM --platform=linux/amd64 amazonlinux:2023

ENV container=docker
ENV PHP_VERSION=8.4

RUN dnf install -y --allowerasing \
        bash \
        curl \
        ca-certificates \
        tar \
        gzip \
        grep \
        findutils \
        which \
        shadow-utils \
        sudo \
        procps-ng \
        gcc \
        make \
        autoconf \
        automake \
        libtool \
        pkgconf \
        git \
        openssl-devel \
        zlib-devel \
        libcurl-devel \
        libxml2-devel \
        oniguruma-devel \
        fcgi \
    && dnf clean all

# Install PHP 8.4 and PHP-FPM from available repositories.
# Fail explicitly if the base image does not provide these packages.
RUN dnf install -y --allowerasing \
        php8.4 \
        php8.4-cli \
        php8.4-common \
        php8.4-devel \
        php8.4-fpm \
        php-pear \
    && dnf clean all

# Verify the installed PHP version.
RUN php -v && \
    php-fpm --version && \
    phpize --version

WORKDIR /workspace

COPY . /workspace

RUN chmod +x /workspace/tests/*.sh 2>/dev/null || true

CMD ["/bin/bash"]
