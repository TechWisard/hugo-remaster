"""Strict catalog and lossless extraction of the observed MDIC chunk container."""
from __future__ import annotations

from collections import Counter
from dataclasses import asdict, dataclass
import hashlib
import io
import json
from pathlib import Path
import wave

from .binary import FormatError, Reader, require

ALIGNMENT = 2048
MAX_SOURCE_BYTES = 256 * 1024 * 1024
MAX_TEXTURE_PIXELS = 4 * 1024 * 1024


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


@dataclass(frozen=True)
class Chunk:
    index: int
    group: int
    offset: int
    header_size: int
    payload_size: int
    kind: int
    aux0: int | None
    aux1: int | None
    sha256: str

    @property
    def resource_id(self) -> int:
        return self.aux0 if self.aux0 is not None else self.index

    @property
    def width(self) -> int:
        return (self.aux1 or 0) & 65535

    @property
    def height(self) -> int:
        return (self.aux1 or 0) >> 16

    @property
    def label(self) -> str:
        return f"g{self.group:03d}_id{self.resource_id:04d}_{self.offset:08x}"


@dataclass(frozen=True)
class Group:
    index: int
    offset: int
    span: int
    member_count: int


@dataclass
class Container:
    data: bytes
    chunks: list[Chunk]
    groups: list[Group]
    audio: dict[int, dict]

    def payload(self, chunk: Chunk) -> bytes:
        start = chunk.offset + chunk.header_size
        return self.data[start:start + chunk.payload_size]

    @property
    def summary(self) -> dict:
        return {
            "input_size": len(self.data), "input_sha256": sha256(self.data),
            "alignment": ALIGNMENT, "groups": len(self.groups),
            "chunk_counts": dict(sorted(Counter(c.kind for c in self.chunks).items())),
            "all_group_spans_match": True, "all_group_member_counts_match": True,
            "bitmap_layout": "RGBA8, row-major",
            "audio_formats": [dict(channels=k[0], sample_rate=k[1], sample_width=k[2], count=v)
                              for k, v in sorted(Counter(
                                  (a["channels"], a["sample_rate"], a["sample_width"])
                                  for a in self.audio.values()).items())],
        }


def validate_wav(payload: bytes, label: str) -> dict:
    r = Reader(payload, label)
    require(r.bytes(0, 4) == b"RIFF" and r.bytes(8, 4) == b"WAVE", f"{label}: expected RIFF/WAVE")
    require(r.u32(4) + 8 == len(payload), f"{label}: RIFF size does not match the chunk")
    try:
        with wave.open(io.BytesIO(payload), "rb") as wav:
            channels, width, rate, frames = wav.getnchannels(), wav.getsampwidth(), wav.getframerate(), wav.getnframes()
            require(wav.getcomptype() == "NONE" and channels in (1, 2) and width in (1, 2, 3, 4)
                    and 0 < rate <= 192000, f"{label}: unsupported PCM format")
            require(len(wav.readframes(frames)) == frames * channels * width, f"{label}: truncated PCM frames")
    except (wave.Error, EOFError) as exc:
        raise FormatError(f"{label}: invalid WAV: {exc}") from exc
    return dict(channels=channels, sample_width=width, sample_rate=rate, frames=frames)


