# syntax=docker/dockerfile:1.7
# =============================================================================
# LabVIEW CI Linux Beta image
# =============================================================================
# Isolated Linux worker lane for proving VIPM/VIPC support without changing the
# stable Linux container path used by existing Linux actions.
# =============================================================================

ARG NIPM_FEED_URL=https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2026/26.1/released
ARG VIA_SUPPORT_PACKAGE=ni-vialin-labview-support
ARG VIPM_PACKAGE=ni-vipm

FROM nationalinstruments/labview:latest-linux

ARG NIPM_FEED_URL
ARG VIA_SUPPORT_PACKAGE
ARG VIPM_PACKAGE
ARG CI_WORKER_VERSION=dev
ARG LABVIEW_VERSION=2026

COPY .github/labview/vipm/install-vipc-linux.sh /opt/lvci/vipm/install-vipc-linux.sh
COPY .github/labview/vipm-linux/ /opt/lvci/vipc/

RUN set -eux; \
    chmod +x /opt/lvci/vipm/install-vipc-linux.sh; \
    echo "Adding nipkg feed: ${NIPM_FEED_URL}"; \
    nipkg feed-add --name=ni-labview-ci-beta "${NIPM_FEED_URL}" || true; \
    nipkg update; \
    echo "Installing Linux worker packages: ${VIA_SUPPORT_PACKAGE} ${VIPM_PACKAGE}"; \
    nipkg install --accept-eulas --no-progress "${VIA_SUPPORT_PACKAGE}"; \
    nipkg install --accept-eulas --no-progress "${VIPM_PACKAGE}"

RUN --mount=type=secret,id=vipm_serial,required=false \
    --mount=type=secret,id=vipm_full_name,required=false \
    --mount=type=secret,id=vipm_email,required=false \
    set -eux; \
    if [ -f /run/secrets/vipm_serial ]; then export VIPM_SERIAL_NUMBER="$(cat /run/secrets/vipm_serial)"; fi; \
    if [ -f /run/secrets/vipm_full_name ]; then export VIPM_FULL_NAME="$(cat /run/secrets/vipm_full_name)"; fi; \
    if [ -f /run/secrets/vipm_email ]; then export VIPM_EMAIL="$(cat /run/secrets/vipm_email)"; fi; \
    export VIPC_DIR=/opt/lvci/vipc; \
    export LABVIEW_VERSION="${LABVIEW_VERSION}"; \
    /opt/lvci/vipm/install-vipc-linux.sh

ENV CI_WORKER_VERSION=${CI_WORKER_VERSION}
LABEL com.cotc.ci-worker.version=${CI_WORKER_VERSION} \
      com.cotc.ci-worker.platform=linux-beta
