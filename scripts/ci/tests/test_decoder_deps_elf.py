"""H-DECODER-DEPS, ELF branch: red when a NEEDED companion is not in the
bundle, green when it is. Uses synthetic ELF64 shared objects (stdlib only)."""

from __future__ import annotations

import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from ci import assertions, binfmt  # noqa: E402


def make_elf(needed):
    """Minimal ELF64 LE: null section, .dynstr, .dynamic (DT_NEEDED..., DT_NULL)."""
    strtab = b"\x00"
    offsets = []
    for name in needed:
        offsets.append(len(strtab))
        strtab += name.encode() + b"\x00"
    dyn = b"".join(struct.pack("<qQ", 1, o) for o in offsets) + struct.pack("<qQ", 0, 0)
    str_off = 64
    dyn_off = str_off + len(strtab)
    sh_off = dyn_off + len(dyn)
    ehdr = bytearray(64)
    ehdr[:4] = b"\x7fELF"
    ehdr[4], ehdr[5], ehdr[6] = 2, 1, 1
    struct.pack_into("<H", ehdr, 18, 0xB7)
    struct.pack_into("<Q", ehdr, 0x28, sh_off)
    struct.pack_into("<HHH", ehdr, 0x3A, 64, 3, 0)

    def sh(sh_type, off, size, link):
        h = bytearray(64)
        struct.pack_into("<I", h, 4, sh_type)
        struct.pack_into("<QQ", h, 0x18, off, size)
        struct.pack_into("<I", h, 0x28, link)
        return bytes(h)

    shdrs = sh(0, 0, 0, 0) + sh(3, str_off, len(strtab), 0) + sh(6, dyn_off, len(dyn), 1)
    return bytes(ehdr) + strtab + dyn + shdrs


class _Source:
    def __init__(self, files):
        self.files = files

    def members(self):
        return list(self.files)

    def read(self, name):
        return self.files[name]

    def find(self, basenames):
        return [n for n in self.files if n.rsplit("/", 1)[-1] in set(basenames)]


class ElfDepsTest(unittest.TestCase):
    PIN = [{"artifact": n} for n in ("libdng_decoder_native.so", "libheif.so.1", "libde265.so.0")]

    def _bundle(self, with_de265):
        files = {
            "bundle/lib/libdng_decoder_native.so": make_elf(["libheif.so.1", "libm.so.6", "libc.so.6"]),
            "bundle/lib/libheif.so.1": make_elf(["libde265.so.0", "libstdc++.so.6"]),
        }
        if with_de265:
            files["bundle/lib/libde265.so.0"] = make_elf(["libc.so.6"])
        return files

    def _run(self, files):
        return assertions._assert_decoder_deps({"pin_libraries": self.PIN, "source": _Source(files)})

    def test_parser_reads_needed(self):
        self.assertEqual(binfmt.elf_needed(make_elf(["a.so.1", "libc.so.6"])), ["a.so.1", "libc.so.6"])

    def test_red_when_companion_missing(self):
        status, msg = self._run(self._bundle(False))
        self.assertEqual(status, "fail")
        self.assertIn("libde265.so.0", msg)

    def test_green_when_complete(self):
        self.assertEqual(self._run(self._bundle(True))[0], "pass")

    def test_red_on_unlisted_needed(self):
        files = self._bundle(True)
        files["bundle/lib/libde265.so.0"] = make_elf(["libnewdep.so.3"])
        status, msg = self._run(files)
        self.assertEqual(status, "fail")
        self.assertIn("libnewdep.so.3", msg)


if __name__ == "__main__":
    unittest.main()
