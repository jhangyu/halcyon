"""Binary-format readers for the R-7 assertion suite: executable architecture
(Mach-O / universal / ELF / PE headers) and PE import tables. Pure functions over
bytes; stdlib only; no subprocess (G-1/G-3)."""

from __future__ import annotations

import struct

_MACHO_CPU = {0x0100000C: "arm64", 0x01000007: "x86_64", 0x00000007: "i386"}
_ELF_MACHINE = {0x3E: "x86_64", 0xB7: "aarch64", 0x28: "arm", 0x03: "i386"}
_PE_MACHINE = {0x8664: "x86_64", 0xAA64: "arm64", 0x14C: "i386"}


def machine_arch(data):
    """Return the architecture name encoded in a Mach-O/ELF/PE header.

    Raises ValueError when the bytes are not a recognised executable format.
    """
    if len(data) < 64:
        raise ValueError("file too short to carry an executable header")
    magic = data[:4]
    if magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):  # Mach-O 64/32 LE
        cputype = struct.unpack_from("<I", data, 4)[0]
        return _MACHO_CPU.get(cputype, f"macho-cputype-0x{cputype:x}")
    if magic == b"\xca\xfe\xba\xbe":  # universal binary
        count = struct.unpack_from(">I", data, 4)[0]
        slices = []
        for index in range(count):
            cputype = struct.unpack_from(">I", data, 8 + index * 20)[0]
            slices.append(_MACHO_CPU.get(cputype, f"0x{cputype:x}"))
        return "+".join(slices)
    if magic == b"\x7fELF":
        endian = "<" if data[5] == 1 else ">"
        machine = struct.unpack_from(endian + "H", data, 18)[0]
        return _ELF_MACHINE.get(machine, f"elf-machine-0x{machine:x}")
    if magic[:2] == b"MZ":
        pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
        if data[pe_offset : pe_offset + 4] != b"PE\x00\x00":
            raise ValueError("MZ header without a PE signature")
        machine = struct.unpack_from("<H", data, pe_offset + 4)[0]
        return _PE_MACHINE.get(machine, f"pe-machine-0x{machine:x}")
    raise ValueError(f"unrecognised executable format (magic {magic!r})")


def pe_imports(data):
    """Return (static, delayed) imported DLL names of a PE image, lowercased.

    Read from data directories 1 (import) and 13 (delay import); raises
    ValueError when the bytes are not a PE image.
    """
    if data[:2] != b"MZ":
        raise ValueError("not a PE image (no MZ header)")
    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe_offset : pe_offset + 4] != b"PE\x00\x00":
        raise ValueError("MZ header without a PE signature")
    sections_count = struct.unpack_from("<H", data, pe_offset + 6)[0]
    optional_size = struct.unpack_from("<H", data, pe_offset + 20)[0]
    optional = pe_offset + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    directories = optional + (112 if magic == 0x20B else 96)
    sections = [
        struct.unpack_from("<IIII", data, optional + optional_size + i * 40 + 8)
        for i in range(sections_count)
    ]

    def offset(rva):
        for virtual_size, virtual_address, raw_size, raw_offset in sections:
            if virtual_address <= rva < virtual_address + max(virtual_size, raw_size):
                return rva - virtual_address + raw_offset
        raise ValueError(f"RVA 0x{rva:x} lies in no section")

    def names(index, stride, name_field):
        rva = struct.unpack_from("<I", data, directories + index * 8)[0]
        found = []
        if not rva:
            return found
        cursor = offset(rva)
        while True:
            name_rva = struct.unpack_from("<I", data, cursor + name_field)[0]
            if not name_rva:
                return found
            start = offset(name_rva)
            found.append(data[start : data.index(b"\x00", start)].decode("ascii").lower())
            cursor += stride

    return names(1, 20, 12), names(13, 32, 4)
