# imgresize

Read-only HTTP/HTTPS image resizing in **Zig 0.16.x** with libvips as the image
engine. HTTP serving and fetching use `std.http.Server`, `std.http.Client`, and
native Zig I/O. No C application sources, C wrappers, libcurl/libmicrohttpd
application dependencies, or Python test/benchmark dependencies.

Requires Linux, Zig 0.16.x, libvips with its codecs, and `pkg-config`. The small
`src/vips.zig` ABI boundary uses opaque image handles and accessor functions;
application logic uses Zig ownership, error unions, and deferred cleanup.

```sh
direnv allow
direnv exec . make
direnv exec . ./zig-out/bin/imgresize
# Equivalent build:
direnv exec . zig build -Doptimize=ReleaseFast
```

URL-encode the source, including its query string:

```sh
curl --get 'http://localhost:8080/resize' \
  --data-urlencode 'url=https://example.com/photo.jpg' \
  --data-urlencode 'w=300' --data-urlencode 'h=200' \
  --data-urlencode 'format=webp' -o resized.webp
```

`GET /health` returns `ok`. Other HTTP methods return 405. Images are fetched
and resized in memory; uploads are not supported. Sources must be decodable by
the installed libvips loaders. Output formats are JPEG, WebP, PNG and AVIF (when
the installed libvips has the encoder). Dimensions default to 300×300, quality
to 80, and fit to `cover`; `contain`, `inside`, `outside` and `fill` are accepted.
`f` aliases `format`, with explicit `format` taking precedence.

Width defaults to `w=300`; omitted `h` defaults to the normalized width.
Only an **explicit zero** opts an axis out: `w=80&h=0&fit=inside` bounds the
displayed width to 80 while preserving aspect ratio (a portrait's height can
exceed 80); `w=0&h=60&fit=inside` bounds the displayed height to 60. EXIF
autorotation is applied before interpreting these axes. `inside` and `contain`
do not enlarge smaller sources. With one unconstrained axis, `cover` and `fill`
also preserve aspect ratio rather than cropping or stretching. Both axes zero
return HTTP 400; `w=80` alone still uses an 80×80 target. Positive parameters
retain the existing 8192 bound and invalid-value fallback; the derived
unconstrained dimension has no arbitrary axis cap, but source, resolved target
and actual output must all satisfy `MAX_PIXELS`. Cache keys distinguish explicit
zero axes from ordinary two-axis targets.

## Docker

```sh
docker build --pull -t imgresize:latest .
docker run -d --name imgresize -p 8080:8080 \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --mount type=volume,src=imgresize-cache,dst=/var/cache/images \
  --cap-drop ALL --security-opt no-new-privileges \
  --cpus=2 --memory=512m --pids-limit=256 \
  -e RESIZE_WORKERS=2 -e CACHE_MAX_SIZE=64MiB \
  -e CACHE_TTL_SECONDS=300 -e CACHE_CLEANUP_SECONDS=30 imgresize:latest
curl -fsS http://localhost:8080/health
docker stop --time=30 imgresize
```

Both stages use `alpine:latest`. The builder installs Alpine's Zig package, runs
the real-server integration suite, then builds a stripped, baseline-CPU
`ReleaseFast` executable. The runtime contains only the service and runtime
packages: libvips, its HEIF module, the AV1 encoder, and HTTPS CA certificates.
It runs as UID 1000 and GID 100 (`users`), with an exec-form entrypoint for SIGTERM shutdown and
a health check that respects `PORT`. No compiler, headers, benchmark, source,
or build cache is copied into the runtime image.

Pass the environment variables below with `-e`. Changing `PORT` also requires
changing the container-side published port. CPU and memory flags enforce limits;
worker counts alone do not. Outbound network restrictions and authentication
remain necessary for untrusted callers.

`latest` and Alpine packages are mutable: rebuild with `--pull` for updates.
This source requires Zig 0.16.x; a future Alpine Zig upgrade may require a source
migration. For Podman, configure `docker.io` as an unqualified-search registry
so `alpine:latest` resolves.

### GitHub container images

The publication workflow builds `linux/amd64` and `linux/arm64` on separate native
runner matrix jobs, runs the Dockerfile's tests on each architecture, and merges
their pushed digests into a single GHCR image. No persistent build cache is used.

