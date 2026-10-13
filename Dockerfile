FROM alpine:latest AS build
RUN apk add --no-cache zig musl-dev binutils pkgconf vips-dev vips-heif libheif-aom ca-certificates
WORKDIR /build
COPY build.zig ./
COPY src/ ./src/
RUN zig build test -Doptimize=Debug -j2 --summary all \
    && zig build -Doptimize=ReleaseFast -Dcpu=baseline -j2 \
    && strip zig-out/bin/imgresize

FROM alpine:latest AS runtime
RUN apk add --no-cache ca-certificates vips vips-heif libheif-aom \
    && adduser -S -D -H -u 1000 -G users imgresize \
    && mkdir -p /var/cache/images \
    && chown 1000:100 /var/cache/images
COPY --from=build /build/zig-out/bin/imgresize /usr/local/bin/imgresize
USER 1000:100
EXPOSE 8080
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/local/bin/imgresize"]
