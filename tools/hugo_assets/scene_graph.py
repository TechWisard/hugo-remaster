"""Bounded decoding of source references, transforms and fixed-slot object graphs.

Offsets in the dataclasses are relative to the containing Record.  Unknown flag
bits and auxiliary words stay raw; they are not treated as scene-tree links.
"""
from __future__ import annotations

from collections import Counter
from dataclasses import dataclass

import numpy as np

from .binary import Reader, require
from .catalog import Catalog, Record
from .mesh import Mesh, parse_mesh


GRAPH_POINTER_FIELDS = {8003: 8, 10000: 8, 10204: 12, 10300: 44, 10301: 8}
TRANSFORM_KINDS = frozenset((3000, 3001, 3002, 3003))


@dataclass(frozen=True)
class GraphNode:
    index: int
    offset: int
    transform_ref: int
    renderable_ref: int
    flags: int
    aux_count: int
    aux_offset: int
    local_bounds: np.ndarray | None

    @property
    def collision_mask_a(self) -> int:
        return self.flags

    @property
    def collision_mask_b(self) -> int:
        return self.aux_count


@dataclass(frozen=True)
class GraphState:
    index: int
    offset: int
    flags: int
    duration: float
    vector: np.ndarray
    bounds: np.ndarray
    nodes: tuple[GraphNode, ...]


@dataclass(frozen=True)
class ObjectGraph:
    offset: int
    node_count: int
    states: tuple[GraphState, ...]


@dataclass(frozen=True)
class SourceTransform:
    translation: np.ndarray
    matrix: np.ndarray

    @classmethod
    def identity(cls) -> SourceTransform:
        return cls(np.zeros(3, dtype=np.float64), np.eye(3, dtype=np.float64))

    def compose(self, local: SourceTransform) -> SourceTransform:
        """A local source-space transform under this source-space transform."""
        return SourceTransform(self.matrix @ local.translation + self.translation,
                               self.matrix @ local.matrix)

    def points(self, points: np.ndarray) -> np.ndarray:
        return np.asarray(points) @ self.matrix.T + self.translation


@dataclass(frozen=True)
class CollisionTriangle:
    submesh: int
    submesh_offset: int
    triangle: int
    surface_type: int
    vertices: np.ndarray


@dataclass(frozen=True)
class CollisionMesh:
    group: int
    record: int
    root_offset: int
    nodes: tuple[dict, ...]
    triangles: tuple[CollisionTriangle, ...]
    triangle_reference_count: int
    leaf_count: int


