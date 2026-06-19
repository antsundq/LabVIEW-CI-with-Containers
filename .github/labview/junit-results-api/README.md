# NI JUnit Results API (vendored)

NI's **JUnit Results API** (`JUnit API.lvlib`) builds a JUnit-compatible XML tree
(`<testsuites>`/`<testsuite>`/`<testcase>`) from LabVIEW. The **UTF Junit Report**
library (`../utf-junit`) calls into it to turn Unit Test Framework results into the
JUnit report the CI pipeline consumes.

## Provenance

Vendored verbatim from NI's open-source repository:

- Source: <https://github.com/NISystemsEngineering/LV-JUnit> (`Source/`, tag `1.0.1`)
- License: **Apache-2.0** (see `LICENSE`)
- Author: NI Systems Engineering

## Why it is vendored

LabVIEW's `RunUnitTests` LabVIEWCLI operation statically links
`utf junit report.lvlib:create junit report.vi`, which in turn links the members of
`JUnit API.lvlib` at the symbolic path `<vilib>:\ni\JUnit Results API\`. That library
historically shipped in LabVIEW's `vi.lib`, but it is **not** present in the
LabVIEW 2026 Windows worker image (neither the base install nor the UTF add-on places
it there). Without it, the `RunUnitTests` operation class loads broken and the CLI
fails with `-350053` ("missing or bad files... required modules or toolkits").

`.github/labview/run-unit-tests.ps1` mirrors this folder into
`<LabVIEW 2026>\vi.lib\ni\JUnit Results API\` (preserving the `Controls\` subfolder so
the library's `../Controls/*.ctl` member URLs resolve) before invoking the operation;
`.github/docker/labview-ci.Dockerfile` bakes the same copy into the image.

## Version pairing

The companion `create junit report.vi` in `../utf-junit` is pinned to the
`ced05a3a` ("Update for release") revision of `LabVIEW-DCAF/UTF-Test`, which links the
**singular** `Test Suite Attribute Values.ctl` that this published JUnit API provides.
(The later DCAF master revision `f16a6f9` relinked to an unpublished **plural**
`Test Suites Attribute Values.ctl` that no released JUnit API ships, so it cannot load
against this library.)

## Members (`JUnit API.lvlib`)

`Create JUnit Root.vi`, `Add Test Suite.vi`, `Add Test Case.vi`, `Add Failure.vi`,
`Add Error.vi`, `Add Skipped.vi`, `Save JUnit Report.vi`, `Find & Convert Attributes.vi`,
and `Controls\{Outcome Attributes, Test Case Attributes, Test Suite Attribute Values}.ctl`.
`JUnit Example.vi` is the upstream example and is not part of the report path.
