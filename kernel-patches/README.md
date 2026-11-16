# Local kernel patches

Patches applied to the KernelSU submodule at build time, by `build-socrates.sh`,
and never committed into the submodule itself. That keeps `KernelSU/` pointing
at an upstream commit anyone can fetch, while the tree still carries the
changes it needs.

Both halves of the naming are deliberate: `kernel-patches/` rather than
`patches/`, and `.diff` rather than `.patch`, because the kernel `.gitignore`
excludes exactly `patches/` and `*.patch`.

## avc-spoof.diff

Ports KernelSU's `avc_spoof` feature onto the `builtin` branch.

`KSU_FEATURE_AVC_SPOOF` (id 10003) exists on upstream `main` only, while
`CONFIG_KSU_SUSFS*` exists on `builtin` only, so no single branch provides
both. Upstream's own SUSFS glue for `main` is not the answer: it is 939
insertions against 2281 deletions, because it replaces main's syscall-hook
architecture with builtin's manual hooks. Porting the 216-line feature the
other way round is an order of magnitude smaller.

Written against `KernelSU` @ `f9aa2fec23c3f4a06a935f69dc04cb85b261e7f3`
(upstream `builtin`, 2026-11-12). It touches:

| File | Change |
|---|---|
| `kernel/feature/avc_spoof.c` | new, adapted from `main` |
| `kernel/feature/avc_spoof.h` | new |
| `kernel/include/uapi/feature.h` | `KSU_FEATURE_AVC_SPOOF = 10003` |
| `kernel/policy/feature.c` | name table entry |
| `kernel/ksu_main.c` | unity-build include + `ksu_avc_spoof_init()` |
| `kernel/runtime/ksud.c` | late init from `on_post_fs_data()` |
| `kernel/extension/extension.c` | rename `forced_mask` / `forced_pending` |

The rename fixes a latent bug rather than working around one: `policy/feature.c`
and `extension/extension.c` each declare a static bitmap with the same name, and
the unity build merges them into one symbol for as long as the types match.
Raising `KSU_FEATURE_MAX` to 10004 makes them incompatible and the build fails.

## When the submodule moves

`build-socrates.sh` applies each patch in three steps: skip if already applied,
plain `git apply` if the context still matches, otherwise `git apply --3way`,
which merges using the blob ids recorded in the patch. The last one absorbs
upstream edits that merely land near a hunk.

A three-way merge only fails when upstream changed the lines the patch edits.
Then the build stops with the conflicting files listed, and nothing is built:

```
git -C KernelSU reset -q
git -C KernelSU checkout -- .
git -C KernelSU clean -fd
```

## Regenerating after a conflict

Bump `.gitmodules` / the submodule pointer first, then redo the port by hand on
top of the clean submodule, and export the result as a patch:

```bash
git -C KernelSU apply --3way kernel-patches/avc-spoof.diff   # best-effort start
$EDITOR KernelSU/kernel/feature/avc_spoof.c                  # resolve by hand
git -C KernelSU add -A
git -C KernelSU diff --cached --binary > kernel-patches/avc-spoof.diff
git -C KernelSU reset                                        # unstage, keep files
```

Then update `KSU_PATCH_BASE` in `build-socrates.sh` to the new submodule commit,
and confirm the script's own apply path works in a scratch clone before
committing:

```bash
git clone --no-hardlinks .git/modules/KernelSU /tmp/ksu-check
git -C /tmp/ksu-check checkout <new base sha>
git -C /tmp/ksu-check apply --check kernel-patches/avc-spoof.diff
```

## Expected state

Because the patch is applied to the submodule worktree, a build leaves
`KernelSU` showing as modified:

```
$ git status --short
 m KernelSU
```

`git status` inside `KernelSU` lists the seven files above. That is the
designed state, not an unfinished commit.
