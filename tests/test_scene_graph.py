"""Generated graph/mesh fixtures; no original game data is committed."""
from __future__ import annotations

import json
from dataclasses import replace
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from hugo_assets.binary import FormatError
from hugo_assets.catalog import Catalog, Record, Scene
from hugo_assets.gltf import export_glb, verify_glb
from hugo_assets.levels import _batch_geometry, assemble_level, export_campaign, export_level
from hugo_assets.mesh import Selection, parse_mesh
from hugo_assets.mdic import Chunk, Container, Group
from hugo_assets.scene_graph import SceneIndex, SourceTransform, parse_collision_mesh, parse_graph, parse_transform


def graph_bytes(rows):
    count, slots = len(rows), len(rows[0])
    table = 32 + 48 * slots
    nodes = table + 56 * count
    data = bytearray(nodes + 32 * slots * count)
    struct.pack_into("<8I", data, 0, 0x01010101, 0, count, slots, table, 0, 0, 32)
    for i, row in enumerate(rows):
        at = table + 56 * i
        struct.pack_into("<3I10fI", data, at, 0x02020202, 0, 2, 1.0,
                         0, 0, 0, 0, 0, 0, 10, 10, 10, nodes + i * slots * 32 - at)
        for j, (transform, target) in enumerate(row):
            struct.pack_into("<8I", data, nodes + (i * slots + j) * 32,
                             0x03030303, 0, transform, 0, target, 0, 0, 0)
    return bytes(data)


def graph_record(rows, kind=8003, group=1, index=0):
    header = 12
    data = bytearray(header)
    struct.pack_into("<I", data, 8, header)
    return Record(index, 100, kind, header, bytes(data) + graph_bytes(rows), group)


def transform_record(index, group, translation=(0, 0, 0), matrix=None):
    matrix = np.eye(3) if matrix is None else np.array(matrix)
    data = struct.pack("<I12f", 3000, *translation, *matrix.reshape(-1))
    return Record(index, 100 + 100 * index, 3000, 52, data, group)


def triangle_record(index, group):
    data = bytearray(152)
    for offset, value in ((0, 2001), (4, 0x01010101), (32, 0x02020202),
                          (40, 104), (44, 112), (48, 192), (52, 196), (112, 116)):
        struct.pack_into("<I", data, offset, value)
    struct.pack_into("<H", data, 38, 1)
    struct.pack_into("<HH", data, 104, 1, 1)
    struct.pack_into("<6f", data, 72, 0, 0, 0, 10, 10, 0)
    struct.pack_into("<IIHHII", data, 116, 1, 0, 3, 1, 176, 152)
    struct.pack_into("<I", data, 148, 180)
    data += b"".join(struct.pack("<hhhBB", x, y, 0, 0, 0) for x, y in ((0, 0), (10, 0), (0, 10)))
    data += struct.pack("<I", (1 << 10) | (2 << 20)) + bytes((100, 60, 40, 0)) * 3 + bytes(4)
    data += struct.pack("<4f5I", 0, 0, 10, 10, 0, 0, 0, 0, 232)
    data += struct.pack("<IIHHII", 1, 240, 5, 1, 116, 252) + bytes(4)
    return Record(index, 100, 2001, 104, bytes(data), group)


