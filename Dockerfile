FROM golang:1.26.10-alpine@sha256:9ce231b28998b32e116927c61aa5c406183061d4f3f2d61b292c88e7f6bdf7ca AS frp-source

ARG FRP_VERSION=0.71.1
ENV GOTOOLCHAIN=local
WORKDIR /src
RUN go mod download github.com/fatedier/frp@v${FRP_VERSION} \
    && cp -a /go/pkg/mod/github.com/fatedier/frp@v${FRP_VERSION} /src/frp \
    && chmod -R u+w /src/frp

FROM node:22.23.4-bookworm-slim@sha256:de170b39439eb0e5a3444ad7d60b015614a381e10fecae2e30ec9e735122f38d AS frp-web
WORKDIR /src/web
COPY --from=frp-source /src/frp/web ./
RUN npm ci \
    && npm run build --workspace ./frpc \
    && npm run build --workspace ./frps

FROM frp-source AS frp-build
WORKDIR /src/frp
ENV CGO_ENABLED=0
COPY --from=frp-web /src/web/frpc/dist ./web/frpc/dist
COPY --from=frp-web /src/web/frps/dist ./web/frps/dist
# Upstream release binaries still embed vulnerable Go and x/net versions.
RUN go get golang.org/x/net@v0.60.0 \
    && mkdir -p /out \
    && go build -trimpath -ldflags="-s -w" -o /out/ ./cmd/frpc ./cmd/frps

FROM scratch AS frp-server-binary
COPY --from=frp-build /out/frps /frps

FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        busybox \
        ca-certificates \
        curl \
        dropbear-bin \
        openssh-client \
        sudo \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 user \
    && useradd --uid 10001 --gid 10001 --groups sudo --home-dir /home/user --shell /bin/bash user \
    && passwd -d user \
    && printf 'user ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/user-nopasswd \
    && chmod 0440 /etc/sudoers.d/user-nopasswd \
    && printf 'Welcome to Enclava Debian SSH.\n\nYour home folder (/home/user) is persistent and backed by encrypted /state/app-data.\nThe root filesystem is platform-managed and may be reset between deployments.\n' >/etc/motd \
    && mkdir -p /state/app-data/home /state/app-data/.enclava/frp \
    && rm -rf /home/user \
    && ln -s /state/app-data/home/user /home/user \
    && chown -h 10001:10001 /home/user \
    && chown -R 10001:10001 /state/app-data \
    && chown -R 0:0 /state/app-data/.enclava \
    && chmod 0700 /state/app-data/.enclava /state/app-data/.enclava/frp

COPY --from=frp-build /out/frpc /usr/local/bin/frpc

COPY entrypoint.sh /usr/local/bin/debian-ssh-frp-entrypoint
RUN chmod 0755 /usr/local/bin/debian-ssh-frp-entrypoint

WORKDIR /
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/debian-ssh-frp-entrypoint"]
