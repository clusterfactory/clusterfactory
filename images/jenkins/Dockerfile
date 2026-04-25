# Jenkins image with pre-installed plugins for airgap deployment
# Source of truth: factory/components/jenkins.py JENKINS_VERSION and PLUGINS

FROM jenkins/jenkins:2.541.3-jdk21

USER root

# Install plugin dependencies if needed
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    && rm -rf /var/lib/apt/lists/*

USER jenkins

# Install plugins
# Latest versions - will auto-resolve dependencies
RUN jenkins-plugin-cli --plugins \
    plain-credentials \
    credentials \
    git \
    workflow-aggregator \
    workflow-job

# Skip the setup wizard
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"
