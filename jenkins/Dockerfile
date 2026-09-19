# Data-only image carrying the resolved Jenkins plugin closure (ADR 0006).
# Built at `zarf package create` time from jenkins/plugins/ (make plugins);
# pushed only to a throwaway registry on the build machine (make
# local-registry) so Zarf can pull it into the package. Not an application image: busybox only exists so
# the init container can `cp`.
# renovate: datasource=docker depName=busybox
FROM docker.io/library/busybox:1.37.0@sha256:7a3ebe5bfd1a4a19797d20b0c0bb39d44393e9a03fd852c0865b0f540d868df0
COPY plugins/ /plugins/
COPY plugins.lock /plugins.lock
USER 1000:1000
