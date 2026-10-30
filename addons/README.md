# Kernel add-ons

This directory makes the Droidspaces and USB Arsenal changes reproducible
without committing them to the kernel branch. `apply-addons.sh` applies the
patches to the working tree and merges the config fragments into the generated
`.config` at build time, so upstream syncs stay clean.

## Local build

```sh
bash build.sh
```

`build.sh` clones the toolchains if needed, calls
`addons/apply-addons.sh prepare`, builds the kernel, and writes the flashable zip
to `AnyKernel/BlackHole-v2.1_KSU-miatoll-<timestamp>.zip`.

## What gets applied

- **USB Arsenal** (`kernel-patches/4.14`, pinned in `addons.env`):
  patches `0004`-`0012`. `0001` is already covered by this tree's CAF
  multi-gadget support; `0002` and `0003` depend on Samsung-only code that this
  tree does not have.
- **Droidspaces** (`Documentation/resources/kernel-patches/non-GKI`, pinned in
  `addons.env`): the cgroup restore patch. The `xt_qtaguid` patch is skipped
  because this tree does not carry that driver.
- **Config fragments** (`config/droidspace.config`, `config/usbarsenal.config`):
  merged into `out/.config` with `scripts/kconfig/merge_config.sh`, followed by
  `make olddefconfig`.

All entries are idempotent: files are checked for known markers, so running the
script twice is safe.

## Manual use

```sh
# Apply patches, generate the defconfig and merge fragments
./addons/apply-addons.sh prepare \
  --defconfig arch/arm64/configs/vendor/xiaomi/miatoll_defconfig \
  --out out

# Apply patches only
./addons/apply-addons.sh patches

# Merge fragments into an existing config
./addons/apply-addons.sh config out/.config
```

Useful environment variables:

| Variable | Purpose |
| --- | --- |
| `ADDONS_CACHE_DIR` | Download cache (default: `addons/.cache`) |
| `USB_ARSENAL_DIR` | Use a local USB-Arsenal checkout |
| `DROIDSPACES_PATCH_DIR` | Use a local directory with `01*.patch` / `02*.patch` |
| `USB_ARSENAL_REF` | Override the pinned USB Arsenal commit |
| `DROIDSPACES_REF` | Override the pinned Droidspaces commit |

## Updating the pinned sources

1. Edit the SHAs in `addons/addons.env`.
2. Run `./addons/apply-addons.sh prepare ...` on a clean tree.
3. Check `out/.config` and do a full build.
4. If upstream renamed or reordered the patches, update the sentinels and the
   curated patch list in `apply-addons.sh`.

## GitHub Actions

`.github/workflows/build.yml` runs on pushes to `16.2` / `16.2-NEW`, on `v*`
tags, and manually. It checks out submodules, caches the toolchains and ccache,
runs `bash build.sh`, uploads the zip as an artifact, and publishes a release.

Enable Actions in your fork and make sure this workflow exists on the fork's
default branch (normally `16.2`) so fork syncs trigger it. A fork sync is a push
to the default branch; syncing other branches is a separate operation.

## Known limitation

`CONFIG_CFS_BANDWIDTH` cannot be enabled while `CONFIG_SCHED_WALT=y`, so
Droidspaces `--cpus` limits are unavailable unless WALT is dropped. The script
prints a warning instead of failing.
