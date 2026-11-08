"""Observed scene/object directory; identifiers are not guessed semantic names."""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass

from .binary import Reader, require
from .mdic import Chunk, Container


@dataclass(frozen=True)
class Record:
    index: int
    offset: int
    kind: int
    header_size: int
    data: bytes
    group: int

    @property
    def label(self) -> str:
        return f"Group {self.group}, object {self.index} (type {self.kind})"


@dataclass(frozen=True)
class Scene:
    group: int
    category: int
    payload_size: int
    header_size: int
    child_sizes: tuple[int, ...]
    records: tuple[Record, ...]


def parse_scene(data: bytes, expected_group: int) -> Scene:
    r = Reader(data, f"Scene payload in group {expected_group}")
    require(r.bytes(0, 8) == b"\x01" * 4 + b"\x02" * 4, f"{r.label}: unsupported signature")
    category, serial = r.unpack("<HH", 8)
    require(category in (2, 3, 4), f"{r.label}: unsupported category {category}")
    require(serial == expected_group + 1, f"{r.label}: serial {serial} does not match group number")
    directory = r.u32(12)
    require(directory >= 16 and directory % 4 == 0, f"{r.label}: invalid object directory offset")
    require(r.u32(directory) == 0x03030303, f"{r.label}: missing object-directory marker")
    count, table = r.unpack("<II", directory + 4)
    require(0 < count <= 65535, f"{r.label}: unsupported object count {count}")
    require(table >= directory + 12 and table % 4 == 0, f"{r.label}: object table overlaps the header")
    r.check(table, count * 12, "object directory")
    entries = [r.unpack("<III", table + 12 * i) for i in range(count)]
    records = []
    previous_end = table + count * 12
    for i, (offset, kind, size) in enumerate(entries):
        end = entries[i + 1][0] if i + 1 < count else len(data)
        require(offset % 4 == 0 and previous_end <= offset < end <= len(data),
                f"{r.label}: object {i} has unordered, overlapping or out-of-bounds offsets")
        require(size > 0 and size <= end - offset, f"{r.label}: object {i} header exceeds its record")
        records.append(Record(i, offset, kind, size, data[offset:end], expected_group))
        previous_end = end
    children = ()
    if category == 3:
        child_count = r.u32(28)
        require(32 + child_count * 4 <= directory, f"{r.label}: child-size table exceeds the header")
        children = tuple(r.u32(32 + 4 * i) for i in range(child_count))
    return Scene(expected_group, category, len(data), directory, children, tuple(records))


class Catalog:
    def __init__(self, container: Container):
        self.container = container
        self.scenes: dict[int, Scene] = {}
        self.scene_chunks: dict[int, Chunk] = {}
        self.textures: dict[tuple[int, int], Chunk] = {}
        for chunk in container.chunks:
            if chunk.kind == 4:
                require(chunk.group not in self.scenes, f"Group {chunk.group}: multiple scene payloads are unsupported")
                self.scenes[chunk.group] = parse_scene(container.payload(chunk), chunk.group)
                self.scene_chunks[chunk.group] = chunk
            elif chunk.kind == 2:
                self.textures[(chunk.group, chunk.resource_id)] = chunk
        self.texture_groups = sorted({group for group, _ in self.textures})
        self.descriptors = []
        group_at = {g.offset: g.index for g in container.groups}
        for scene in self.scenes.values():
            for i, expected_size in enumerate(scene.child_sizes, scene.group + 1):
                child = self.scene_chunks.get(i)
                require(child is not None and child.payload_size + child.header_size == expected_size,
                        f"Group {scene.group}: child scene {i} does not match its declared size")
            if scene.group != 0:
                continue
            for record in scene.records:
                if record.kind != 4000:
                    continue
                r = Reader(record.data, record.label)
                fields = r.unpack("<6I", 0)
                require(fields[2] >= 24 and fields[3] >= 24, f"{r.label}: string points into descriptor header")
                require(fields[4] in group_at, f"{r.label}: scene descriptor points outside group starts")
                self.descriptors.append(dict(name=r.cstring(fields[2]), container=r.cstring(fields[3]),
                                             container_offset=fields[4], group=group_at[fields[4]]))

    def record(self, group: int, index: int, kind: int | None = None) -> Record:
        scene = self.scenes.get(group)
        require(scene is not None and 0 <= index < len(scene.records),
                f"Unsupported asset layout: missing group {group}, object {index}")
        record = scene.records[index]
        require(kind is None or record.kind == kind,
                f"Unsupported asset layout: {record.label}, expected type {kind}")
        return record

    def texture(self, group: int, texture_id: int) -> Chunk:
        candidates = [g for g in self.texture_groups if g <= group]
        require(bool(candidates), f"No texture resource group before scene {group}")
        chunk = self.textures.get((candidates[-1], texture_id), self.textures.get((0, texture_id)))
        require(chunk is not None, f"Unresolved texture {texture_id} in scene group {group}")
        return chunk

    @property
    def summary(self) -> dict:
        return {
            "scene_payloads": len(self.scenes),
            "object_record_count": sum(len(s.records) for s in self.scenes.values()),
            "class_counts": dict(sorted(Counter(r.kind for s in self.scenes.values() for r in s.records).items())),
            "scene_descriptors": self.descriptors,
            "blocks": [dict(group=s.group, category=s.category, payload_size=s.payload_size,
                            object_count=len(s.records), child_count=len(s.child_sizes))
                       for s in self.scenes.values()],
        }
