# killbill-railway

Deployment files for running [Kill Bill](https://killbill.io) — the open-source
subscription billing and payments platform — on [Railway](https://railway.com).

The published `killbill/killbill` image is already configurable entirely through
environment variables, so this repository is a single thin layer on top of it.
It adds only what a Railway deployment needs and the image cannot express:

| File | Why it exists |
|---|---|
| `Dockerfile` | `FROM killbill/killbill:0.24.21`, plus the two files below |
| `rewrite.config` | Maps `/healthz` onto Kill Bill's `/1.0/healthcheck`, because Railway's health-check path may not contain a `.` |
| `railway-entrypoint.sh` | Seeds the OSGI bundle directory onto the volume, sizes the JVM heap from the cgroup, binds the JDWP and JMX ports to loopback, creates the default tenant, then drops to the image's `tomcat` user |
| `patch-tomcat.py` | Makes Tomcat trust Railway's edge as a proxy, so logs record the real client. Shared by both images |
| `kaui/Dockerfile` | `FROM killbill/kaui:4.0.25` plus `patch-tomcat.py`. Selected with `RAILWAY_DOCKERFILE_PATH=kaui/Dockerfile`; the build context is the repository root |

MariaDB and Redis run from their published images and need no files here.

## Configuration

Every variable has a working default; see the deployment's overview for the full
list. The ones worth knowing:

| Variable | Purpose |
|---|---|
| `KB_ADMIN_PASSWORD` | password for the `admin` account used by Kaui and the REST API |
| `KILLBILL_API_KEY` / `KILLBILL_API_SECRET` | credentials of the tenant created on first boot |
| `KILLBILL_DAO_URL` / `KILLBILL_DAO_USER` / `KILLBILL_DAO_PASSWORD` | MariaDB connection |
| `KILLBILL_CACHE_CONFIG_REDIS` / `..._REDIS_URL` / `..._REDIS_PASSWORD` | Redis-backed distributed cache |
| `KB_org_killbill_cache_disabled` | caches kept out of Redis; defaults to the two that cannot be serialized |
| `KB_org_killbill_server_baseUrl` | the deployment's own public URL |