def synthetic_catalog(actions=1):
    global_records = (triangle_record(0, 0),)
    wrapper = graph_record([[(0x80000002, 0x80000000)]], group=1, index=3)
    primary = bytearray(graph_bytes([[(0, 0), (0, 0x80000003)]] * actions))
    for action in range(actions):
        state = 128 + action * 56
        node = state + struct.unpack_from("<I", primary, state + 52)[0]
        struct.pack_into("<3I", primary, node + 20, 4097 if action == 0 else 2,
                         8 if action == 0 else 4, len(primary) - node)
        primary += struct.pack("<6f", -1, -2, -3, 1, 2, 3)
    primary = bytes(primary)
    auxiliary = graph_bytes([[(0, 0x80000000)]])
    data = bytearray(1588)
    struct.pack_into("<3I", data, 8, 1588, 1588 + len(primary), 0x80000001)
    player = Record(4, 900, 10000, 1588, bytes(data) + primary + auxiliary, 1)
    main_records = (triangle_record(0, 1), transform_record(1, 1, (100, 200, 300)),
                    transform_record(2, 1, (0, 0, 10)), wrapper, player)
    sub_records = [transform_record(0, 2, (200, 400, 0), [[0, -1, 0], [1, 0, 0], [0, 0, 1]])]
    for index, kind, size in ((1, 10401, 156), (2, 10400, 1248)):
        b = bytearray(size)
        struct.pack_into("<4I", b, 0, 0, 1, 0x80000000, 0x80010000)
        sub_records.append(Record(index, 100 + index * 100, kind, size, bytes(b), 2))
    catalog = Catalog.__new__(Catalog)
    catalog.scenes = {0: Scene(0, 2, 0, 16, (), global_records),
                      1: Scene(1, 3, 288, 288, (40,), main_records),
                      2: Scene(2, 4, 24, 24, (), tuple(sub_records))}
    payload = bytearray(2048)
    struct.pack_into("<IIHHI", payload, 544, 0x01010101, 0x02020202, 3, 2, 288)
    struct.pack_into("<4I", payload, 544 + 20, 40, 1024, 1, 40)
    struct.pack_into("<I", payload, 544 + 160, 1024)
    struct.pack_into("<IIHHIII", payload, 1056, 0x01010101, 0x02020202, 4, 3, 24, 0, 0)
    catalog.scene_chunks = {1: Chunk(0, 1, 528, 16, 288, 4, None, None, "synthetic"),
                            2: Chunk(1, 2, 1040, 16, 24, 4, None, None, "synthetic")}
    catalog.descriptors = [dict(group=1, name="SyntheticLevel")]
    catalog.container = Container(bytes(payload), list(catalog.scene_chunks.values()),
                                  [Group(g, g * 512, 512, 1) for g in range(3)], {})
    return catalog


class GraphTests(unittest.TestCase):
    def test_scope_is_ancestor_depth_not_absolute_group(self):
        index = SceneIndex(synthetic_catalog())
        self.assertEqual(index.resolve(2, 0x80000000).kind, 3000)
        self.assertEqual(index.resolve(2, 0x80010000).group, 1)
        self.assertEqual(index.resolve(2, 0x80020000).group, 0)
        self.assertIsNone(index.resolve(2, 0))
        for word in (1, 0x80030000, 0x8001ffff):
            with self.subTest(word=word), self.assertRaises(FormatError):
                index.resolve(2, word)
        with self.assertRaisesRegex(FormatError, "unsupported type"):
            index.resolve(2, 0x80010000, (3000,))

    def test_multiple_state_pointers_are_relative_to_each_descriptor(self):
        record = graph_record([[(0x80000001, 0x80000002), (0, 0)],
                               [(0, 0x80010003), (0x80000004, 0)]])
        graph = parse_graph(record)
        self.assertEqual((graph.node_count, len(graph.states)), (2, 2))
        self.assertEqual(graph.states[1].nodes[0].renderable_ref, 0x80010003)
        self.assertEqual(graph.states[1].nodes[0].offset - graph.states[0].nodes[0].offset, 64)
        first = graph.states[0].offset
        second = graph.states[1].offset
        self.assertEqual(struct.unpack_from("<I", record.data, second + 52)[0]
                         - struct.unpack_from("<I", record.data, first + 52)[0], 8)

    def test_corrupt_graph_pointers_markers_counts_and_bounds_are_rejected(self):
        original = graph_record([[(0, 0)]])
        state, node = 12 + 80, 12 + 80 + 56
        mutations = [(12 + 8, 0xffffffff), (state + 52, 0xfffffff0),
                     (node, 0x04040404), (node + 8, 123), (node + 28, 4)]
        for offset, value in mutations:
            data = bytearray(original.data)
            struct.pack_into("<I", data, offset, value)
            changed = Record(0, 100, 8003, 12, bytes(data), 1)
            with self.subTest(offset=offset), self.assertRaises(FormatError):
                parse_graph(changed)
        data = bytearray(original.data)
        struct.pack_into("<f", data, state + 28, float("nan"))
        with self.assertRaisesRegex(FormatError, "bounding box"):
            parse_graph(Record(0, 100, 8003, 12, bytes(data), 1))

    def test_affine_basis_is_preserved_and_composes_with_parent(self):
        shear = [[1, 0.1, 0], [0, 1, 0], [0, 0, 1]]
        local = parse_transform(transform_record(0, 1, (10, 20, 30), shear))
        parent = SourceTransform(np.array([100, 200, 300]), np.array([[0, -1, 0], [1, 0, 0], [0, 0, 1]]))
        result = parent.compose(local).points(np.array([[2, 5, 7]]))
        np.testing.assert_allclose(result, [[75, 212.5, 337]])
        np.testing.assert_allclose(local.matrix, shear, atol=1e-7)

    def test_orphan_subscene_is_rejected(self):
        catalog = synthetic_catalog()
        catalog.scenes[1] = Scene(1, 3, 0, 288, (), catalog.scenes[1].records)
        with self.assertRaisesRegex(FormatError, "no validated parent"):
            SceneIndex(catalog)

    def test_scope_neighbors_are_checked_against_source_header_offsets(self):
        catalog = synthetic_catalog()
        rows = SceneIndex(catalog).segment_neighbors(1)
        self.assertEqual((rows[0]["group"], rows[0]["previous_group"], rows[0]["next_group"]), (2, None, None))
        data = bytearray(catalog.container.data)
        struct.pack_into("<I", data, 1056 + 16, 2048)
        catalog.container.data = bytes(data)
        with self.assertRaisesRegex(FormatError, "neighbor does not address"):
            SceneIndex(catalog).segment_neighbors(1)


