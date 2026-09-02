# Kaui — Kill Bill's back-office admin UI — for Railway.
#
# Built from the repository root, so this file is selected with
# RAILWAY_DOCKERFILE_PATH=kaui/Dockerfile rather than a root directory.
#
# The published image needs no code changes; this layer only applies the proxy
# fix described in patch-tomcat.py, which matters more here than on the Kill Bill
# service because Kaui is a browser-facing console whose Rails request log is the
# record of who did what.
FROM killbill/kaui:4.0.25

USER root

COPY patch-tomcat.py /usr/local/bin/patch-tomcat.py
RUN python3 /usr/local/bin/patch-tomcat.py /var/lib/tomcat/conf

USER tomcat
