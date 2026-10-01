"""Characterization tests for the binary-format readers (machine_arch,
pe_imports, parse_dwarfdump_uuid). Fixtures are hand-built byte literals so the
suite runs offline on any host; each fixture shape follows the reader's code."""

from __future__ import annotations

import struct
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
if str(REPO_ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(REPO_ROOT / "scripts"))

from ci import binfmt  # noqa: E402


def _pad(header, size=64):
    return header + b"\x00" * (size - len(header))


def _macho(cputype):
    return _pad(b"\xcf\xfa\xed\xfe" + struct.pack("<I", cputype))


def _fat(*cputypes):
    body = b"\xca\xfe\xba\xbe" + struct.pack(">I", len(cputypes))
    for cputype in cputypes:
        body += struct.pack(">IIIII", cputype, 0, 0, 0, 0)
    return _pad(body, max(64, len(body)))


def _elf(machine, little_endian=True):
    ident = b"\x7fELF" + bytes([2, 1 if little_endian else 2]) + b"\x00" * 10
    endian = "<" if little_endian else ">"
    return _pad(ident + struct.pack(endian + "HH", 3, machine))


_PE_OFFSET = 0x40
_OPTIONAL = _PE_OFFSET + 24
_OPTIONAL_SIZE = 112 + 16 * 8  # PE32+ fixed part + 16 data directories
_SECTIONS = _OPTIONAL + _OPTIONAL_SIZE
_VA, _RAW, _SECTION_SIZE = 0x1000, 0x200, 0x400


def _pe(machine=0x8664, static=(), delayed=()):
    """A minimal PE32+ image: one section at RVA 0x1000 holding the import
    directory (20-byte descriptors, name RVA at +12) at 0x1000, the delay-import
    directory (32-byte descriptors, name RVA at +4) at 0x1100, and the DLL name
    strings from 0x1200 on."""
    image = bytearray(_RAW + _SECTION_SIZE)
    image[0:2] = b"MZ"
    struct.pack_into("<I", image, 0x3C, _PE_OFFSET)
    image[_PE_OFFSET:_PE_OFFSET + 4] = b"PE\x00\x00"
    struct.pack_into("<HH", image, _PE_OFFSET + 4, machine, 1)
    struct.pack_into("<H", image, _PE_OFFSET + 20, _OPTIONAL_SIZE)
    struct.pack_into("<H", image, _OPTIONAL, 0x20B)
    struct.pack_into("<IIII", image, _SECTIONS + 8, _SECTION_SIZE, _VA, _SECTION_SIZE, _RAW)
    directories = _OPTIONAL + 112
    name_rva = _VA + 0x200

    def place(names, table_rva, stride, name_field, index):
        nonlocal name_rva
        if not names:
            return
        struct.pack_into("<I", image, directories + index * 8, table_rva)
        for i, name in enumerate(names):
            struct.pack_into("<I", image, table_rva - _VA + _RAW + i * stride + name_field, name_rva)
            encoded = name.encode("ascii") + b"\x00"
            start = name_rva - _VA + _RAW
            image[start:start + len(encoded)] = encoded
            name_rva += len(encoded)

    place(static, _VA, 20, 12, 1)
    place(delayed, _VA + 0x100, 32, 4, 13)
    return bytes(image)


class MachineArchTests(unittest.TestCase):
    def test_macho_arm64(self):
        self.assertEqual(binfmt.machine_arch(_macho(0x0100000C)), "arm64")

    def test_macho_x86_64(self):
        self.assertEqual(binfmt.machine_arch(_macho(0x01000007)), "x86_64")

    def test_macho_unknown_cputype_is_named_not_raised(self):
        self.assertEqual(binfmt.machine_arch(_macho(0x12)), "macho-cputype-0x12")

    def test_universal_binary_joins_slices_in_order(self):
        self.assertEqual(binfmt.machine_arch(_fat(0x01000007, 0x0100000C)), "x86_64+arm64")

    def test_elf_x86_64_and_aarch64(self):
        self.assertEqual(binfmt.machine_arch(_elf(0x3E)), "x86_64")
        self.assertEqual(binfmt.machine_arch(_elf(0xB7)), "aarch64")

    def test_elf_big_endian_reads_machine_big_endian(self):
        self.assertEqual(binfmt.machine_arch(_elf(0x3E, little_endian=False)), "x86_64")

    def test_pe_x86_64_and_arm64(self):
        self.assertEqual(binfmt.machine_arch(_pe(machine=0x8664)), "x86_64")
        self.assertEqual(binfmt.machine_arch(_pe(machine=0xAA64)), "arm64")

    def test_short_input_raises(self):
        with self.assertRaisesRegex(ValueError, "too short"):
            binfmt.machine_arch(b"\xcf\xfa\xed\xfe")

    def test_mz_without_pe_signature_raises(self):
        with self.assertRaisesRegex(ValueError, "without a PE signature"):
            binfmt.machine_arch(_pad(b"MZ"))

    def test_unrecognised_magic_raises(self):
        with self.assertRaisesRegex(ValueError, "unrecognised executable format"):
            binfmt.machine_arch(_pad(b"JUNK"))


class PeImportsTests(unittest.TestCase):
    def test_static_and_delayed_buckets_lowercased(self):
        static, delayed = binfmt.pe_imports(
            _pe(static=["KERNEL32.dll"], delayed=["flutter_windows.dll", "Plugin.DLL"])
        )
        self.assertEqual(static, ["kernel32.dll"])
        self.assertEqual(delayed, ["flutter_windows.dll", "plugin.dll"])

    def test_no_directories_gives_two_empty_lists(self):
        self.assertEqual(binfmt.pe_imports(_pe()), ([], []))

    def test_not_mz_raises(self):
        with self.assertRaisesRegex(ValueError, "no MZ header"):
            binfmt.pe_imports(_macho(0x0100000C))

    def test_rva_outside_every_section_raises(self):
        image = bytearray(_pe(static=["a.dll"]))
        struct.pack_into("<I", image, _OPTIONAL + 112 + 8, 0x9000)
        with self.assertRaisesRegex(ValueError, "lies in no section"):
            binfmt.pe_imports(bytes(image))


if __name__ == "__main__":
    unittest.main()