class LevelTests(unittest.TestCase):
    def test_nested_visual_and_parent_mesh_are_placed_without_resource_dumping(self):
        level = assemble_level(synthetic_catalog(), 1)
        self.assertEqual(len(level.instances), 3)
        self.assertEqual(level.spawn, [1, 3, -2])
        player = next(o for o in level.owners if o["type"] == 10000)
        np.testing.assert_allclose(player["bounds"], [[1, 3.1, -2.1], [1.1, 3.1, -2]])
        segment = next(o for o in level.owners if o["type"] == 10400)
        self.assertEqual(segment["collision_role"], "segment")
        np.testing.assert_allclose(segment["bounds"], [[1.9, 0, -4.1], [2, 0, -4]])
        self.assertTrue(all(i.mesh.group == 1 for i in level.instances))

    def test_glb_reuses_geometry_and_preserves_named_owner_hierarchy(self):
        catalog = synthetic_catalog()
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            entry = export_level(assemble_level(catalog, 1), catalog, output)
            raw = (output / entry["geometry_path"]).read_bytes()
            verified = verify_glb(raw)
            self.assertEqual(verified["meshes"], 1)
            size = struct.unpack_from("<I", raw, 12)[0]
            doc = json.loads(raw[20:20 + size])
            mesh_nodes = [n for n in doc["nodes"] if "mesh" in n]
            self.assertEqual(len(mesh_nodes), 3)
            manifest = json.loads((output / entry["manifest_path"]).read_text())
            names = {n["name"] for n in doc["nodes"]}
            for owner in manifest["owners"]:
                self.assertIn(owner["id"], names)
                self.assertTrue(set(owner["mesh_nodes"]).issubset(names))
            self.assertTrue(entry["validation"]["glb"]["checked_instance_matrices"])
            self.assertEqual(entry["validation"]["native_collision"]["unique_triangles"], 1)
            self.assertEqual(manifest["native_scope_policy"]["initial_segment_groups"], [2])
            self.assertEqual(manifest["native_scope_policy"]["max_resident_segments"], 2)

    def test_all_actions_keep_separate_groups_but_reuse_source_geometry(self):
        catalog = synthetic_catalog(actions=2)
        level = assemble_level(catalog, 1)
        player = next(o for o in level.owners if o["type"] == 10000)
        self.assertEqual([a["node_name"] for a in player["actions"]],
                         [f"{player['id']}_Action000", f"{player['id']}_Action001"])
        self.assertEqual([i["action"] for i in player["mesh_instances"]], [0, 1])
        self.assertEqual([a["collision_nodes"][0]["collision_mask_a"] for a in player["actions"]], [4097, 2])
        self.assertEqual([a["collision_nodes"][0]["collision_mask_b"] for a in player["actions"]], [8, 4])
        self.assertEqual(player["actions"][0]["collision_nodes"][0]["transform_chain"], [])
        np.testing.assert_allclose(player["actions"][0]["collision_nodes"][0]["bounds"],
                                   [[-0.01, -0.03, -0.02], [0.01, 0.03, 0.02]])
        with tempfile.TemporaryDirectory() as temporary:
            entry = export_level(level, catalog, Path(temporary))
            self.assertEqual(entry["validation"]["glb"]["meshes"], 1)
            self.assertEqual(entry["validation"]["exported_actions"], 2)

    def test_action_names_are_globally_unique_across_owners_and_match_manifest(self):
        catalog = synthetic_catalog(actions=4)
        header = bytearray(148)
        struct.pack_into("<II", header, 8, len(header), 0x80000001)
        struct.pack_into("<II", header, 0x8C, 0, 1000)
        second_actor = Record(5, 1000, 10301, len(header),
                              bytes(header) + graph_bytes([[(0, 0x80000000)]] * 4), 1)
        catalog.scenes[1] = replace(catalog.scenes[1], records=(*catalog.scenes[1].records, second_actor))
        level = assemble_level(catalog, 1)
        actors = [owner for owner in level.owners if owner["actions"]]
        self.assertEqual(len(actors), 2)
        names = [a["node_name"] for owner in actors for a in owner["actions"]]
        self.assertEqual(len(names), 8)
        self.assertEqual(len(set(names)), 8)
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            entry = export_level(level, catalog, output)
            raw = (output / entry["geometry_path"]).read_bytes()
            length = struct.unpack_from("<I", raw, 12)[0]
            doc = json.loads(raw[20:20 + length])
            node_indices = {node["name"]: i for i, node in enumerate(doc["nodes"])}
            self.assertEqual(len(node_indices), len(doc["nodes"]))
            for owner in actors:
                self.assertEqual([a["index"] for a in owner["actions"]], [0, 1, 2, 3])
                for action in owner["actions"]:
                    expected = f"{owner['id']}_Action{action['index']:03d}"
                    self.assertEqual(action["node_name"], expected)
                    self.assertEqual(action["node_path"], owner["id"] + "/" + expected)
                    self.assertIn(node_indices[expected], doc["nodes"][node_indices[owner["id"]]]["children"])
            self.assertTrue(entry["validation"]["glb"]["checked_unique_node_names"])
            self.assertTrue(entry["validation"]["glb"]["checked_action_node_paths"])

    def test_material_batching_keeps_every_color_and_morph_triangle(self):
        catalog = synthetic_catalog()
        mesh = parse_mesh(triangle_record(0, 1))
        first = mesh.parts[0]
        moving = np.stack((first.vertices[0], first.vertices[0] + [0, 0, 5])).astype(np.float32)
        uv_samples = np.repeat(first.uv_bytes, 2, axis=0)
        part_a = replace(first, vertices=moving, uv_bytes=uv_samples)
        part_b = replace(first, index=1, vertices=moving + [100, 0, 0], uv_bytes=uv_samples, colors=first.colors + 1)
        changed = replace(mesh, parts=(part_a, part_b), sample_count=2, timeline_words=(0, 65536))
        raw = export_glb(catalog, [Selection(changed, "synthetic", np.zeros(3), np.eye(3))], include_samples=True)
        doc, _, mapping, report = _batch_geometry(raw)
        self.assertEqual(mapping, {0: [0]})
        self.assertEqual((report["source_surfaces"], report["exported_surfaces"]), (2, 1))
        self.assertEqual(report["source_triangles"], report["exported_triangles"])
        self.assertTrue(report["checked_every_morph_triangle_attribute"])
        merged = doc["meshes"][0]["primitives"][0]
        self.assertEqual(merged["extras"]["source_submesh_indices"], [0, 1])
        self.assertEqual(doc["accessors"][merged["targets"][0]["POSITION"]]["count"], 6)

    def test_surface_limit_splits_a_mesh_without_losing_triangles(self):
        catalog = synthetic_catalog()
        mesh = parse_mesh(triangle_record(0, 1))
        many = replace(mesh, parts=tuple(replace(mesh.parts[0], index=i) for i in range(129)))
        raw = export_glb(catalog, [Selection(many, "synthetic", np.zeros(3), np.eye(3))])
        length = struct.unpack_from("<I", raw, 12)[0]
        doc = json.loads(raw[20:20 + length])
        for i, material in enumerate(doc["materials"]):
            material["pbrMetallicRoughness"]["baseColorFactor"][0] = i / 129
        encoded = json.dumps(doc, separators=(",", ":")).encode()
        encoded += b" " * (-len(encoded) % 4)
        binary = raw[28 + length:]
        rebuilt = (struct.pack("<4sII", b"glTF", 2, 28 + len(encoded) + len(binary))
                   + struct.pack("<II", len(encoded), 0x4e4f534a) + encoded
                   + struct.pack("<II", len(binary), 0x004e4942) + binary)
        doc, _, mapping, report = _batch_geometry(rebuilt)
        self.assertEqual(mapping, {0: [0, 1]})
        self.assertEqual([len(m["primitives"]) for m in doc["meshes"]], [128, 1])
        self.assertEqual(report["source_triangles"], 129)
        self.assertEqual(report["exported_triangles"], 129)

    def test_failed_campaign_does_not_publish_partial_levels(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            sentinel = output / "existing.glb"
            sentinel.write_bytes(b"keep")
            with patch("hugo_assets.levels.PLAYABLE_MAIN_GROUPS", (1, 999)):
                with self.assertRaises(FormatError):
                    export_campaign(synthetic_catalog(), output)
            self.assertEqual(sentinel.read_bytes(), b"keep")
            self.assertFalse((output / "levels").exists())
            self.assertFalse((output / "campaign.json").exists())
            self.assertEqual(list(output.iterdir()), [sentinel])

    def test_existing_campaign_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            (output / "campaign.json").write_text("keep")
            with self.assertRaisesRegex(FormatError, "already exists"):
                export_campaign(synthetic_catalog(), output)
            self.assertEqual((output / "campaign.json").read_text(), "keep")

    def test_absent_source_collision_tree_does_not_become_render_collision(self):
        catalog = synthetic_catalog()
        original = catalog.scenes[1].records[0]
        data = bytearray(original.data[:196])
        struct.pack_into("<I", data, 52, 0)
        records = (replace(original, data=bytes(data)), *catalog.scenes[1].records[1:])
        catalog.scenes[1] = replace(catalog.scenes[1], records=records)
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            entry = export_level(assemble_level(catalog, 1), catalog, output)
            manifest = json.loads((output / entry["manifest_path"]).read_text())
            segment = next(o for o in manifest["owners"] if o["type"] == 10400)
            self.assertIsNone(segment["collision_mesh_key"])
            self.assertEqual(segment["collision_geometry"], "none_in_source")
            self.assertEqual(entry["validation"]["native_collision"]["render_triangle_fallbacks"], 0)


class CollisionTests(unittest.TestCase):
    def test_native_leaf_selects_source_faces_and_preserves_surface_id(self):
        collision = parse_collision_mesh(triangle_record(0, 1))
        self.assertEqual((len(collision.nodes), collision.leaf_count, len(collision.triangles)), (1, 1, 1))
        triangle = collision.triangles[0]
        self.assertEqual((triangle.submesh, triangle.triangle, triangle.surface_type), (0, 0, 5))
        np.testing.assert_equal(triangle.vertices, [[0, 0, 0], [10, 0, 0], [0, 10, 0]])

    def test_corrupt_native_tree_and_face_indices_are_rejected(self):
        original = triangle_record(0, 1)
        for offset, fmt, value in ((196 + 16, "<I", 196), (244, "<I", 117),
                                    (252, "<H", 1), (248, "<I", 0xfffffff0)):
            data = bytearray(original.data)
            struct.pack_into(fmt, data, offset, value)
            with self.subTest(offset=offset), self.assertRaises(FormatError):
                parse_collision_mesh(replace(original, data=bytes(data)))


if __name__ == "__main__":
    unittest.main()