def parse_mdic(data: bytes) -> Container:
    require(0 < len(data) <= MAX_SOURCE_BYTES, "HUGO4.CD is empty or exceeds the 256 MiB importer limit")
    require(len(data) % ALIGNMENT == 0, "HUGO4.CD length is not aligned to 2048 bytes (possibly truncated)")
    r = Reader(data, "MDIC container")
    chunks: list[Chunk] = []
    groups: list[Group] = []
    audio: dict[int, dict] = {}
    texture_keys: set[tuple[int, int]] = set()
    offset = 0
    members = 0

    def close_group(end: int) -> None:
        if groups:
            group = groups[-1]
            require(end - group.offset == group.span,
                    f"Group {group.index}: declared span {group.span} does not match {end - group.offset}")
            require(members == group.member_count,
                    f"Group {group.index}: declared {group.member_count} members, found {members}")

    while offset < len(data):
        require(r.bytes(offset, 4, "signature") == b"MDIC", f"Missing MDIC signature at 0x{offset:x}")
        header, length, kind = r.unpack("<III", offset + 4, "chunk header")
        require(header in (16, 24), f"Unsupported MDIC header size {header} at 0x{offset:x}")
        require(kind in (1, 2, 4, 5), f"Unsupported MDIC chunk type {kind} at 0x{offset:x}")
        r.check(offset, header, "extended header")
        r.check(offset + header, length, "payload")
        end = offset + header + length
        aligned_end = (end + ALIGNMENT - 1) // ALIGNMENT * ALIGNMENT
        require(aligned_end <= len(data), f"Truncated aligned chunk at 0x{offset:x}")
        aux0, aux1 = r.unpack("<II", offset + 16) if header == 24 else (None, None)
        if kind == 1:
            close_group(offset)
            require(header == 24 and length == 0, f"Invalid group header at 0x{offset:x}")
            require(aux0 is not None and aux0 >= ALIGNMENT and aux0 % ALIGNMENT == 0
                    and aux0 <= len(data) - offset, f"Invalid group span at 0x{offset:x}")
            require(aux1 is not None and aux1 <= aux0 // ALIGNMENT - 1,
                    f"Impossible group member count at 0x{offset:x}")
            groups.append(Group(len(groups), offset, aux0, aux1))
            members = 0
        else:
            require(bool(groups), "MDIC asset appears before a group header")
            members += 1
        require(bool(groups), "No MDIC groups found")
        payload = data[offset + header:end]
        chunk = Chunk(len(chunks), groups[-1].index, offset, header, length, kind, aux0, aux1, sha256(payload))
        if kind == 2:
            require(header == 24 and chunk.width > 0 and chunk.height > 0,
                    f"Texture at 0x{offset:x} has no valid dimensions")
            pixels = chunk.width * chunk.height
            require(pixels <= MAX_TEXTURE_PIXELS and length == pixels * 4,
                    f"Texture at 0x{offset:x}: RGBA length does not match dimensions")
            key = (chunk.group, chunk.resource_id)
            require(key not in texture_keys, f"Duplicate texture ID {key[1]} in group {key[0]}")
            texture_keys.add(key)
        elif kind == 4:
            require(length >= 16, f"Empty/truncated scene at 0x{offset:x}")
        elif kind == 5:
            require(header == 24, f"Audio at 0x{offset:x} has no resource ID")
            audio[chunk.index] = validate_wav(payload, f"WAV chunk {chunk.index}")
        chunks.append(chunk)
        offset = aligned_end
    close_group(len(data))
    return Container(data, chunks, groups, audio)


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")


def extract(container: Container, directory: Path) -> dict[int, Path]:
    """Only writes into a caller-owned staging directory; no input filenames are used."""
    from PIL import Image

    directory.mkdir(parents=True, exist_ok=True)
    exports = {}
    rows = []
    for chunk in container.chunks:
        row = asdict(chunk)
        payload = container.payload(chunk)
        target = None
        if chunk.kind == 2:
            target = directory / "textures" / (chunk.label + ".png")
            target.parent.mkdir(exist_ok=True)
            Image.frombytes("RGBA", (chunk.width, chunk.height), payload).save(target)
            with Image.open(target) as check:
                require(check.mode == "RGBA" and check.tobytes() == payload, f"PNG verification failed: {target.name}")
            row.update(width=chunk.width, height=chunk.height, resource_id=chunk.resource_id)
        elif chunk.kind in (4, 5):
            folder, suffix = ("scene_data", ".bin") if chunk.kind == 4 else ("audio", ".wav")
            target = directory / folder / (chunk.label + suffix)
            target.parent.mkdir(exist_ok=True)
            target.write_bytes(payload)
            require(sha256(target.read_bytes()) == chunk.sha256, f"Extraction verification failed: {target.name}")
        if target is not None:
            exports[chunk.index] = target
            row["export"] = target.relative_to(directory).as_posix()
        rows.append(row)
    write_json(directory / "chunks.json", rows)
    write_json(directory / "groups.json", [asdict(g) for g in container.groups])
    write_json(directory / "summary.json", container.summary)
    return exports
