#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Standalone build script for the Redmi K60 Pro (socrates / SM8550) kernel.
#
# This tree is LineageOS lineage-24.0 plus:
#   - SukiSU Ultra (drivers/kernelsu, branch builtin: KernelSU + KPM + SUSFS)
#   - SUSFS v2.4.0 kernel patches
#   - arch/arm64/configs/vendor/socrates-sukisu.config
#
# Usage:
#   ./build-socrates.sh                  build Image, patch it, pack a boot image
#   ./build-socrates.sh --no-kpm         skip the KernelPatch step
#   ./build-socrates.sh --no-pack        skip the boot image, keep the Image
#   ./build-socrates.sh --stock FILE     use FILE as the stock boot template
#   ./build-socrates.sh --release STR    override the kernel release string;
#               STR is either a full 5.15.<sublevel>[-suffix] string or a bare
#               suffix such as "byxingstar", expanded to 5.15.194-byxingstar
#
# Environment:
#   CLANG_DIR   AOSP prebuilt clang directory (must contain bin/clang)
#   STOCK_BOOT  stock boot image used as the template for the flashable image;
#               defaults to ./boot_stock.img, then ../boot_stock.img
#   KERNEL_RELEASE  same as --release, e.g. 5.15.194-xingstar
#   KP_DIR      ShirkNeko/SukiSU_KernelPatch_patch checkout; fetched and built
#               into KP_CACHE automatically when missing
#   KP_CACHE    cache root for KernelPatch and the Arm bare metal toolchain
#               (default: ~/.cache/socrates-kp)
#   SKEY        KernelPatch superkey (random, saved to .superkey if unset)
#   JOBS        parallel compile jobs (default: nproc, capped on small machines)
#   OUT         output directory (default: <tree>/out)
#
# Two details in here are load bearing. Do not "clean them up":
#
#   1. LLVM=1 is passed to *every* make invocation, including gki_defconfig and
#      olddefconfig. Kconfig probes CC_IS_CLANG from $(CC); without LLVM=1 it
#      probes the host gcc, decides CC_IS_CLANG=n and silently drops both LTO
#      and CFI_CLANG. A kernel built without CFI cannot run the vendor modules
#      that Xiaomi ships, because they are CFI instrumented.
#
#   2. SUBLEVEL=194 plus the pinned CONFIG_LOCALVERSION reproduce the stock
#      HyperOS 4 release string byte for byte, so uname -r matches the ROM.
#      It is not what decides whether vendor modules load: same_magic() in
#      kernel/module.c skips the release prefix once a module carries CRCs,
#      so the flags part of the vermagic is the part that has to match.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$REPO/out}
JOBS=${JOBS:-}
# The release the tree declares for itself. Everything below derives from it
# unless --release overrides it, so the build reports 5.15.<tree sublevel>
# instead of pretending to be the stock ROM kernel.
TREE_RELEASE=$(awk '/^VERSION =/{v=$3} /^PATCHLEVEL =/{p=$3} /^SUBLEVEL =/{s=$3}
                    END{if (s == "") printf "%s.%s", v, p; else printf "%s.%s.%s", v, p, s}' \
                "$REPO/Makefile")
DEFAULT_SUBLEVEL=${TREE_RELEASE##*.}
KV_SUBLEVEL=""
EXPECTED_RELEASE="$TREE_RELEASE"
RELEASE_OVERRIDE=${KERNEL_RELEASE:-}
RELEASE_LOCALVERSION=""
DO_KPM=1
DO_PACK=1
STOCK_BOOT=${STOCK_BOOT:-}
KP_CACHE=${KP_CACHE:-$HOME/.cache/socrates-kp}
ARM_TC_URL="https://developer.arm.com/-/media/Files/downloads/gnu/13.3.rel1/binrel/arm-gnu-toolchain-13.3.rel1-x86_64-aarch64-none-elf.tar.xz"

while [ $# -gt 0 ]; do
    case "$1" in
        --no-kpm) DO_KPM=0; shift ;;
        --kpm)    DO_KPM=1; shift ;;
        --no-pack) DO_PACK=0; shift ;;
        --release)
            RELEASE_OVERRIDE=${2:-}
            [ -n "$RELEASE_OVERRIDE" ] || { echo "--release needs a string" >&2; exit 1; }
            shift 2 ;;
        --stock|--pack)
            STOCK_BOOT=${2:-}
            [ -n "$STOCK_BOOT" ] || { echo "$1 needs a path" >&2; exit 1; }
            shift 2 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

step() { printf '\n===== %s =====\n' "$*"; }

# scripts/kconfig/merge_config.sh and the fragment paths below are relative to
# the tree root, so anchor the working directory before anything else runs.
cd "$REPO"

