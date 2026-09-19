# Demo image built by the clusterfactory pipeline. The base comes from the
# Nexus docker-hosted registry, pre-seeded from the package - never from
# Docker Hub.
FROM nexus.clusterfactory.svc.cluster.local:5000/alpine:3.22
RUN echo "hello from clusterfactory" > /hello.txt
CMD ["cat", "/hello.txt"]