def parse_collision_mesh(record: Record, mesh: Mesh | None = None) -> CollisionMesh | None:
    """Recover the native quadtree's exact render-triangle subset and surface IDs.

    C3DPSXCollisionObject searches XY cells, then looks up each referenced packed
    face in its source submesh.  The low entry word is a returned surface ID;
    it is preserved numerically rather than assigned a guessed gameplay name.
    """
    r = Reader(record.data, record.label)
    require(record.kind == 2001, f"{r.label}: collision data requires a mesh")
    root = r.u32(52)
    if root == 0:
        return None
    mesh = mesh if mesh is not None else parse_mesh(record)
    require(mesh.sample_count == 1, f"{r.label}: animated native collision vertices are unsupported")
    require(root == mesh.extra_offset and root % 4 == 0, f"{r.label}: invalid collision root")
    part_table = r.u32(44)
    parts = {r.u32(part_table + 4 * i): i for i in range(len(mesh.parts))}
    nodes: list[dict] = []
    visited: set[int] = set()
    triangles: dict[tuple[int, int], CollisionTriangle] = {}
    references = leaves = 0

    def check_extra(offset: int, length: int, label: str) -> None:
        require(offset >= root and offset % 4 == 0, f"{r.label}: {label} pointer escapes collision data")
        r.check(offset, length, label)

    def visit(offset: int, depth: int = 0) -> int:
        nonlocal references, leaves
        require(depth <= 64 and len(nodes) < 100000, f"{r.label}: collision tree exceeds traversal limits")
        require(offset not in visited, f"{r.label}: cyclic/repeated collision-tree node")
        visited.add(offset)
        check_extra(offset, 36, "collision node")
        bounds = np.array(r.unpack("<4f", offset), dtype=np.float64)
        require(bool(np.isfinite(bounds).all() and (bounds[:2] <= bounds[2:]).all()),
                f"{r.label}: invalid collision-node XY bounds")
        children = r.unpack("<4I", offset + 16)
        leaf = r.u32(offset + 32)
        node_index = len(nodes)
        node = dict(source_offset=offset, source_bounds_xy=bounds.tolist(), children=[], entries=[])
        nodes.append(node)
        if leaf:
            check_extra(leaf, 8, "collision leaf")
            count, table = r.unpack("<2I", leaf)
            require(table == leaf + 8 and count <= 65535, f"{r.label}: invalid collision leaf table")
            check_extra(table, count * 12, "collision entries")
            leaves += 1
            node["source_leaf_offset"] = leaf
            for i in range(count):
                at = table + i * 12
                surface, face_count, part_offset, face_table = r.unpack("<HHII", at)
                require(0 < face_count <= 32767 and part_offset in parts,
                        f"{r.label}: collision entry has no valid source submesh/faces")
                check_extra(face_table, face_count * 2, "collision face IDs")
                face_ids = r.unpack("<" + "H" * face_count, face_table)
                part_index = parts[part_offset]
                part = mesh.parts[part_index]
                require(all(face < len(part.faces) for face in face_ids),
                        f"{r.label}: collision triangle index exceeds source submesh")
                node["entries"].append(dict(source_offset=at, surface_type=surface, submesh=part_index,
                                             submesh_offset=part_offset, triangle_indices=list(face_ids)))
                for face in face_ids:
                    key = part_index, face
                    old = triangles.get(key)
                    require(old is None or old.surface_type == surface,
                            f"{r.label}: conflicting native surface IDs for one source triangle")
                    if old is None:
                        points = part.vertices[0, part.faces[face]].astype(np.float64)
                        triangles[key] = CollisionTriangle(part_index, part_offset, face, surface, points)
                references += face_count
        for child in children:
            node["children"].append(visit(child, depth + 1) if child else None)
        return node_index

    visit(root)
    require(bool(triangles), f"{r.label}: native collision tree has no triangles")
    return CollisionMesh(record.group, record.index, root, tuple(nodes), tuple(triangles.values()), references, leaves)


def _bounds(reader: Reader, offset: int) -> np.ndarray:
    value = np.array(reader.unpack("<6f", offset), dtype=np.float64).reshape(2, 3)
    require(bool(np.isfinite(value).all() and (value[0] <= value[1]).all()),
            f"{reader.label}: invalid bounding box at 0x{offset:x}")
    return value


def parse_transform(record: Record) -> SourceTransform:
    """Preserve the stored first affine matrix, including non-orthogonal bases."""
    r = Reader(record.data, record.label)
    require(record.kind in TRANSFORM_KINDS and r.u32(0) == record.kind,
            f"{r.label}: expected a supported transform record")
    values = np.array(r.unpack("<12f", 4), dtype=np.float64)
    require(bool(np.isfinite(values).all()), f"{r.label}: non-finite transform")
    matrix = values[3:].reshape(3, 3)
    require(abs(float(np.linalg.det(matrix))) > 1e-12, f"{r.label}: singular transform")
    return SourceTransform(values[:3], matrix)