# --release rewrites the kernel release string, so uname -r and the settings
# screen show something else. It is opt in, and it states what it does and does
# not affect: the release prefix is not what vendor modules are checked on.
if [ -n "$RELEASE_OVERRIDE" ]; then
    # The kernel assembles its release string from VERSION.PATCHLEVEL.SUBLEVEL
    # plus the localversion suffix, so a bare name can never be the whole
    # string. Accept one anyway and expand it against the default sublevel,
    # which is what someone typing their own name actually means.
    case "$RELEASE_OVERRIDE" in
        5.15.*) : ;;
        *)
            RELEASE_OVERRIDE="5.15.${DEFAULT_SUBLEVEL}-${RELEASE_OVERRIDE#-}"
            echo "note: --release expanded to '$RELEASE_OVERRIDE'" >&2
            ;;
    esac
    if [[ ! "$RELEASE_OVERRIDE" =~ ^5\.15\.([0-9]+)(.*)$ ]]; then
        echo "error: --release must be 5.15.<sublevel>[-suffix] or a bare suffix, got '$RELEASE_OVERRIDE'" >&2
        exit 1
    fi
    KV_SUBLEVEL="${BASH_REMATCH[1]}"
    RELEASE_LOCALVERSION="${BASH_REMATCH[2]}"
    EXPECTED_RELEASE="$RELEASE_OVERRIDE"
    cat >&2 <<'EOF'

  ############################################################
  #  NOTE: custom kernel release requested
  #
  #  Only the part after the first space of the vermagic is
  #  compared when the module carries symbol CRCs, which every
  #  prebuilt vendor_dlkm module does on a MODVERSIONS kernel.
  #  See same_magic() in kernel/module.c. The release prefix is
  #  ignored, so changing it does not stop modules from loading
  #  as long as the flags part (SMP preempt mod_unload modversions
  #  aarch64) stays identical, which it does here.
  #
  #  What would break loading is a different module ABI: other
  #  KMI generation, a different compiler affecting CFI, or
  #  symbols whose CRC drifted. Keep the stock boot image around
  #  anyway.
  ############################################################
EOF
fi

step "kernelsu submodule"
# KernelSU lives in a submodule at KernelSU/ and is reachable from the kernel
# build through drivers/kernelsu, which is a symlink. Fetch it when the tree
# was cloned without --recursive, and repair the symlink on checkouts that
# materialise it as a plain file (Windows without symlink support).
if [ ! -f "$REPO/KernelSU/kernel/Makefile" ]; then
    git -C "$REPO" submodule update --init KernelSU
fi
if [ ! -d "$REPO/drivers/kernelsu" ]; then
    rm -f "$REPO/drivers/kernelsu"
    ln -s ../KernelSU/kernel "$REPO/drivers/kernelsu"
fi
echo "kernelsu: $(git -C "$REPO/KernelSU" log --oneline -1 2>/dev/null || echo unknown)"

step "locating clang"
if [ -z "${CLANG_DIR:-}" ]; then
    for c in "$REPO/../toolchain/clang-repo/clang-r450784d" \
             "$REPO/toolchain/clang" \
             "$REPO/../clang-r450784d"; do
        if [ -x "$c/bin/clang" ]; then CLANG_DIR=$c; break; fi
    done
fi
if [ -z "${CLANG_DIR:-}" ] || [ ! -x "$CLANG_DIR/bin/clang" ]; then
    cat >&2 <<'EOF'
error: AOSP prebuilt clang not found.

This kernel is built with clang-r450784d (clang 14.0.6), the exact toolchain
the stock HyperOS 4 kernel was built with. Using a different major version
changes the CFI type hashes and the vendor modules will refuse to load.

Fetch it once, next to the kernel tree:

    git clone --depth=1 --filter=blob:none --no-checkout \
        -b android13-release \
        https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 clang-repo
    cd clang-repo
    git sparse-checkout init --cone
    git sparse-checkout set clang-r450784d
    git checkout android13-release

then either export CLANG_DIR=/path/to/clang-repo/clang-r450784d or put the
tree so that ../toolchain/clang-repo/clang-r450784d resolves.
EOF
    exit 1
fi
export PATH="$CLANG_DIR/bin:$PATH"
echo "clang: $CLANG_DIR"
clang --version | head -1

if [ -z "$JOBS" ]; then
    JOBS=$(nproc)
    mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
    # a thin LTO link is the memory peak, keep some headroom
    if [ "$mem_gb" -lt 10 ] && [ "$JOBS" -gt 6 ]; then JOBS=6; fi
fi
echo "jobs : $JOBS"

# scripts/setlocalversion appends a bare '+' when this variable is unset, and
# appends '-ab<number>' when BUILD_NUMBER is in the environment.
export LOCALVERSION=""
unset BUILD_NUMBER || true

