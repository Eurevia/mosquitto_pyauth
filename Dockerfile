# Adapted from: https://github.com/iegomez/mosquitto-go-auth

# Mosquitto version
# 2.0.15 → false "disconnected due to out of memory" on QoS1 disconnect (#3253/#2627)
# 2.0.22 → fixes bogus OOM disconnect reporting
# 2.0.23 → additional broker fixes (session/OpenSSL/persistence); tarball on mosquitto.org
ARG MOSQUITTO_VERSION=2.0.23

# Use debian:stable-slim as a builder for Mosquitto and dependencies.
FROM debian:stable-slim as mosquitto_builder
ARG MOSQUITTO_VERSION

# Get mosquitto build dependencies.
RUN set -ex; \
    apt-get update; \
    apt-get install -y wget build-essential cmake libssl-dev libcjson-dev

WORKDIR /app

RUN mkdir -p mosquitto

RUN wget https://mosquitto.org/files/source/mosquitto-${MOSQUITTO_VERSION}.tar.gz

RUN tar xzvf mosquitto-${MOSQUITTO_VERSION}.tar.gz

# Build mosquitto without websockets (MQTT/TLS only in our deployment).
# Avoids building libwebsockets, which fails on GCC 14 with LWS 4.2.2 (-Werror=enum-int-mismatch).
RUN set -ex; \
    cd mosquitto-${MOSQUITTO_VERSION}; \
    make CFLAGS="-Wall -O2" WITH_WEBSOCKETS=no; \
    make install;

# Use debian:stable-slim as a builder for the Mosquitto Python Auth plugin.
FROM --platform=$BUILDPLATFORM debian:stable-slim AS python_builder

# Bring TARGETPLATFORM to the build scope
ARG TARGETPLATFORM
ARG BUILDPLATFORM

# Get python build deps
RUN set -ex; \
    apt-get update; \
    apt-get install -y python3-dev libc-ares2 libc-ares-dev build-essential cmake pkg-config

# Install needed libc and gcc for target platform.
RUN set -ex; \
  if [ ! -z "$TARGETPLATFORM" ]; then \
    case "$TARGETPLATFORM" in \
  "linux/arm64") \
    apt update && apt install -y gcc-aarch64-linux-gnu libc6-dev-arm64-cross \
    ;; \
  "linux/arm/v7") \
    apt update && apt install -y gcc-arm-linux-gnueabihf libc6-dev-armhf-cross \
    ;; \
  "linux/arm/v6") \
    apt update && apt install -y gcc-arm-linux-gnueabihf libc6-dev-armel-cross libc6-dev-armhf-cross \
    ;; \
  esac \
  fi

WORKDIR /app
COPY --from=mosquitto_builder /usr/local/include/ /usr/local/include/
COPY --from=mosquitto_builder /usr/local/lib/ /usr/local/lib/

COPY ./ ./
# PYTHON_VERSION is auto-detected from system python3 (see Makefile)
RUN set -ex; \
    make clean; \
    make USE_CARES=1

#Start from a new image.
FROM debian:stable-slim

RUN set -ex; \
    apt update; \
    apt install -y libc-ares2 libcjson1 openssl uuid tini wget cmake libssl-dev python3 python3-pip

RUN mkdir -p /mosquitto/config /mosquitto/data /mosquitto/log
RUN set -ex; \
    groupadd mosquitto; \
    useradd -s /sbin/nologin mosquitto -g mosquitto -d /mosquitto/data; \
    chown -R mosquitto:mosquitto /mosquitto/config; \
    chown -R mosquitto:mosquitto /mosquitto/data; \
    chown -R mosquitto:mosquitto /mosquitto/log

#Copy confs, plugin so and mosquitto binary.
COPY --from=mosquitto_builder /app/mosquitto/ /mosquitto/
COPY --from=python_builder /app/auth_plugin_pyauth.so /mosquitto/
COPY --from=mosquitto_builder /usr/local/sbin/mosquitto /usr/sbin/mosquitto
COPY --from=mosquitto_builder /usr/local/include/ /usr/local/include/
COPY --from=mosquitto_builder /usr/local/lib/libmosquitto* /usr/local/lib/

COPY --from=mosquitto_builder /usr/local/bin/mosquitto_passwd /usr/bin/mosquitto_passwd
COPY --from=mosquitto_builder /usr/local/bin/mosquitto_sub /usr/bin/mosquitto_sub
COPY --from=mosquitto_builder /usr/local/bin/mosquitto_pub /usr/bin/mosquitto_pub
COPY --from=mosquitto_builder /usr/local/bin/mosquitto_rr /usr/bin/mosquitto_rr

RUN ldconfig;

RUN pip3 install --break-system-packages firebase_admin;

EXPOSE 1884

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD [ "/usr/sbin/mosquitto" ,"-c", "/mosquitto/config/mosquitto.conf" ]
