"""Explicit, bounds-checked reads; validation remains active under python -O."""
from __future__ import annotations

import struct


class FormatError(ValueError):
    """The input is corrupt or outside the format subset this importer supports."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise FormatError(message)


class Reader:
    def __init__(self, data: bytes, label: str):
        self.data = data
        self.label = label

    def check(self, offset: int, length: int, field: str = "data") -> None:
        require(offset >= 0 and length >= 0 and offset <= len(self.data)
                and length <= len(self.data) - offset,
                f"{self.label}: {field} at 0x{offset:x} ({length} bytes) is outside the record")

    def unpack(self, fmt: str, offset: int, field: str = "field") -> tuple:
        self.check(offset, struct.calcsize(fmt), field)
        return struct.unpack_from(fmt, self.data, offset)

    def u32(self, offset: int, field: str = "uint32") -> int:
        return self.unpack("<I", offset, field)[0]

    def bytes(self, offset: int, length: int, field: str = "data") -> bytes:
        self.check(offset, length, field)
        return self.data[offset:offset + length]

    def cstring(self, offset: int) -> str:
        self.check(offset, 1, "string")
        end = self.data.find(b"\0", offset)
        require(end >= 0, f"{self.label}: unterminated string at 0x{offset:x}")
        try:
            return self.data[offset:end].decode("ascii")
        except UnicodeDecodeError as exc:
            raise FormatError(f"{self.label}: unsupported non-ASCII catalog string") from exc