MAKE_ARGS=(-C "$REPO" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1)
# SUBLEVEL is only forced when a release was requested. Left alone, the tree
# reports the version its own Makefile declares.
if [ -n "$KV_SUBLEVEL" ]; then
    MAKE_ARGS+=(SUBLEVEL="$KV_SUBLEVEL")
fi

# Regenerating the config rewrites include/config/auto.conf, which marks every
# object stale, so a plain repeat run of this script would rebuild the whole
# tree for nothing. Hash the config inputs and skip the pipeline when they have
# not changed, which keeps iteration incremental.
CONFIG_HASH=$(
    cat arch/arm64/configs/gki_defconfig \
        arch/arm64/configs/vendor/kalama_GKI.config \
        arch/arm64/configs/vendor/socrates_GKI.config \
        arch/arm64/configs/vendor/socrates-sukisu.config |
    sha256sum | cut -d" " -f1
)
CONFIG_HASH="${CONFIG_HASH}-sub${KV_SUBLEVEL:-tree}${RELEASE_LOCALVERSION}"
CONFIG_STAMP="$OUT/.socrates-config"

if [ -f "$CONFIG_STAMP" ] && [ "$(cat "$CONFIG_STAMP")" = "$CONFIG_HASH" ] && [ -f "$OUT/.config" ]; then
    step "config unchanged, skipping regeneration"
else
    step "defconfig"
    make "${MAKE_ARGS[@]}" gki_defconfig

    step "merge vendor fragments"
    FRAGMENTS=(
        arch/arm64/configs/vendor/kalama_GKI.config
        arch/arm64/configs/vendor/socrates_GKI.config
        arch/arm64/configs/vendor/socrates-sukisu.config
    )
    if [ -n "$RELEASE_OVERRIDE" ]; then
        # merged last so it wins over the pinned value in socrates-sukisu.config
        printf '# CONFIG_LOCALVERSION_AUTO is not set\nCONFIG_LOCALVERSION="%s"\n' \
            "$RELEASE_LOCALVERSION" > "$OUT/.release.config"
        FRAGMENTS+=("$OUT/.release.config")
    fi
    scripts/kconfig/merge_config.sh -m -O "$OUT" "$OUT/.config" "${FRAGMENTS[@]}"

    step "olddefconfig"
    make "${MAKE_ARGS[@]}" olddefconfig

    # olddefconfig rewrites .config but not include/config/auto.conf, and
    # scripts/setlocalversion reads auto.conf. Without this the release string
    # silently drifts from what .config says, which the check below only
    # catches after the fact.
    step "sync auto.conf"
    touch "$OUT/.config"
    make "${MAKE_ARGS[@]}" syncconfig

    echo "$CONFIG_HASH" > "$CONFIG_STAMP"
fi

step "verify release string"
RELEASE=$(make "${MAKE_ARGS[@]}" -s kernelrelease)
echo "got      : $RELEASE"
echo "expected : $EXPECTED_RELEASE"
if [ "$RELEASE" != "$EXPECTED_RELEASE" ]; then
    echo "error: release string drifted, refusing to build a kernel that cannot load the stock modules" >&2
    exit 1
fi

step "building Image"
make "${MAKE_ARGS[@]}" -j"$JOBS" Image
IMAGE="$OUT/arch/arm64/boot/Image"
ls -l "$IMAGE"

