# Wire-engine image (ADR 0002): upstream python:slim + one stdlib-only script.
# No pip, no build step, nothing to mirror. Built at `zarf package create` time (make
# wire-engine-image) and pushed only to a throwaway registry on the build machine.
# renovate: datasource=docker depName=python
FROM docker.io/library/python:3.12-slim@sha256:44ff437bba879d4941b710a369a8f19266aea34b29002807f0c487fabc9eec9b
COPY wire.py /app/wire.py
USER 65532:65532
ENTRYPOINT ["python3", "-u", "/app/wire.py"]
