# Kill Bill for Railway.
#
# The published image is fully env-var configurable, so this layer only adds the
# three things Railway needs and the image cannot express:
#
#   1. a health-check path Railway accepts. Kill Bill's real probe lives at
#      /1.0/healthcheck, and Railway's healthcheckPath rejects "."; Tomcat's
#      RewriteValve (already enabled in the image's server.xml) maps /healthz
#      onto it, so the deploy is gated on a check that touches the database.
#   2. a boot-time bootstrap: seed the OSGI bundle directory onto the volume,
#      size the JVM heap from the cgroup, bind the JDWP and JMX ports to
#      loopback, and create the default tenant through Kill Bill's own API.
#   3. a root entrypoint that chowns the volume and drops back to `tomcat`.
#
# It also applies the two Tomcat fixes in patch-tomcat.py, which Kaui shares.
FROM killbill/killbill:0.24.21

USER root

RUN mkdir -p /var/lib/tomcat/conf/Catalina/localhost
COPY rewrite.config /var/lib/tomcat/conf/Catalina/localhost/rewrite.config
COPY railway-entrypoint.sh /var/lib/killbill/railway-entrypoint.sh
COPY patch-tomcat.py /usr/local/bin/patch-tomcat.py

# Trust Railway's edge so the audit trail records the real client address, and
# turn on Tomcat's own security-header filter.
RUN python3 /usr/local/bin/patch-tomcat.py /var/lib/tomcat/conf

RUN chmod 0644 /var/lib/tomcat/conf/Catalina/localhost/rewrite.config \
 && chmod 0755 /var/lib/killbill/railway-entrypoint.sh \
 && chown -R tomcat:tomcat /var/lib/tomcat/conf \
 && bash -n /var/lib/killbill/railway-entrypoint.sh

# Stays root so the entrypoint can chown the mounted volume; it drops to
# `tomcat` with setpriv before exec'ing the image's own launcher.
CMD ["/var/lib/killbill/railway-entrypoint.sh"]