def parse_graph(record: Record, base: int | None = None) -> ObjectGraph:
    """Decode all states, with every node pointer checked against its row.

    The primary graph location depends on the owner class.  An explicit base can
    also decode the secondary type-10000 graph without claiming when it is used.
    """
    r = Reader(record.data, record.label)
    if base is None:
        require(record.kind in GRAPH_POINTER_FIELDS, f"{r.label}: no known graph-pointer field")
        base = r.u32(GRAPH_POINTER_FIELDS[record.kind])
    require(base >= record.header_size and base % 4 == 0,
            f"{r.label}: graph overlaps its owner header")
    magic, reserved, state_count, node_count, table, zero1, zero2, slots = r.unpack("<8I", base)
    require(magic == 0x01010101 and reserved == zero1 == zero2 == 0,
            f"{r.label}: invalid graph header at 0x{base:x}")
    require(0 < state_count <= 4096 and 0 < node_count <= 4096,
            f"{r.label}: unsupported graph counts")
    require(slots == 32 and table == 32 + 48 * node_count,
            f"{r.label}: unsupported runtime-slot/state-table layout")
    r.check(base + slots, node_count * 48, "runtime graph slots")
    r.check(base + table, state_count * 56, "graph state table")
    nodes_base = base + table + state_count * 56
    r.check(nodes_base, state_count * node_count * 32, "graph nodes")
    nodes_end = nodes_base + state_count * node_count * 32
    states = []
    for state_index in range(state_count):
        at = base + table + state_index * 56
        marker, zero, flags = r.unpack("<3I", at)
        duration, *vector = r.unpack("<4f", at + 12)
        require(marker == 0x02020202 and zero == 0, f"{r.label}: invalid graph-state marker")
        require(bool(np.isfinite([duration, *vector]).all()) and duration >= 0,
                f"{r.label}: invalid state duration/vector")
        state_nodes = at + r.u32(at + 52)
        require(state_nodes == nodes_base + state_index * node_count * 32,
                f"{r.label}: graph-state node pointer does not address its fixed row")
        nodes = []
        for node_index in range(node_count):
            pos = state_nodes + node_index * 32
            marker, zero, transform, zero2, renderable, node_flags, count, extra = r.unpack("<8I", pos)
            require(marker == 0x03030303 and zero == zero2 == 0,
                    f"{r.label}: invalid graph-node marker/reserved fields at 0x{pos:x}")
            require((transform == 0 or transform & 0x80000000 != 0)
                    and (renderable == 0 or renderable & 0x80000000 != 0),
                    f"{r.label}: malformed graph-node reference")
            node_bounds = None
            if extra:
                require(extra % 4 == 0 and pos + extra >= nodes_end,
                        f"{r.label}: auxiliary bounds overlap the node table")
                node_bounds = _bounds(r, pos + extra)
            nodes.append(GraphNode(node_index, pos, transform, renderable, node_flags,
                                   count, extra, node_bounds))
        states.append(GraphState(state_index, at, flags, duration,
                                 np.array(vector, dtype=np.float64), _bounds(r, at + 28), tuple(nodes)))
    return ObjectGraph(base, node_count, tuple(states))


