# Wire engine runtime image
FROM python:3.12-slim

# Install tini for proper signal handling
RUN apt-get update \
    && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source
COPY src/clusterfactory_engine/ ./clusterfactory_engine/

# Run as non-root
USER 10001

# Use tini as PID 1 for proper signal handling
ENTRYPOINT ["tini", "--", "python", "-m", "clusterfactory_engine"]
