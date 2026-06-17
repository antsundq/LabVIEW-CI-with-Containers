# toimages — position-aware VI renderer (for the in-place VI Browser)

These VIs produce a **position + ownership** JSON model of a VI's block diagram.
The VI Browser's in-place renderer (`vi-render.js`) consumes that model to draw a
VI nearly identically to the LabVIEW editor: the root diagram is painted once and
every Case / Event / Stacked-Sequence structure is composited **in place** at its
real location, with a `◀ n/N ▶` selector to page through its cases (recursively
for nested structures) — instead of stacking every case in separate galleries
below the diagram.

## Provenance

Vendored from NI's `lvctl` tool (`ni/testhub` → `src/labview/lvctl/vis/toimages`).
`Convert.vi` is the entry point; it walks the block diagram with VI Server
scripting and emits the frames JSON.

```
Convert.vi                     VI Path in  ->  JSON out
SubVIs/Get VI Info.vi          top-level diagram image + per-structure frames
SubVIs/Create Frame Array.vi   captures each Case/Event/Sequence frame image
SubVIs/Get Frame-Owner Array.vi walks the Owner chain -> parent/child tree
SubVIs/Image to Info.vi        image cluster -> {Image, Position, Children}
SubVIs/{Combine Frame Data, Get Names, Compress Images, Base64 Encode}.vi
Controls/{JSON Image Data, Image Position}.ctl
```

## JSON schema (what the renderer expects)

A flat JSON **array** of frames; the tree is encoded by child-index lists and
geometry by `Position` (relative to the owning diagram):

```jsonc
[
  { "Image": "<base64 PNG>",
    "Position": { "Left": 0,  "Top": 0,  "Width": 760, "Height": 420 },
    "Children": [1, 2, 3, 4, 5] },          // the root block diagram
  { "Image": "<base64 PNG>",                 // one case of a structure
    "Position": { "Left": 60, "Top": 60, "Width": 300, "Height": 200 },
    "Children": [6, 7] }                      // nested structure inside this case
  // ...
]
```

`Image` may also be `Base64 Image`; `Children` may also be `Child Indices`.
Sibling frames that share one `Position` rectangle are the cases of a single
structure and collapse into one in-place stepper.

## How it is wired into CI

`render-snapshots.ps1` already emits the per-VI HTML snapshot. After each
successful render it ALSO emits `<blob>.json` next to `<blob>.html` — **but only
when a `PrintToImagesJson` LabVIEWCLI operation is present in this ops folder.**
The hook is a strict no-op otherwise, so the gallery is unaffected until the
operation exists. The VI Browser auto-prefers `<blob>.json` (in-place) and falls
back to `<blob>.html` (flat) when it is absent.

## How it reaches the container (no base-image change needed)

These VIs are **not baked into any container image.** Like the sibling
`PrintToSingleFileHtml` operation, they ride with the tooling repository and are
**bind-mounted** into the snapshot container at runtime (`-v <ops>:C:\ops` in
`build-snapshots.ps1`). The snapshot job runs on the **stock** NI image
(`nationalinstruments/labview:latest-windows`), not the custom CI worker image.

Consequences:

- **Clients do not add anything to their container.** When a repo updates the
  tooling (the normal What's-New → update path / `source.ref` bump), it checks out
  this folder and bind-mounts it — the renderer VIs come along automatically. No
  image rebuild, no image pull, no per-client container surgery.
- The only container-level requirement is **LabVIEW scripting**, which `Convert.vi`
  needs to traverse block-diagram objects (it walks `Owner`, iterates a structure's
  `Frames[]`, and sets `VisFrame`). Plain "print to HTML" does not need it, which is
  why the stock image does not enable it by default.

### Scripting is enabled at runtime (not via the image)

`render-snapshots.ps1` calls `Enable-LVScripting` to merge the scripting tokens
into the container's `LabVIEW.ini` (next to `LabVIEW.exe`) **before** rendering —
idempotently, preserving every other key. It runs **only** when the
`PrintToImagesJson` operation is present, so today's HTML-only pipeline is
unchanged. The token set mirrors the `LabVIEW.ini` that `lvctl` ships for this same
workload (vendored here as `LabVIEW.ini` for provenance); the load-bearing key is
`SuperSecretPrivateSpecialStuff=True`.

Because scripting is enabled at runtime, it also travels with the tooling update —
so a base-image rebuild/redistribution is **not** required to roll this out to
clients. (If you would rather bake scripting into a custom image instead, you would
have to switch the snapshot job off the stock image onto that image; the runtime
approach avoids that and keeps the snapshot container lightweight.)

## Remaining step (must be done in the LabVIEW IDE — needs Windows + LabVIEW 2026)

`Convert.vi` is a plain VI (lvctl runs it over VI Server). LabVIEWCLI has no
generic "run a VI" operation, and COM cannot drive a headless LabVIEW in the
container (proven dead three ways — see the repo memo), so the only headless path
is to wrap `Convert.vi` in a custom LabVIEWCLI operation, exactly like the sibling
`../PrintToSingleFileHtml` (itself vendored from NI's `labview-for-containers`).
This is the one step that cannot be done on macOS; everything else is wired.

The operation is binary VIs, so duplicate it **inside LabVIEW** (a raw filesystem
copy + rename breaks the compiled class links):

1. On Windows + LabVIEW 2026, open `.github/labview/PrintToSingleFileHtml/`
   `PrintToSingleFileHtml.lvclass`. Use **File ▸ Save As ▸ rename** on the class
   (and let LabVIEW save renamed copies of the member VIs) to create
   `.github/labview/PrintToImagesJson/PrintToImagesJson.lvclass`. It MUST be a
   sibling folder of `PrintToSingleFileHtml` under `.github/labview/`, because the
   hook passes `-AdditionalOperationDirectory .github\labview` (the parent) and
   LabVIEWCLI finds the op by the `PrintToImagesJson` folder name.
2. Edit the new `RunOperation.vi`. It already parses the CLI args and gives you the
   target VI path (`-VI`) and the output path (`-OutputPath`). Replace the
   "print to HTML" middle (the `Open VI` ▸ `Print to temp file` ▸ base64 chain)
   with one call to `..\toimages\Convert.vi`:
   - wire the `-VI` path string  ->  Convert.vi **`VI Path in`**
   - run it (it is already a subVI call; just wait for it to finish)
   - wire Convert.vi **`JSON out`** (string)  ->  the existing file-write that
     targets `-OutputPath` (write UTF-8, no BOM). The HTML-only helpers
     (`Print to temp file.vi`, `base64_fast_encode.vi`) can be left unused.
3. Keep the CLI surface identical (`-VI <path> -OutputPath <path> -Headless -o -c`)
   so the hook in `render-snapshots.ps1` drives it unchanged. (`Enable-LVScripting`
   already merges the scripting tokens into `LabVIEW.ini` at runtime, which
   `Convert.vi` needs to walk the diagram.)
4. Save **all** for LabVIEW 2026 and commit the `PrintToImagesJson` folder. On the
   next snapshot run, newly-rendered VIs gain a `<blob>.json` and the VI Browser
   shows them in place. To backfill already-rendered VIs, clear `by-blob/` (or run
   the snapshots workflow in `backfill` mode) so they re-render with JSON.

Tip: validate one VI locally first —
`LabVIEWCLI -OperationName PrintToImagesJson -AdditionalOperationDirectory <repo>\.github\labview -VI <some.vi> -OutputPath out.json -Headless -o -c`
then open `vi-interactive.html?frames=out.json` to confirm `vi-render.js` accepts it.