class SceneIndex:
    """Resolve scoped handles through subscene → main scene → global scene."""

    def __init__(self, catalog: Catalog):
        self.catalog = catalog
        self.parents: dict[int, int | None] = {}
        for group, scene in catalog.scenes.items():
            if scene.category == 2:
                require(group == 0, "Unsupported global scene group")
                self.parents[group] = None
            elif scene.category == 3:
                require(group not in self.parents, f"Group {group}: overlapping scene ownership")
                self.parents[group] = 0
                for child in range(group + 1, group + 1 + len(scene.child_sizes)):
                    require(child not in self.parents and child in catalog.scenes
                            and catalog.scenes[child].category == 4,
                            f"Group {group}: invalid/overlapping subscene {child}")
                    self.parents[child] = group
        require(set(self.parents) == set(catalog.scenes) and 0 in self.parents,
                "One or more scene groups have no validated parent")

    def groups_for_main(self, group: int) -> tuple[int, ...]:
        scene = self.catalog.scenes.get(group)
        require(scene is not None and scene.category == 3, f"Group {group} is not a main scene")
        return tuple(range(group, group + 1 + len(scene.child_sizes)))

    def segment_neighbors(self, main_group: int) -> list[dict]:
        """Validate the file's explicit previous/next scope offsets.

        These links describe adjacency; they do not by themselves prove which
        scopes the native loader keeps resident or which actors have started.
        """
        groups = self.groups_for_main(main_group)[1:]
        by_offset = {g.offset: g.index for g in self.catalog.container.groups}
        result = []
        for ordinal, group in enumerate(groups):
            chunk = self.catalog.scene_chunks.get(group)
            require(chunk is not None, f"Group {group}: missing subscene payload for neighbor validation")
            r = Reader(self.catalog.container.payload(chunk), f"Subscene {group}")
            previous, following = r.unpack("<2I", 16)
            resolved = []
            for word in (previous, following):
                require(word == 0 or word in by_offset, f"Group {group}: neighbor does not address an MDIC group")
                target = by_offset[word] if word else None
                require(target is None or target in groups, f"Group {group}: neighbor escapes its main scene")
                resolved.append(target)
            expected = [groups[ordinal - 1] if ordinal else None,
                        groups[ordinal + 1] if ordinal + 1 < len(groups) else None]
            require(resolved == expected, f"Group {group}: unsupported non-linear subscene adjacency")
            result.append(dict(group=group, ordinal=ordinal, previous_group=resolved[0], next_group=resolved[1],
                               source_previous_container_offset=previous, source_next_container_offset=following,
                               source_header_fields=[16, 20], parent_group=main_group,
                               native_residency_policy_decoded=False))
        return result

    def resolve(self, group: int, word: int,
                expected: set[int] | frozenset[int] | tuple[int, ...] | None = None) -> Record | None:
        require(group in self.parents, f"Unknown reference source group {group}")
        if word == 0:
            return None
        require(0 <= word <= 0xffffffff and word & 0x80000000 != 0,
                f"Group {group}: malformed reference 0x{word:x}")
        scope, index = (word >> 16) & 0x7fff, word & 65535
        target = group
        for _ in range(scope):
            parent = self.parents[target]
            require(parent is not None, f"Group {group}: reference 0x{word:x} escapes the scene ancestry")
            target = parent
        record = self.catalog.record(target, index)
        require(expected is None or record.kind in expected,
                f"Group {group}: reference 0x{word:x} resolves to unsupported type {record.kind}")
        return record

    def transform(self, group: int, word: int) -> SourceTransform:
        record = self.resolve(group, word, TRANSFORM_KINDS)
        return SourceTransform.identity() if record is None else parse_transform(record)

    def evidence(self, record: Record) -> dict:
        chunk = self.catalog.scene_chunks.get(record.group)
        result = dict(group=record.group, record=record.index, type=record.kind,
                      scene_payload_offset=record.offset)
        if chunk is not None:
            result["container_offset"] = chunk.offset + chunk.header_size + record.offset
        return result

    def audit(self) -> dict:
        """Validate every known graph and reference, even unused action states."""
        counts = Counter(scene_groups=len(self.catalog.scenes))
        kinds = Counter()
        for scene in self.catalog.scenes.values():
            counts[f"category_{scene.category}_groups"] += 1
            for record in scene.records:
                if record.kind not in GRAPH_POINTER_FIELDS:
                    continue
                graphs = [parse_graph(record)]
                if record.kind == 10000:
                    graphs.append(parse_graph(record, Reader(record.data, record.label).u32(12)))
                    counts["auxiliary_graphs"] += 1
                for graph in graphs:
                    counts["graphs"] += 1
                    counts["states"] += len(graph.states)
                    for state in graph.states:
                        for node in state.nodes:
                            counts["node_slots"] += 1
                            transform = self.resolve(record.group, node.transform_ref, TRANSFORM_KINDS)
                            target = self.resolve(record.group, node.renderable_ref)
                            if transform is not None:
                                parse_transform(transform)
                                counts["resolved_transform_references"] += 1
                            if target is not None:
                                counts["resolved_renderable_references"] += 1
                                kinds[target.kind] += 1
                            counts["validated_auxiliary_bounds"] += int(node.local_bounds is not None)
        return dict(counts, renderable_type_counts=dict(sorted(kinds.items())),
                    unresolved_graph_references=0, malformed_graphs=0,
                    reference_scope="ancestor count: 0 local, 1 parent, 2 grandparent")
