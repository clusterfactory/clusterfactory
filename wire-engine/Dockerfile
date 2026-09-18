# Wire-engine image (ADR 0002): upstream python:slim + one stdlib-only script.
# No pip, no build step, nothing to mirror. Built into the local Docker daemon
# at `zarf package create` time (make wire-engine-image), never pushed.
# renovate: datasource=docker depName=python
FROM docker.io/library/python:3.12-slim@sha256:2fe5997d249a808b8eeea52c58a1dbffbba28754dc11699ef5c029f2d818ce79
COPY wire.py /app/wire.py
USER 65532:65532
ENTRYPOINT ["python3", "-u", "/app/wire.py"]
