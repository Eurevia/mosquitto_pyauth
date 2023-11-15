# Adapted from: https://github.com/iegomez/mosquitto-go-auth

# Define Mosquitto version
ARG MOSQUITTO_VERSION=2.0.15
# Define libwebsocket version
ARG LWS_VERSION=4.2.2

# Use debian:stable-slim as a builder for Mosquitto and dependencies.
FROM debian:stable-slim as mosquitto_builder
ARG MOSQUITTO_VERSION
ARG LWS_VERSION

# Get mosquitto build dependencies.
RUN set -ex; \
    apt-get update; \
    apt-get install -y wget build-essential cmake libssl-dev libcjson-dev

# Get libwebsocket. Debian's libwebsockets is too old for Mosquitto version > 2.x so it gets built from source.
RUN set -ex; \
    wget https://github.com/warmcat/libwebsockets/archive/v${LWS_VERSION}.tar.gz -O /tmp/lws.tar.gz; \
    mkdir -p /build/lws; \
    tar --strip=1 -xf /tmp/lws.tar.gz -C /build/lws; \
    rm /tmp/lws.tar.gz; \
    cd /build/lws; \
    cmake . \
        -DCMAKE_BUILD_TYPE=MinSizeRel \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DLWS_IPV6=ON \
        -DLWS_WITHOUT_BUILTIN_GETIFADDRS=ON \
        -DLWS_WITHOUT_CLIENT=ON \
        -DLWS_WITHOUT_EXTENSIONS=ON \
        -DLWS_WITHOUT_TESTAPPS=ON \
        -DLWS_WITH_HTTP2=OFF \
        -DLWS_WITH_SHARED=OFF \
        -DLWS_WITH_ZIP_FOPS=OFF \
        -DLWS_WITH_ZLIB=OFF \
        -DLWS_WITH_EXTERNAL_POLL=ON; \
    make -j "$(nproc)"; \
    rm -rf /root/.cmake

WORKDIR /app

RUN mkdir -p mosquitto

RUN wget http://mosquitto.org/files/source/mosquitto-${MOSQUITTO_VERSION}.tar.gz

RUN tar xzvf mosquitto-${MOSQUITTO_VERSION}.tar.gz

# Build mosquitto.
RUN set -ex; \
    cd mosquitto-${MOSQUITTO_VERSION}; \
    make CFLAGS="-Wall -O2 -I/build/lws/include" LDFLAGS="-L/build/lws/lib" WITH_WEBSOCKETS=yes; \
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
RUN set -ex; \
    make clean; \
    make USE_CARES=1 PYTHON_VERSION=3.11

#Start from a new image.
FROM debian:stable-slim

RUN set -ex; \
    apt update; \
    apt install -y libc-ares2 openssl uuid tini wget cmake libssl-dev python3 python3-pip

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

EXPOSE 1883 1884

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD [ "/usr/sbin/mosquitto" ,"-c", "/mosquitto/config/mosquitto.conf" ]
