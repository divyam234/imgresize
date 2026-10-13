# imgresize

Read-only HTTP/HTTPS image resizing in **Zig 0.16.x** with libvips as the image
engine. HTTP serving and fetching use `std.http.Server`, `std.http.Client`, and
native Zig I/O. No C application sources, C wrappers, libcurl/libmicrohttpd
application dependencies, or Python test/benchmark dependencies.

Requires Linux, Zig 0.16.x, libvips with its codecs, and `pkg-config`. The small
`src/vips.zig` ABI boundary uses opaque image handles and accessor functions;
application logic uses Zig ownership, error unions, and deferred cleanup.

```sh
nix-shell --run 'make && ./zig-out/bin/imgresize'
# Equivalent build:
nix-shell --run 'zig build -Doptimize=ReleaseFast'
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
| `BUFFER_MEMORY_MB` | 128 | Shared capacity budget for buffered sources and encoded responses |
| `MAX_BODY_MB` | 50 | Maximum downloaded source bytes; not an upload setting |
| `MAX_PIXELS` | 40000000 | Maximum source, requested output and actual output pixel count |

Invalid configuration fails startup. For a CPU/memory-constrained deployment
serving up to 100 concurrent clients:

```sh
PORT=8080 THREAD_POOL=8 RESIZE_WORKERS=2 VIPS_CONCURRENCY=1 \
CONN_LIMIT=128 BUFFER_MEMORY_MB=128 MAX_BODY_MB=20 MAX_PIXELS=25000000 \
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
nix-shell --run 'make test'
# Or:
nix-shell --run 'zig build test -Doptimize=Debug'
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
nix-shell --run 'zig build benchmark -Doptimize=ReleaseFast -- \
  https://example.com/photo.jpg http://127.0.0.1:8080 --concurrency 100 --rounds 10'
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

- Replaced the C application and libcurl/libmicrohttpd HTTP paths with idiomatic
  Zig and native HTTP/I/O while retaining the libvips image engine.
- Replaced Python load testing with a native Zig benchmark and real-server tests.
- Preserved bounded resize concurrency, source/response accounting, pixel guards
  and fast shrink-on-load; added cleanup of libvips thread-local state.
- Bounded native HTTP connection queues and deadlines, verified redirects and
  origin framing, and retained early source release and graceful shutdown.
- Tuned the native worker default to eight and used Zig's SMP allocator for
  optimized source/HTTP buffers after measuring threaded-I/O memory pressure.