```sh
docker pull ghcr.io/divyam234/imgresize:latest
docker run -d --name imgresize -p 8080:8080 \
  --mount type=volume,src=imgresize-cache,dst=/var/cache/images \
  -e CACHE_MAX_SIZE=64MiB ghcr.io/divyam234/imgresize:latest
```

Pushes to `main` and manual runs publish only `latest`; Git tag pushes do not
trigger publication. Each platform is pushed by digest first; `latest` is updated
only after both builds succeed.

Actions use the latest stable major versions checked when this workflow was added:
checkout v7, upload-artifact v7, download-artifact v8, Buildx v4, login v4,
metadata v6, and build-push v7. `GITHUB_TOKEN` authenticates GHCR with job-scoped
`packages: write`; no separate registry secret is required.

The repository is public. GHCR package visibility is managed separately: if an
anonymous pull is denied after the first publication, set the package's visibility
to public in GitHub package settings, or authenticate with `docker login ghcr.io`.

## Resized-image cache

The optional disk-backed LRU cache stores successful encoded resize results, not
source images or libvips operation graphs. Enable it with `CACHE_MAX_SIZE` and a
writable cache directory. There is no second in-memory payload cache.

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `CACHE_MAX_SIZE` | 0 | Maximum cache-owned file bytes, including 32-byte headers; e.g. `30GiB` or `512MB`; 0 disables caching and all cache-directory I/O |
| `CACHE_DIR` | `/var/cache/images` | Writable persistent directory; container UID 1000, GID 100 |
| `CACHE_TTL_SECONDS` | 300 | Absolute lifetime from insertion; hits do not extend expiration |
| `CACHE_CLEANUP_SECONDS` | 30 | Interval between expired-entry cleanup passes |

Sizes accept nonnegative whole numbers with `B`, SI units `KB` through `EB`, IEC
units `KiB` through `EiB` (case-insensitive), or raw bytes without a suffix.
Decimal units use powers of 1000; binary units use powers of 1024. Fractions,
unknown units and products exceeding the platform's representable `usize` are
rejected at startup. TTL and cleanup intervals are positive whole seconds.

The cleaner first runs after one cleanup interval. Lookups reject entries at the
exact expiration boundary, even before the next pass. Hits promote entries to
most-recently-used; admission evicts least-recently-used entries when needed.
Only successful results are admitted. Oversized results and failed admissions
serve the original encoded output without caching, subject to the transient
response memory budget.

Keys include the source URL and normalized width, height, fit, format and quality.
Equivalent parameter ordering, defaults and aliases share a result; distinct
resize options do not. Hits skip origin downloads, decoding and encoding, and
stream from disk using a fixed 32 KiB response buffer rather than loading whole
cached images into RAM. Misses write the original encoded buffer directly to an
owned temporary file and atomically rename it after completion. Interrupted or
failed writes remove their temporary files; startup removes owned orphan temps.

Files persist across service restart. Startup restores the index and byte
accounting, discards expired or invalid owned files, and orders retained entries
by persisted insertion time (live access promotions are not persisted).
Expiration uses the persisted nanosecond UTC insertion timestamp, not process
uptime; backwards wall-clock jumps invalidate future-dated entries. Source
changes are not revalidated before expiry. TTL controls this server's disk cache,
not downstream HTTP caches.

The byte limit includes admission reservations and evicted/expired files still
open for active response leases. Such responses can finish safely and the bytes
remain charged until their last lease closes. Headers count; filesystem block
rounding and filesystem metadata do not. Index metadata is bounded separately to
262144 entries, including pending admissions and pinned removed entries. At that
bound LRU entries are evicted even if disk space remains; pinned capacity may
force an uncached response. At most 1024 response leases and 64 simultaneous
admissions open files, rather than keeping every cached entry's descriptor open.
Deletion failures conservatively retain their charge; restart retries orphan
cleanup. `BUFFER_MEMORY_SIZE` guards transient source and encoded miss responses;
it does not charge disk hits. Decoder scratch, bounded index metadata and worker
buffers still require RAM headroom.

Mount persistent storage read/write at `CACHE_DIR` even with a read-only root
filesystem. For a host bind mount, create the directory owned by UID 1000/GID 100.
Use one running imgresize service per directory. Only recognizable
`imgresize-v1-<SHA256>.cache` files and their owned temporary names are managed;
unrelated files and legacy Stash thumbnails in a shared directory are ignored,
never deleted, and do not count toward this cache's limit.

