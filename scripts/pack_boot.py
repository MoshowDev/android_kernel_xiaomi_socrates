#!/usr/bin/env python3
"""Repack a boot v4 image with a newly built kernel, keeping stock geometry.

The stock socrates boot_b.img is laid out as

    0        - 1584      boot image header (v4)
    4096     - N         kernel
    N ..     - A         zero padding to the next page
    A        - A + 2304  AVB0 vbmeta blob (signed by Xiaomi)
    A + 2304 - end       zero padding to the partition size

The new kernel is written at the same 4096 offset, everything from the end of
the kernel up to the vbmeta offset is zeroed, and the original vbmeta blob is
copied back at its original offset, so the only difference from stock is the
kernel payload.

The vbmeta hash descriptor still describes the stock kernel, so AVB cannot
validate the new one. That is unavoidable without Xiaomi's signing key and is
the same situation as any third party boot image on an unlocked bootloader.

Usage:
    pack_boot.py --stock boot_stock.img --kernel Image --out boot_new.img
"""
import argparse
import hashlib
import struct
import sys

PAGE = 4096

ap = argparse.ArgumentParser()
ap.add_argument("--stock", required=True, help="stock boot image used as the template")
ap.add_argument("--kernel", required=True, help="new raw Image (or Image patched by kptools)")
ap.add_argument("--out", required=True)
args = ap.parse_args()

stock = open(args.stock, "rb").read()
kernel = open(args.kernel, "rb").read()

if stock[:8] != b"ANDROID!":
    sys.exit("stock image: bad magic, not an Android boot image")
hdr_ver = struct.unpack_from("<I", stock, 40)[0]
if hdr_ver != 4:
    sys.exit("only boot header v4 supported, got %d" % hdr_ver)

old_kernel_size = struct.unpack_from("<I", stock, 8)[0]
header_size = struct.unpack_from("<I", stock, 20)[0]
avb_off = stock.find(b"AVB0", PAGE)
if avb_off < 0:
    sys.exit("no AVB0 blob found in the stock image")

auth = struct.unpack_from(">Q", stock, avb_off + 12)[0]
aux = struct.unpack_from(">Q", stock, avb_off + 20)[0]
avb_len = 256 + auth + aux

print("stock kernel : %d bytes" % old_kernel_size)
print("new kernel   : %d bytes (%+d)" % (len(kernel), len(kernel) - old_kernel_size))
print("avb blob     : offset %d, %d bytes" % (avb_off, avb_len))

buf = bytearray(stock)

struct.pack_into("<I", buf, 8, len(kernel))
struct.pack_into("<I", buf, 12, 0)      # no ramdisk in boot, it lives in vendor_boot
struct.pack_into("<I", buf, 1580, 0)    # no boot signature

# clear everything from the start of the kernel area, then write the new kernel
buf[PAGE:] = b"\x00" * (len(buf) - PAGE)
end = PAGE + len(kernel)
if end > avb_off:
    sys.exit("new kernel does not fit before the vbmeta offset (%d > %d)" % (end, avb_off))
buf[PAGE:end] = kernel

# restore the original vbmeta where the bootloader expects it
buf[avb_off:avb_off + avb_len] = stock[avb_off:avb_off + avb_len]

open(args.out, "wb").write(bytes(buf))

print("output       : %s" % args.out)
print("size         : %d bytes" % len(buf))
print("sha256       : %s" % hashlib.sha256(buf).hexdigest())
print("free before avb: %d bytes" % (avb_off - end))