# KernelPatch is the runtime behind CONFIG_KPM: it rides along as an extra
# payload in the Image and takes over the entry point, which is what answers
# the KPM ioctl ABI. kptools and kpimg are fetched and built once into
# KP_CACHE, so a clean checkout produces a KPM capable image without manual
# prep work.
ensure_kp() {
    if [ -n "${KP_DIR:-}" ] && [ -x "$KP_DIR/tools/kptools" ] && [ -f "$KP_DIR/kernel/kpimg" ]; then
        return 0
    fi

    local cand
    for cand in "${KP_DIR:-}" "$REPO/../kp_patch" "$KP_CACHE/kp_patch"; do
        [ -n "$cand" ] || continue
        if [ -f "$cand/kernel/Makefile" ]; then KP_DIR=$cand; break; fi
    done

    if [ -z "${KP_DIR:-}" ] || [ ! -f "$KP_DIR/kernel/Makefile" ]; then
        step "fetching KernelPatch"
        mkdir -p "$KP_CACHE"
        git clone --depth=1 https://github.com/ShirkNeko/SukiSU_KernelPatch_patch "$KP_CACHE/kp_patch"
        KP_DIR="$KP_CACHE/kp_patch"
    fi

    if [ ! -x "$KP_DIR/tools/kptools" ]; then
        step "building kptools"
        make -C "$KP_DIR/tools" -j"$JOBS"
    fi

    if [ ! -f "$KP_DIR/kernel/kpimg" ]; then
        step "building kpimg"
        if ! command -v aarch64-none-elf-gcc >/dev/null 2>&1; then
            # Find the compiler itself. The tarball carries several directories
            # named bin (the target sysroot has one too), so a name based search
            # for "bin" picks the wrong one.
            local tcgcc
            tcgcc=$(find "$KP_CACHE/toolchain" -maxdepth 4 -type f -name aarch64-none-elf-gcc 2>/dev/null | head -1 || true)
            if [ -z "$tcgcc" ]; then
                step "fetching Arm bare metal toolchain"
                mkdir -p "$KP_CACHE/toolchain"
                curl -fL --retry 2 -o "$KP_CACHE/toolchain/armgnu.tar.xz" "$ARM_TC_URL"
                tar -xf "$KP_CACHE/toolchain/armgnu.tar.xz" -C "$KP_CACHE/toolchain"
                tcgcc=$(find "$KP_CACHE/toolchain" -maxdepth 4 -type f -name aarch64-none-elf-gcc | head -1)
            fi
            [ -n "$tcgcc" ] || { echo "error: no aarch64-none-elf-gcc found" >&2; exit 1; }
            export PATH="$(dirname "$tcgcc"):$PATH"
        fi
        TARGET_COMPILE=aarch64-none-elf- make -C "$KP_DIR/kernel" -j"$JOBS"
    fi
}

if [ "$DO_KPM" = "1" ]; then
    ensure_kp
    step "patching Image with KernelPatch (KPM runtime)"
    echo "kptools : $KP_DIR/tools/kptools"
    echo "kpimg   : $KP_DIR/kernel/kpimg"
    SKEY_FILE="$REPO/.superkey"
    if [ -z "${SKEY:-}" ]; then
        [ -f "$SKEY_FILE" ] || (umask 077; openssl rand -hex 16 > "$SKEY_FILE")
        SKEY=$(cat "$SKEY_FILE")
    fi
    "$KP_DIR/tools/kptools" -p -i "$IMAGE" -k "$KP_DIR/kernel/kpimg" -S "$SKEY" -o "$IMAGE.kp"
    IMAGE="$IMAGE.kp"
    ls -l "$IMAGE"
fi

if [ "$DO_PACK" = "1" ]; then
    step "packing boot image"
    if [ -z "$STOCK_BOOT" ]; then
        for cand in "$REPO/boot_stock.img" "$REPO/../boot_stock.img" "$REPO/stock_boot.img"; do
            if [ -f "$cand" ]; then STOCK_BOOT=$cand; break; fi
        done
    fi
    if [ -z "$STOCK_BOOT" ] || [ ! -f "$STOCK_BOOT" ]; then
        cat >&2 <<'EOF'
error: no stock boot image to use as the template.

A flashable boot image is made by swapping the kernel inside your own stock
boot.img, so that the partition geometry and the AVB blob stay where the
bootloader expects them. The script needs that file and it cannot ship with
the tree.

Drop it next to the tree and it is picked up automatically:

    cp /path/to/boot.img ./boot_stock.img

or point at it explicitly:

    ./build-socrates.sh --stock /path/to/boot.img

Pulling it from a rooted phone:

    adb shell su -c 'dd if=/dev/block/by-name/boot of=/sdcard/boot.img'
    adb pull /sdcard/boot.img boot_stock.img

Pass --no-pack to stop after the kernel Image and skip this step.
EOF
        echo "  image: $IMAGE" >&2
        exit 1
    fi
    echo "template: $STOCK_BOOT"
    python3 "$REPO/scripts/pack_boot.py" --stock "$STOCK_BOOT" --kernel "$IMAGE" --out "$OUT/boot.img"
    PACKED="$OUT/boot.img"
fi

step "done"
echo "image   : $IMAGE"
if [ "$DO_KPM" = "1" ]; then
    echo "kpm     : patched with KernelPatch"
else
    echo "kpm     : NOT patched (--no-kpm)"
fi
if [ -n "${PACKED:-}" ]; then
    echo "boot    : $PACKED"
    echo "boot sha: $(sha256sum "$PACKED" | cut -d' ' -f1)"
fi
echo "release : $RELEASE"
if [ -n "$RELEASE_OVERRIDE" ]; then
    echo "note    : custom release; vendor modules still load, same_magic() ignores"
    echo "          the release prefix when the module carries CRCs"
fi
echo "sha256  : $(sha256sum "$IMAGE" | cut -d' ' -f1)"
strings -a "$IMAGE" | grep -m1 '^Linux version 5' || true