## Concurrency and memory

A bounded queue accepts concurrent clients while a fixed group of HTTP workers
fetches sources. A separate semaphore limits CPU-heavy image processing. The
server sends `Connection: close` after one response so idle keep-alive clients
cannot occupy the fixed worker group. Successful, fully consumed origin responses
can reuse connections in a pool bounded by the HTTP worker count; failed and
redirect responses close without draining potentially large bodies.

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | 8080 | HTTP listening port |
| `THREAD_POOL` | 8 | HTTP workers, including downloads and resize-slot waiters |
| `RESIZE_WORKERS` | min(online CPUs, 4) | Maximum simultaneous image resizes |
| `VIPS_CONCURRENCY` | 1 | libvips worker concurrency per resize |
| `CONN_LIMIT` | 128 | Maximum accepted queued + active connections; excess connections close |
| `BUFFER_MEMORY_SIZE` | 128MiB | Shared capacity budget for buffered sources and encoded responses; e.g. `128MiB` or `512MB`; same SI/IEC syntax as `CACHE_MAX_SIZE`, max 8GiB |
| `MAX_BODY_SIZE` | 50MiB | Maximum downloaded source bytes; not an upload setting; same SI/IEC syntax as `CACHE_MAX_SIZE`, max 1GiB |
| `MAX_PIXELS` | 40000000 | Maximum source, requested output and actual output pixel count |

Invalid configuration fails startup. For a CPU/memory-constrained deployment
serving up to 100 concurrent clients:

```sh
PORT=8080 THREAD_POOL=8 RESIZE_WORKERS=2 VIPS_CONCURRENCY=1 \
CONN_LIMIT=128 BUFFER_MEMORY_SIZE=128MiB MAX_BODY_SIZE=20MiB MAX_PIXELS=25000000 \
./zig-out/bin/imgresize
```

Start with two resize slots; increase toward the CPU quota only after measuring
representative sources, dimensions and output formats. More HTTP workers can
help slow origins but also hold more buffers and use more I/O runtime resources.
`THREAD_POOL` is an application-worker limit, **not a total OS-thread limit**:
Zig's threaded I/O backend also runs deadline and network tasks, and codecs can
create threads. More resize slots or libvips concurrency increases CPU/memory
pressure.

The shared buffer budget rejects exhausted source/response capacity with 503.
It is **not a total RSS limit**: decoder/encoder scratch space, active output
encoding, TLS/HTTP buffers, thread stacks, libraries and allocator overhead are
additional. Use a container/systemd memory limit and CPU quota for hard resource
ceilings; leave headroom and benchmark those limits. Large images or expensive
AVIF encoding need different sizing from small JPEG/WebP thumbnails.

Optimized builds use Zig's SMP allocator for HTTP/source buffers; large sources
are mapped directly rather than retained in libc thread arenas. Debug builds
retain the checked allocator. Source capacity is freed immediately after encoding,
before reserving response capacity. Encoded output is allocated
by libvips and released with `g_free` when transmission completes, fails or is
canceled; it must not be freed by a Zig arena. Operation caching is disabled to
avoid retaining borrowed source buffers. Image graphs and per-thread libvips
state are released with deferred cleanup. Nonlinear resizing enables decoder
shrink-on-load and trades linear-light colour averaging for lower CPU/memory use.

Downloads permit HTTP/HTTPS only, including redirects, with at most five redirects.
HTTPS verifies system trusted CA certificates. Connection setup has a 5-second
deadline; the whole download, including redirects/body, has a 20-second deadline.
Accepted client connections have a 30-second total deadline including queue time;
CPU-bound codec work cannot be interrupted midway but ownership cleanup completes
before a worker returns. Headers and query storage are bounded to 8 KiB.

Failed, oversized, truncated or timed-out origin downloads return 502;
undecodable images and pixel-limit violations return 400. SIGINT/SIGTERM cancel
network tasks, close queued connections, join workers and release resources.

## Production boundary

**Security:** URL fetching can access private networks, localhost and cloud
metadata services, including through redirects. HTTP/HTTPS-only is not SSRF
protection. Do not expose this service to untrusted clients without authentication
and outbound network restrictions. Put it behind a TLS/authentication proxy with
request rate limits and restricted ingress; the listener binds all IPv4 interfaces.
Reserve connection capacity for health checks.

