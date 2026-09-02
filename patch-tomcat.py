#!/usr/bin/env python3
"""Two edits both killbill-cloud Tomcat images need on Railway.

1. RemoteIpValve is configured with no `internalProxies`, so its default list
   (RFC1918 only) never matches Railway's edge: `x-forwarded-proto` is ignored,
   every request looks like plain HTTP, and the recorded client address is the
   proxy. Railway reaches containers from 100.64.0.0/10 and its own edge appears
   in X-Forwarded-For inside 152.233.0.0/17, so trusting both lands the valve on
   the real client. Forged entries are not a risk here: Railway's edge overwrites
   any client-supplied X-Forwarded-For before the container sees it.

2. Tomcat ships HttpHeaderSecurityFilter commented out. With the valve fixed
   above, requests are correctly seen as secure, so the filter can emit HSTS —
   which is what keeps a session cookie off plain HTTP, since the Rails session
   store in Kaui hardcodes its options and offers no `secure` switch.
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

SECURITY_FILTER = """
  <filter>
    <filter-name>httpHeaderSecurity</filter-name>
    <filter-class>org.apache.catalina.filters.HttpHeaderSecurityFilter</filter-class>
    <init-param>
      <param-name>hstsEnabled</param-name>
      <param-value>true</param-value>
    </init-param>
    <init-param>
      <param-name>hstsMaxAgeSeconds</param-name>
      <param-value>31536000</param-value>
    </init-param>
    <init-param>
      <param-name>hstsIncludeSubDomains</param-name>
      <param-value>false</param-value>
    </init-param>
    <init-param>
      <param-name>antiClickJackingOption</param-name>
      <param-value>DENY</param-value>
    </init-param>
    <init-param>
      <param-name>blockContentTypeSniffingEnabled</param-name>
      <param-value>true</param-value>
    </init-param>
    <async-supported>true</async-supported>
  </filter>
  <filter-mapping>
    <filter-name>httpHeaderSecurity</filter-name>
    <url-pattern>/*</url-pattern>
    <dispatcher>REQUEST</dispatcher>
  </filter-mapping>
</web-app>"""


def patch(path, old, new, already):
    with open(path) as fh:
        body = fh.read()
    if already in body:
        print(f"{path}: already patched")
        return
    if old not in body:
        raise SystemExit(f"{path}: expected marker not found: {old!r}")
    with open(path, "w") as fh:
        fh.write(body.replace(old, new, 1))
    print(f"{path}: patched")


patch(
    f"{CONF_DIR}/server.xml",
    VALVE,
    f'{VALVE} internalProxies="{INTERNAL_PROXIES}"',
    "internalProxies=",
)
patch(
    f"{CONF_DIR}/web.xml",
    "</web-app>",
    SECURITY_FILTER,
    "<filter-name>httpHeaderSecurity</filter-name>",
)
