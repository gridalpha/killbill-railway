#!/usr/bin/env python3
"""Make Tomcat trust Railway's edge as a reverse proxy.

killbill-cloud's server.xml declares RemoteIpValve with no `internalProxies`, so
the valve falls back to its RFC1918 default, which never matches Railway: every
request is seen as plain HTTP and the recorded client is the proxy rather than
the caller. Railway reaches containers from 100.64.0.0/10 and its own edge
appears in X-Forwarded-For inside 152.233.0.0/17, so trusting both makes the
valve walk past them onto the real client. Forged entries are not a risk here —
Railway's edge overwrites any client-supplied X-Forwarded-For before the
container sees it.

Measured on Kaui after this patch: the Rails request log records the caller's
public address, where it previously recorded 100.64.0.x.

Note that Tomcat's HttpHeaderSecurityFilter is deliberately *not* enabled here.
Adding it to $CATALINA_BASE/conf/web.xml has no effect on either image — the
headers a patched build emits are identical to an unpatched one — so there is no
supported way to add HSTS without repackaging the WAR.
"""
import sys

CONF_DIR = sys.argv[1] if len(sys.argv) > 1 else "/var/lib/tomcat/conf"

INTERNAL_PROXIES = (
    r"100\.\d{1,3}\.\d{1,3}\.\d{1,3}"
    r"|152\.233\.\d{1,3}\.\d{1,3}"
    r"|127\.\d{1,3}\.\d{1,3}\.\d{1,3}"
    r"|::1|0:0:0:0:0:0:0:1"
    r"|fd[0-9a-fA-F]{2}:.*"
)

VALVE = 'className="org.apache.catalina.valves.RemoteIpValve"'

path = f"{CONF_DIR}/server.xml"
with open(path) as fh:
    body = fh.read()

if "internalProxies=" in body:
    print(f"{path}: already patched")
elif VALVE not in body:
    raise SystemExit(f"{path}: RemoteIpValve not found; refusing to guess")
else:
    with open(path, "w") as fh:
        fh.write(body.replace(VALVE, f'{VALVE} internalProxies="{INTERNAL_PROXIES}"', 1))
    print(f"{path}: RemoteIpValve now trusts Railway's edge")
