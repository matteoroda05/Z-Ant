# CMSIS dependency fetch scripts

## Role

The CMSIS integration uses three scripts to install the upstream vendor trees
under `third_party/` in the directory layout expected by
`zantBuild/cmsis_build.zig`:

| Script | Destination | Reference variable | Archive variable |
|---|---|---|---|
| `scripts/fetch_cmsis_nn.sh` | `third_party/CMSIS-NN` | `CMSIS_NN_REF` | `CMSIS_NN_ARCHIVE` |
| `scripts/fetch_cmsis_5.sh` | `third_party/CMSIS_5` | `CMSIS5_REF` | `CMSIS5_ARCHIVE` |
| `scripts/fetch_cmsis_dsp.sh` | `third_party/CMSIS-DSP` | `CMSIS_DSP_REF` | `CMSIS_DSP_ARCHIVE` |

Each script also accepts a repository override (`CMSIS_NN_REPO`,
`CMSIS5_REPO`, or `CMSIS_DSP_REPO`).

## Recommended stable versions

Run these commands from the Z-Ant repository root:

```bash
CMSIS_NN_REF=v7.0.0 ./scripts/fetch_cmsis_nn.sh
CMSIS5_REF=5.9.0 ./scripts/fetch_cmsis_5.sh
CMSIS_DSP_REF=v1.17.0 ./scripts/fetch_cmsis_dsp.sh
```

Explicit release tags make the dependency set reproducible. Without an
override, the scripts use their upstream development defaults (`main` for
CMSIS-NN and `develop` for CMSIS_5/CMSIS-DSP), which can change over time.

When a non-empty reference variable is supplied, the corresponding script tries
only that exact reference and exits with an error if it cannot be fetched. It
does not silently replace an explicitly requested release with a development
branch. When no reference is supplied, the CMSIS_5 and CMSIS-DSP scripts may
fall back across their normal development branch names (`develop`, `main`, and
`master`).

## Git-backed mode

When no archive variable is set, a script:

1. creates `third_party/` if needed;
2. performs a shallow clone of the selected reference when the destination is
   absent;
3. performs a shallow fetch and checks out the selected reference when the
   destination already contains a checkout.

An explicit reference is strict: failure to fetch or clone it stops the script.
Branch-name fallback is used only when the corresponding reference variable was
not supplied.

Checking out a release tag can leave the dependency checkout in a detached
state. That is expected because the directory represents a pinned vendor
release rather than a development branch.

## Offline archive mode

Set the corresponding archive variable to install from a local `.zip`,
`.tar.gz`, `.tar.xz`, or `.tar.bz2` file. Example:

```bash
CMSIS_NN_ARCHIVE=/absolute/path/CMSIS-NN-v7.0.0.zip \
  ./scripts/fetch_cmsis_nn.sh
```

Archive mode extracts into a temporary directory, replaces the dependency's
destination directory, and then moves or copies the extracted content into the
expected layout. The supplied archive must therefore contain the upstream
repository contents at its root or inside one top-level directory.

## What the scripts do not validate

Successful fetching only confirms that the vendor trees were installed. It
does not prove that:

- every path registered in `cmsis_build.zig` exists in that upstream version;
- all required transitive C sources are registered;
- the freestanding target has compatible C standard-library headers;
- the final Cortex-M library compiles and links.

For the current build status and the cross-build command, see
`cmsis_build.md`.