libvips/GLib allocator replacement with jemalloc or mimalloc is a deployment
choice, not mandatory. Dynamically linked builds can use a compatible allocator
via `LD_PRELOAD`; retain the library's release APIs. Measure fragmentation, RSS,
CPU and latency before choosing one. Fully static builds require static libvips
and all enabled codec dependencies; this build does not claim to be fully static.

## Zig-only tests and benchmarking

```sh
direnv exec . make test
# Or:
direnv exec . zig build test -Doptimize=Debug
```

The native integration suite launches the real server, generates image fixtures
with libvips, and runs a local Zig HTTP origin. It exercises output decoding,
resizing dimensions, redirects, response framing, resource saturation/recovery,
concurrent requests, download deadlines, aborts and graceful shutdown. Debug
builds use Zig's allocator leak checking and check ownership accounting at
shutdown. No Python or curl subprocesses are required by the tests.

Run the native benchmark against a representative image URL:

```sh
./zig-out/bin/imgresize-bench https://example.com/photo.jpg \
  http://127.0.0.1:8080 --concurrency 1 16 100 --rounds 3 --pid <server-pid>
```

Or build and run it directly:

```sh
direnv exec . zig build benchmark -Doptimize=ReleaseFast -- \
  https://example.com/photo.jpg http://127.0.0.1:8080 --concurrency 100 --rounds 10
```

The optional Bash wrapper invokes the same Zig executable:

```sh
SOURCE_URL=https://example.com/photo.jpg BASE=http://127.0.0.1:8080 \
N=100 ROUNDS=10 PID=<server-pid> ./scripts/load_test.sh
```

One warmup request precedes the measured rounds. Each round runs
`max(20, concurrency)` requests under a 180-second deadline. JSON lines report
latencies, throughput, failures and total response bytes; `--pid`/`PID` enables
Linux server CPU-time, RSS and thread sampling every 20 ms. The benchmark streams
responses and validates HTTP status, WebP framing and length. Any request failure
produces a nonzero exit. It does not establish pixel quality or performance for
every source/encoder, and the benchmark itself consumes separate CPU resources.

Observed local-origin workload: repeated 2400×1600 JPEG (1,485,044 bytes),
resized to 300×200 WebP at quality 80 with 100 concurrent clients.

| Profile | Requests / failures | Throughput | Peak sampled RSS | CPU seconds / 100 requests |
| --- | --- | --- | --- | --- |
| Default: 8 HTTP workers, 4 resize slots, SMP buffers | 1,000 / 0 | 35.94–38.05/s | 88.24 MiB | 8.22–8.34 |
| Constrained: 8 HTTP workers, 2 resize slots, SMP buffers | 100 / 0 | 26.71/s | 75.58 MiB | 7.17 |

The initial 16-worker native profile used 165.17 MiB sampled peak RSS on the same
workload. Eight workers and directly mapped source buffers reduced that footprint
without losing 100-client capacity. These are workload-specific observations, not
guarantees for slow origins, large outputs or other codecs. Native HTTPS image
fetching, benchmark rejection of non-WebP responses, and the shell wrapper were
also exercised.

## Changes

- Added an `alpine:latest` multi-stage Docker build, non-root runtime, health
  check, AVIF encoder and HTTPS certificate bundle.
- Added native amd64/arm64 GitHub Actions matrix publication to GHCR with a
  merged multi-architecture manifest and major-version action references.
- Added configurable, byte-bounded resized-response LRU caching with absolute
  TTL, periodic expiration cleanup and zero-copy response leases.
- Replaced the C application and libcurl/libmicrohttpd HTTP paths with idiomatic
  Zig and native HTTP/I/O while retaining the libvips image engine.
- Replaced Python load testing with a native Zig benchmark and real-server tests.
- Preserved bounded resize concurrency, source/response accounting, pixel guards
  and fast shrink-on-load; added cleanup of libvips thread-local state.
- Bounded native HTTP connection queues and deadlines, verified redirects and
  origin framing, and retained early source release and graceful shutdown.
- Tuned the native worker default to eight and used Zig's SMP allocator for
  optimized source/HTTP buffers after measuring threaded-I/O memory pressure.
