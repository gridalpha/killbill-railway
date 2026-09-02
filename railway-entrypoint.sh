#!/bin/bash
#
# Railway entrypoint for Kill Bill. Runs as root, prepares the volume, then
# drops to the image's own `tomcat` user and execs the image's launcher.
set -euo pipefail

KB_HOME=/var/lib/killbill
PLUGIN_ROOT="${KILLBILL_PLUGIN_ROOT:-/var/lib/killbill/plugins}"
BAKED_BUNDLES="$KB_HOME/bundles"

log() { echo "[railway-entrypoint] $*"; }

# ---------------------------------------------------------------------------
# 1. Cross-service hosts.
#
# ${{svc.VAR}} references render empty until the referenced service owns a
# deployment, and in a template every service deploys for the first time at
# once. Repair each URL on its *shape* so a first deploy still lands on the
# deterministic private hostname.
# ---------------------------------------------------------------------------
case "${KILLBILL_DAO_URL:-}" in
  ''|'jdbc:mysql://:'*|'jdbc:mysql:///'*)
    KILLBILL_DAO_URL="jdbc:mysql://${KILLBILL_DB_HOST:-mariadb.railway.internal}:3306/killbill"
    log "KILLBILL_DAO_URL was unresolved; defaulted to the private MariaDB host"
    ;;
esac
export KILLBILL_DAO_URL

if [ "${KILLBILL_CACHE_CONFIG_REDIS:-false}" = "true" ]; then
  case "${KILLBILL_CACHE_CONFIG_REDIS_URL:-}" in
    ''|'redis://:'*)
      KILLBILL_CACHE_CONFIG_REDIS_URL="redis://${KILLBILL_REDIS_HOST:-redis.railway.internal}:6379"
      log "KILLBILL_CACHE_CONFIG_REDIS_URL was unresolved; defaulted to the private Redis host"
      ;;
  esac
  export KILLBILL_CACHE_CONFIG_REDIS_URL

  # Two of Kill Bill 0.24's caches hold objects that do not survive a round trip
  # through Redis: a VersionedCatalog comes back with its injected priceOverride
  # null, so the very next findPlan() throws NullPointerException. The damage is
  # invisible — the deployment stays green, accounts and the catalog are created
  # normally, and only subscription creation fails, which then parks the account.
  # Measured on 0.24.21: with these two caches excluded the identical call
  # returns 201 and invoices are generated, and Redis still backs the other
  # thirteen caches. The catalog is re-read from tenant_kvs per access instead.
  export KB_org_killbill_cache_disabled="${KB_org_killbill_cache_disabled:-tenant-catalog,overridden-plan}"
fi

# ---------------------------------------------------------------------------
# 2. Persistent OSGI bundle directory.
#
# Kill Bill installs payment plugins into its bundle directory at runtime (the
# KPM plugin, or `kpm install`), so that directory is mutable state and belongs
# on the volume. The image ships the OSGI platform jars there, and a mount
# hides baked files, so seed the volume from the image on every boot instead of
# relocating. The bundle dir sits one level below the mount root, because every
# Railway volume ships a lost+found the OSGI loader would try to read.
# ---------------------------------------------------------------------------
BUNDLES="$PLUGIN_ROOT/bundles"
mkdir -p "$BUNDLES"
if [ -d "$BAKED_BUNDLES" ]; then
  # No -n: the image's own tree is authoritative and must be refreshed on a
  # version bump, while anything an operator installed lives under paths the
  # baked tree does not contain and is therefore left alone.
  cp -a "$BAKED_BUNDLES/." "$BUNDLES/" 2>/dev/null || true
fi
log "bundle directory $BUNDLES holds: $(ls -A "$BUNDLES" | tr '\n' ' ')"
chown -R tomcat:tomcat "$PLUGIN_ROOT"
export KB_org_killbill_osgi_bundle_install_dir="$BUNDLES"
export KB_org_killbill_billing_plugin_kpm_bundlesPath="$BUNDLES"

# ---------------------------------------------------------------------------
# 3. JVM sizing.
#
# The image's setenv.sh pins -Xmx to a fixed 2G, which overrides the JVM's own
# (correct) cgroup detection, so derive the heap from the container's real
# limit and let a Railway resize retune it.
# ---------------------------------------------------------------------------
if [ -z "${TOMCAT_JAVA_XMX:-}" ]; then
  mem_max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
  if [ "$mem_max" != "max" ] && [ "$mem_max" -gt 0 ] 2>/dev/null; then
    export TOMCAT_JAVA_XMX="$(( mem_max / 1048576 * 60 / 100 ))m"
  else
    export TOMCAT_JAVA_XMX=2G
  fi
  log "heap ceiling TOMCAT_JAVA_XMX=$TOMCAT_JAVA_XMX"
fi

# ---------------------------------------------------------------------------
# 4. Close the two debug surfaces the upstream Tomcat config opens.
#
# killbill-cloud's setenv.sh always passes -Xrunjdwp with server=y and an
# unauthenticated -Dcom.sun.management.jmxremote, both of which would otherwise
# listen on every interface and be reachable from any peer in the project.
# JDWP takes host:port in its address, and JMX honours jmxremote.host, so both
# can be pinned to loopback without patching the image.
# ---------------------------------------------------------------------------
export JVM_JDWP_PORT="${JVM_JDWP_PORT:-127.0.0.1:12345}"
export JAVA_OPTS="${JAVA_OPTS:-} -Dcom.sun.management.jmxremote.host=127.0.0.1 -Djava.rmi.server.hostname=127.0.0.1"

# ---------------------------------------------------------------------------
# 5. Create the default tenant once the server answers.
#
# A tenant is what an API key and secret address, and nothing in Kill Bill's
# configuration creates one, so without this a fresh deployment has no tenant
# for Kaui or the REST API to talk to. POST /1.0/kb/tenants is create-only and
# answers 409 when the tenant already exists, so this never overwrites anything
# an operator has since changed. Runs behind the exec so the health check is
# not held open waiting for it.
# ---------------------------------------------------------------------------
if [ -n "${KILLBILL_API_KEY:-}" ] && [ -n "${KILLBILL_API_SECRET:-}" ]; then
  (
    for _ in $(seq 1 120); do
      if [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${TOMCAT_PORT:-8080}/1.0/healthcheck" || true)" = "200" ]; then
        break
      fi
      sleep 5
    done
    code=$(curl -s -o /dev/null -w '%{http_code}' \
      -X POST "http://127.0.0.1:${TOMCAT_PORT:-8080}/1.0/kb/tenants" \
      -u "admin:${KB_ADMIN_PASSWORD:-password}" \
      -H 'Content-Type: application/json' \
      -H 'X-Killbill-CreatedBy: railway-bootstrap' \
      -d "{\"apiKey\":\"${KILLBILL_API_KEY}\",\"apiSecret\":\"${KILLBILL_API_SECRET}\"}" || true)
    case "$code" in
      201) log "default tenant created" ;;
      409) log "default tenant already exists" ;;
      *)   log "default tenant bootstrap returned HTTP $code" ;;
    esac
  ) &
fi

# ---------------------------------------------------------------------------
# 6. Hand over to the image's own launcher, as the image's own user.
# ---------------------------------------------------------------------------
export HOME=/var/lib/tomcat
log "starting Kill Bill ${KILLBILL_VERSION:-} as tomcat"
exec setpriv --reuid=tomcat --regid=tomcat --init-groups "$KB_HOME/killbill.sh"
