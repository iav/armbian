# sccache: Server Setup Guide

`sccache` supports several remote backends; the most useful for a
self-hosted Armbian build farm are **WebDAV** (lightweight nginx) and
**S3-compatible** (Garage / MinIO / Cloudflare R2 / AWS S3). Set the
relevant `SCCACHE_*` env vars on the build host — see
`extensions/sccache/sccache.sh` header for the full list.

## WebDAV server (nginx)

sccache speaks the full WebDAV verb set, including `PROPFIND` on the
cache root at startup. The stock `ngx_http_dav_module` ships only
`PUT/DELETE/MKCOL/COPY/MOVE` — without `ngx_http_dav_ext_module`
(PROPFIND/OPTIONS) sccache silently marks every PUT as a write error and
the cache stays empty. This is the single most common misconfiguration;
verify with `tail -f /var/log/nginx/access.log` and check for `PROPFIND
… 405`.

1. Install nginx with full WebDAV support:

   ```bash
   apt install nginx libnginx-mod-http-dav-ext avahi-daemon avahi-utils
   ```

   The `libnginx-mod-http-dav-ext` package is in Ubuntu universe /
   Debian main and loads automatically — no module enable step needed.

2. Copy `misc/nginx/sccache-webdav.conf` to
   `/etc/nginx/sites-available/sccache-webdav`, then enable and prepare
   storage:

   ```bash
   cp misc/nginx/sccache-webdav.conf /etc/nginx/sites-available/sccache-webdav
   ln -s /etc/nginx/sites-available/sccache-webdav /etc/nginx/sites-enabled/
   mkdir -p /var/cache/sccache-webdav/sccache
   chown -R www-data:www-data /var/cache/sccache-webdav
   systemctl reload nginx
   ```

3. Verify both directions:

   ```bash
   # PUT (write)
   curl -X PUT --data-binary @/etc/hostname http://localhost:8089/sccache/test
   # GET (read)
   curl http://localhost:8089/sccache/test
   # PROPFIND — must NOT return 405
   curl -X PROPFIND -H 'Depth: 0' http://localhost:8089/sccache/
   ```

   **WARNING:** The sample nginx site listens on plain HTTP and has no
   authentication. Use ONLY in a fully trusted private network. For
   auth, add `auth_basic` directives. For confidentiality, front nginx
   with a TLS-terminating reverse proxy and point sccache at the
   resulting `https://...` endpoint (sccache's WebDAV client accepts
   both `http://` and `https://`).

4. Point the build host at the endpoint:

   ```bash
   ./compile.sh ENABLE_EXTENSIONS=sccache \
                SCCACHE_WEBDAV_ENDPOINT="http://<server>:8089/sccache/" \
                BOARD=... BRANCH=... RELEASE=...
   ```

### Sharing a WebDAV location with ccache-remote

If the same nginx box already serves `ccache` over WebDAV, sccache can
share the location URL — they hash differently and won't collide. Just
make sure the location's `dav_methods` line includes `MKCOL COPY MOVE`
and that `dav_ext_methods PROPFIND OPTIONS` is set; the older
ccache-only config did not need either.

## S3-compatible server (Garage / MinIO / R2)

`sccache` speaks the AWS S3 protocol. Any S3-compatible store works
identically — just point `SCCACHE_ENDPOINT` at it. Self-hosted Garage
is a good fit (single-node, low-RAM, Rust); MinIO is heavier but better
known.

```bash
./compile.sh ENABLE_EXTENSIONS=sccache \
             SCCACHE_BUCKET="sccache" \
             SCCACHE_ENDPOINT="http://<server>:3900" \
             SCCACHE_REGION="garage" \
             AWS_ACCESS_KEY_ID="GK..." \
             AWS_SECRET_ACCESS_KEY="..." \
             BOARD=... BRANCH=... RELEASE=...
```

