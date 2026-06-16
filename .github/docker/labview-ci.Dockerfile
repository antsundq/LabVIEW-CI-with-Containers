# escape=`
# =============================================================================
# LabVIEW CI image for challenge-of-champions
# =============================================================================
# Extends the official NI LabVIEW Windows container (LabVIEW 2026) with the VI
# Analyzer support package (ni-viawin-labview-support), which provides the full
# default VI Analyzer test set (~90 tests). Without this package the analyzer
# reports "0 tests run".
#
# Project VIPM dependencies (OpenG — used by only a handful of VIs) are
# intentionally NOT baked in: every project VI already loads on the bare NI base
# image (the snapshot pipeline renders all 222 VIs there), so the analyzer can
# load and test them without applying the .vipc, keeping the build fast and
# reliable.
#
# Third-party add-ons that ARE wanted in the image (e.g. Antidoc — Wovalab's
# LabVIEW code-documentation generator, package wovalab_lib_antidoc_cli) are
# installed through the VIPM hook below: stage an Antidoc .vipc under
# .github/labview/vipm/ and it is applied at image-build time. VIPM is a
# Windows-only application, so Antidoc-based documentation CI runs on this
# Windows image, not the Linux one.
# =============================================================================
FROM nationalinstruments/labview:latest-windows

SHELL ["powershell", "-NoLogo", "-NoProfile", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# Feed/package values are ARGs so they are explicit and easy to revise per LabVIEW major version.
ARG NIPM_FEED_NAME=LV2026
ARG NIPM_FEED_URL=https://download.ni.com/support/nipkg/products/ni-l/ni-labview-2026/26.1/released
ARG VIA_SUPPORT_PACKAGE=ni-viawin-labview-support

# Worker version: a short content hash of the build inputs (this Dockerfile +
# install-vipc.ps1 + any applied *.vipc), computed by the build workflow and
# passed in here. It is stamped into the image (env + label) so any CI job can
# read back exactly which worker it pulled and link to that worker's manifest on
# the dashboard. Defaults to 'dev' for local/ad-hoc builds.
ARG CI_WORKER_VERSION=dev

# VIPC automation assets. install-vipc.ps1 plus any *.vipc are staged here; the
# build workflow also copies repo-root *.vipc (e.g. "COTC Dependencies.vipc")
# into .github/labview/vipm/ before the build, so "a repo that features a .vipc"
# gets that configuration baked into the Windows worker automatically. With no
# .vipc staged the VIPM hook below is a no-op.
COPY .github/labview/vipm/ C:/vipm/

# Install the VI Analyzer support package and report whether its default TEST
# SUITE is on disk. IMPORTANT FINDING: NI's prebuilt nationalinstruments/labview
# base image ships the VI Analyzer ENGINE but NOT the ~90 default test libraries
# (project\_VI Analyzer\_tests\**\*.llb). The ni-viawin-labview-support package is
# registered as installed; reinstalling it from the feed downloads ~7 MB but lays
# down 0 test files ("0 bytes of additional disk space will be used"), so the tests
# are not obtainable in-container this way — they were stripped from the slim base
# image and live in the full LabVIEW core install. The analyzer therefore loads but
# runs 0 tests until the worker is built with the test suite present (tracked
# separately). This step is NON-FATAL: mass compile, VIDiff and snapshots work on
# this worker regardless, so a missing analyzer suite must not block the whole
# image. It logs the on-disk test count so the gap is visible in the build.
RUN $ErrorActionPreference = 'Continue'; `
    if (-not (Get-Command nipkg -ErrorAction SilentlyContinue)) { throw 'nipkg was not found in the LabVIEW base image.' }; `
    nipkg feed-add --name=$env:NIPM_FEED_NAME $env:NIPM_FEED_URL 2>&1 | Out-Host; `
    nipkg update 2>&1 | Out-Host; `
    nipkg install --accept-eulas -y $env:VIA_SUPPORT_PACKAGE 2>&1 | Out-Host; `
    $lvDir = (Get-ChildItem 'C:\Program Files\National Instruments' -Directory -Filter 'LabVIEW *' | Sort-Object Name -Descending | Select-Object -First 1).FullName; `
    $testsDir = Join-Path $lvDir 'project\_VI Analyzer\_tests'; `
    $count = if (Test-Path $testsDir) { @(Get-ChildItem -LiteralPath $testsDir -Recurse -Filter '*.llb' -ErrorAction SilentlyContinue).Count } else { 0 }; `
    if ($count -lt 1) { `
      Write-Host ('WARNING: VI Analyzer default test suite is NOT present under {0} (0 test libraries). The analyzer engine is installed but the prebuilt base image does not ship the test VIs, so VI Analyzer runs will report 0 tests. Mass compile / VIDiff / snapshots are unaffected.' -f $testsDir); `
    } else { `
      Write-Host ('VI Analyzer test suite present: {0} test libraries under {1}.' -f $count, $testsDir); `
    }; `
    if (Test-Path 'C:\ProgramData\National Instruments\NI Package Manager\cache') { `
      Remove-Item -Path 'C:\ProgramData\National Instruments\NI Package Manager\cache\*' -Force -Recurse -ErrorAction SilentlyContinue `
    }

# Optional VIPC support hook. If .vipc files exist, an installer script must be
# present so dependencies are handled explicitly.
RUN $vipcFiles = Get-ChildItem -Path 'C:\vipm' -Filter '*.vipc' -Recurse -ErrorAction SilentlyContinue; `
    if ($vipcFiles -and $vipcFiles.Count -gt 0) { `
      if (Test-Path 'C:\vipm\install-vipc.ps1') { `
        Write-Host 'VIPC files detected. Running C:\vipm\install-vipc.ps1 ...'; `
        powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File 'C:\vipm\install-vipc.ps1' `
      } else { `
        throw 'VIPC files were detected in C:\vipm but install-vipc.ps1 was not provided.' `
      } `
    } else { `
      Write-Host 'No VIPC dependencies were provided. Skipping VIPM install hook.' `
    }

# Stamp the worker version so any consuming CI job can read it back from the
# pulled image (docker inspect / env) and link the dashboard to this worker's
# published manifest. ENV survives into `docker run`; LABEL is queryable without
# starting a container.
ENV CI_WORKER_VERSION=${CI_WORKER_VERSION}
LABEL com.cotc.ci-worker.version=${CI_WORKER_VERSION} `
      com.cotc.ci-worker.platform=windows
