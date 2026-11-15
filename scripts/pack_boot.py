#!/usr/bin/env python3
"""Repack a boot v4 image with a newly built kernel.

The stock socrates boot_b.img is laid out as

    0        - 1584      boot image header (v4)
    4096     - N         kernel
    N ..     - A         zero padding to the next page
    A        - A + 2304  AVB0 vbmeta blob (signed by Xiaomi)
    A + 2304 - end       zero padding to the partition size

That geometry is baked in below as SOCRATES, together with the 2304 byte
vbmeta blob, so packing no longer needs a copy of the stock boot image. Pass
--stock to use a different image as the template instead (another ROM, a
different device, or a dump taken from the phone).

The kernel is written at offset 4096, everything after it is zeroed, and the
vbmeta blob is written at its original offset, so the only difference from
stock is the kernel payload.

The vbmeta hash descriptor still describes the stock kernel, so AVB cannot
validate the new one. That is unavoidable without Xiaomi's signing key and is
the same situation as any third party boot image on an unlocked bootloader.

Usage:
    pack_boot.py --kernel Image --out boot.img
    pack_boot.py --stock boot_stock.img --kernel Image --out boot.img
"""
import argparse
import base64
import hashlib
import struct
import sys

PAGE = 4096
HEADER_SIZE = 1584
HEADER_VERSION = 4
ANDROID_MAGIC = b"ANDROID!"

# Geometry of the socrates boot partition, taken from the stock boot_b.img
# (HyperOS 4, CP2A.260605.016). Partition size is 96 MiB; the vbmeta blob sits
# at 47583232, which leaves room for a kernel up to ~45.4 MB.
SOCRATES = {
    "total": 100663296,
    "page": PAGE,
    "header_size": HEADER_SIZE,
    "header_version": HEADER_VERSION,
    "os_version": 0,
    "cmdline": b"",
    "avb_offset": 47583232,
    "avb_sha256": "a386820cbd254c5d9b03400bb00a83626e6c42fa8ce7e0ac614da8d3cbb75095",
    "avb_b64": (
        "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"
    ),
}


def die(msg):
    sys.exit("error: %s" % msg)


def build_header(kernel_size, header_size, header_version, os_version, cmdline):
    hdr = bytearray(header_size)
    hdr[0:8] = ANDROID_MAGIC
    struct.pack_into("<I", hdr, 8, kernel_size)
    struct.pack_into("<I", hdr, 12, 0)          # no ramdisk, it lives in vendor_boot
    struct.pack_into("<I", hdr, 16, os_version)
    struct.pack_into("<I", hdr, 20, header_size)
    struct.pack_into("<I", hdr, 40, header_version)
    hdr[44:44 + len(cmdline)] = cmdline
    struct.pack_into("<I", hdr, header_size - 4, 0)   # no boot signature
    return hdr


def pack(kernel, layout, avb_blob, out_path):
    total = layout["total"]
    page = layout["page"]
    avb_off = layout["avb_offset"]

    if len(avb_blob) + avb_off > total:
        die("vbmeta blob does not fit in a %d byte image" % total)
    if page + len(kernel) > avb_off:
        die("kernel is %d bytes, which does not fit before the vbmeta offset %d"
            % (len(kernel), avb_off))

    buf = bytearray(total)
    hdr = build_header(len(kernel), layout["header_size"],
                       layout["header_version"], layout["os_version"],
                       layout["cmdline"])
    # Slice assignment with a shorter sequence resizes the bytearray, so write
    # only as many bytes as the header actually has and leave the rest of the
    # first page zeroed.
    buf[0:len(hdr)] = hdr
    buf[page:page + len(kernel)] = kernel
    buf[avb_off:avb_off + len(avb_blob)] = avb_blob

    with open(out_path, "wb") as fh:
        fh.write(buf)

    print("output         : %s" % out_path)
    print("size           : %d bytes" % len(buf))
    print("kernel offset  : %d, %d bytes" % (page, len(kernel)))
    print("avb offset     : %d, %d bytes" % (avb_off, len(avb_blob)))
    print("free before avb: %d bytes" % (avb_off - page - len(kernel)))
    print("sha256         : %s" % hashlib.sha256(buf).hexdigest())
    return buf


def layout_from_stock(path):
    stock = open(path, "rb").read()
    if stock[:8] != ANDROID_MAGIC:
        die("%s: bad magic, not an Android boot image" % path)
    header_version = struct.unpack_from("<I", stock, 40)[0]
    if header_version != HEADER_VERSION:
        die("%s: only boot header v4 supported, got %d" % (path, header_version))

    avb_off = stock.find(b"AVB0", PAGE)
    if avb_off < 0:
        die("%s: no AVB0 blob found" % path)
    auth = struct.unpack_from(">Q", stock, avb_off + 12)[0]
    aux = struct.unpack_from(">Q", stock, avb_off + 20)[0]
    avb_len = 256 + auth + aux

    header_size = struct.unpack_from("<I", stock, 20)[0]
    layout = {
        "total": len(stock),
        "page": PAGE,
        "header_size": header_size,
        "header_version": header_version,
        "os_version": struct.unpack_from("<I", stock, 16)[0],
        "cmdline": stock[44:44 + 1536].split(b"\x00")[0],
        "avb_offset": avb_off,
    }
    return layout, stock[avb_off:avb_off + avb_len]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stock", help="use this boot image as the template instead of the built-in layout")
    ap.add_argument("--kernel", required=True, help="new raw Image (or Image patched by kptools)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    kernel = open(args.kernel, "rb").read()

    if args.stock:
        layout, avb_blob = layout_from_stock(args.stock)
        print("template       : %s" % args.stock)
    else:
        layout = SOCRATES
        avb_blob = base64.b64decode(SOCRATES["avb_b64"])
        got = hashlib.sha256(avb_blob).hexdigest()
        if got != SOCRATES["avb_sha256"]:
            die("embedded vbmeta blob is corrupt (sha256 %s, expected %s)"
                % (got, SOCRATES["avb_sha256"]))
        print("template       : built-in socrates layout")

    pack(kernel, layout, avb_blob, args.out)


if __name__ == "__main__":
    main()