The scheme in `SCCACHE_ENDPOINT` (`http://` or `https://`) determines
whether TLS is used — `SCCACHE_S3_USE_SSL` is only needed if you set
the endpoint without a scheme (e.g. `SCCACHE_ENDPOINT=server:3900`).
For Cloudflare R2 set `SCCACHE_REGION=auto` and an R2 access key pair;
for AWS S3 set the real region and use IAM credentials.

`SCCACHE_S3_KEY_PREFIX="armbian/"` namespaces objects when sharing a
bucket with other projects.

## Redis-compatible server (KvRocks / Tendis / Dragonfly / Redis)

`sccache` speaks the RESP wire protocol. Plain Redis works but is
in-memory only; for a compile cache (mostly write-once, terabyte-scale
key space) prefer a **disk-resident RESP** store so the working set
isn't capped by RAM:

- **Apache KvRocks** (Apache 2.0, RocksDB backend) — the canonical fit.
  No official .deb; deploy via `docker run apache/kvrocks:<ver>` under
  a systemd wrapper or build from source.
- **Tendis** (Tencent, BSD-3, RocksDB) — production-tested at Tencent,
  smaller external community.
- **Dragonfly** (BSL/AGPL) — RAM-first with optional SSD tiered
  storage; ships .deb on GitHub releases but isn't truly disk-resident
  by default.

Point sccache at the server:

```bash
./compile.sh ENABLE_EXTENSIONS=sccache \
             SCCACHE_REDIS="redis://:<password>@<server>:6666" \
             BOARD=... BRANCH=... RELEASE=...
```

URL form is `redis://[username:password@]host[:port][/db]`. For
unauthenticated LAN deployments drop the credentials prefix:
`SCCACHE_REDIS="redis://<server>:6666"`. Alternatively split the
password out to keep it off the command line and out of the URL:

```bash
SCCACHE_REDIS="redis://<server>:6666" \
SCCACHE_REDIS_PASSWORD="<password>" \
ENABLE_EXTENSIONS=sccache ./compile.sh BOARD=...
```

`SCCACHE_REDIS_KEY_PREFIX="armbian/"` namespaces keys when sharing a
KvRocks instance with other tools. `SCCACHE_REDIS_TTL=<seconds>` adds
expiry on writes (useful for capping disk growth without a separate
eviction job — KvRocks honours TTL via RocksDB compaction).

**KvRocks quirks worth knowing:**
- RocksDB sizes in `kvrocks.conf` are **MB, not bytes**
  (`rocksdb.block_cache_size 256` = 256 MiB). Bytes values fail with
  `out of numeric range`.
- `DBSIZE` returns `0` until the first lazy scan; use `KEYS '*'` to
  see what was actually written.

## GitHub Actions cache (CI runners)

`mozilla-actions/sccache-action` in the workflow exports
`ACTIONS_CACHE_URL` and `ACTIONS_RUNTIME_TOKEN`; setting
`SCCACHE_GHA_ENABLED=on` in the same job makes sccache route through
the per-repo GHA cache. The extension passes these through verbatim —
no Armbian-side config needed beyond `ENABLE_EXTENSIONS=sccache`.

Mind GitHub's 10 GiB free per-repo cap and the metered billing for
overage after late 2025.

## DNS-SD discovery

Unlike `ccache-remote`, sccache (as of v0.15) has no built-in
auto-discovery for its WebDAV / S3 / Redis endpoints. If you want to
advertise yours over Avahi anyway (so other tools can find it), `cp` an
appropriate `.service` file from the ccache-remote extension's `misc/`
tree and rename the service type to `_sccache._tcp`. The Armbian
sccache extension does not consume those announcements yet — that's a
queued follow-up.

## Verifying the cache is actually used

After a build, `sccache --show-stats` (set `DEBUG=yes` or
`SHOW_COMPILE_CACHE=yes` to dump it automatically) tells you whether
the remote backend works:

- `Cache write errors: 0` → PUTs went through.
- `Cache write errors: <N>` while writes are expected → server
  rejected them. With nginx + WebDAV the usual cause is missing
  PROPFIND support; see step 1 above.
- `Cache hits / Cache misses` ratio rises on subsequent runs once the
  cache is warm.
