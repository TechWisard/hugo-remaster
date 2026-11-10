#!/usr/bin/env python3
"""Finish verified open shells after the shared, immutable geometry bake.

This is a scoped final stage, not a second broad remesher. It reads the base
index and its exact numerical resources, copies unchanged resources verbatim
to a separate directory and closes the proven lantern roof and foliage sheets.
The importer already preserves summary.postprocess_chain and pipeline_sha256.
Run import_geometry_quality.gd with this stage's output index afterwards.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct

import numpy as np

from build_geometry_quality import (GLB, source_surfaces, write_geometry, node_matrices,
                                    owner_bindings, exterior_edges, collision_catalog, material_aliases)
from hugo_assets.closed_shell_geometry import close_formed_canopy
from hugo_assets.boundary_geometry import verified_boundary
from hugo_assets.boundary_material_geometry import map_rock_bank
from hugo_assets.geometry_quality import refine_mesh


STAGE = "verified_open_shell_completion_v3"
SOURCE_SCENE = "levels/g027.glb"
SOURCE_MESH = "mg028_r0008"
SOURCE_GROUP, SOURCE_RECORD = 28, 8


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def safe_file(base: Path, relative: str) -> Path:
    path = (base / relative).resolve()
    if not relative or not path.is_relative_to(base.resolve()) or not path.is_file():
        raise ValueError(f"Invalid numerical input path: {relative}")
    return path


def read_geometry(path: Path):
    raw = path.read_bytes()
    if raw[:8] != b"HUGOGEO1":
        raise ValueError("Not a numerical geometry resource")
    size = struct.unpack_from("<I", raw, 8)[0]
    header = json.loads(raw[12:12+size])
    binary = 12+size

    def array(row):
        if row is None:
            return None
        count = int(np.prod(row["shape"]))
        offset = binary+int(row["offset"])
        if offset < binary or offset+count*4 > len(raw):
            raise ValueError("Numerical array extends beyond its resource")
        return np.frombuffer(raw, "<"+row["type"], count=count, offset=offset).reshape(row["shape"]).copy()

    surfaces = []
    for row in header["surfaces"]:
        surface = {key: array(row.get(key)) for key in
                   ("positions", "normals", "colors", "indices", "source_ids", "source_weights", "uv", "uv2")}
        surface.update({key: row.get(key) for key in ("part_index", "native_material_key", "source_vertex_count")})
        surface["lod_indices"] = {float(key): array(value) for key, value in row.get("lods", {}).items()}
        surface["collision_mask"] = np.zeros(len(surface["indices"]), bool)
        surface["collision_surface_types"] = np.full(len(surface["indices"]), -1, np.int32)
        surfaces.append(surface)
    collision = {"faces": array(header["collision_faces"]).reshape(-1, 3, 3),
                 "types": array(header["collision_surface_types"]).tolist()}
    return header, surfaces, collision


def summarise(index):
    summary = index.setdefault("summary", {})
    resources = index["resources"]
    summary.update(resources=len(resources),
                   source_triangles=sum(v["source_triangles"] for v in resources.values()),
                   rebuilt_triangles=sum(v["triangles"] for v in resources.values()),
                   bytes=sum(v["bytes"] for v in resources.values()))
    for key in ("numerical_pose_bytes", "numerical_attribute_bytes", "numerical_provenance_bytes",
                "numerical_index_lod_bytes", "collision_numerical_bytes"):
        summary[key] = sum(v.get(key, 0) for v in resources.values())
    summary["largest_twenty_resources"] = [
        {"path": name, "source_group": value.get("source_group"), "source_record": value.get("source_record"),
         "triangles": value["triangles"], "vertices": value["vertices"], "poses": value["pose_count"],
         "hgm_bytes": value["bytes"], "lod_triangle_counts": value.get("lod_triangle_counts", [])}
        for name, value in sorted(resources.items(), key=lambda item: item[1]["triangles"], reverse=True)[:20]]


def cutout_shell_defects(surfaces, metadata):
    """Audit actual appended index topology, excluding native alpha cards.

    Coordinate welding would hide failures or merge nearby independent sheets.
    Every edge of each closed appended shell must have exactly two incidences.
    The selector is derived afresh from immutable arrays, not a private report.
    """
    defects = []
    for surface, detail in enumerate(metadata.get("cutout_geometry", [])):
        count = int(detail.get("added_triangles", 0))
        if not detail.get("applied") or not count:
            continue
        faces = np.asarray(surfaces[surface]["indices"])[-count:]
        edges = np.sort(np.concatenate((faces[:, [0, 1]], faces[:, [1, 2]], faces[:, [2, 0]])), axis=1)
        _, incidence = np.unique(edges, axis=0, return_counts=True)
        bad = int(np.count_nonzero(incidence != 2))
        degenerate = int(np.count_nonzero(np.any(np.diff(np.sort(faces, axis=1), axis=1) == 0, axis=1)))
        if bad or degenerate:
            defects.append({"surface": surface, "source_texture_key": detail.get("source_texture_key", ""),
                            "shell_triangles": count, "bad_edges": bad, "degenerate_faces": degenerate})
    return defects


def base_fingerprint(index, surfaces, contexts, collision, closure):
    """Reproduce the frozen builder's input fingerprint before scoped work.

    This verifies that context reconstruction matches the actual immutable
    bake, including transforms, boundary classification and native contacts.
    It never rewrites or substitutes the base pipeline hash.
    """
    signature = json.dumps([index["pipeline_sha256"], index["build_options"]], sort_keys=True).encode()
    checksum = hashlib.sha256(signature)

    def add(value):
        if isinstance(value, np.ndarray):
            checksum.update(str((value.shape, value.dtype)).encode())
            checksum.update(value.tobytes())
        elif isinstance(value, dict):
            for key, item in sorted(value.items()):
                checksum.update(str(key).encode())
                add(item)
        elif isinstance(value, (list, tuple)):
            for item in value:
                add(item)
        else:
            checksum.update(json.dumps(value, sort_keys=True).encode()+b"\0")
    for surface, context in zip(surfaces, contexts):
        add(surface)
        add({key: value for key, value in context.items() if key not in
             {"scene_path", "mesh_name", "material", "owner_ids"}})
    if collision is not None:
        add({"faces": collision["faces"], "types": collision["types"]})
    add(closure)
    return checksum.hexdigest()


class ScopedRebuilder:
    def __init__(self, index, generated):
        self.index, self.generated = index, generated
        campaign = json.loads((generated/"campaign.json").read_text())
        self.chapters = {entry["geometry_path"]: entry for entry in campaign["levels"]}
        self.scenes, self.alphas = {}, {}
        self.pack_base = generated.parent/"hd"
        self.pack = json.loads((self.pack_base/"texture_pack.json").read_text())["textures"]

    def scene(self, relative):
        if relative not in self.scenes:
            glb = GLB(self.generated/relative)
            level = json.loads((self.generated/self.chapters[relative]["manifest_path"]).read_text()) if relative in self.chapters else {}
            bindings, transforms = owner_bindings(level), node_matrices(glb.doc)
            self.scenes[relative] = (glb, level, bindings, transforms,
                                     exterior_edges(glb, bindings, transforms) if level else {},
                                     collision_catalog(level))
        return self.scenes[relative]

    def alpha(self, key):
        if key not in self.alphas:
            from PIL import Image
            record = self.pack.get(key, {})
            relative = record.get("path", "")
            path = self.pack_base/relative
            self.alphas[key] = None
            if relative and path.suffix.lower() == ".png" and path.exists():
                recorded = self.index.get("replacement_alpha_inputs", {}).get(key)
                if not recorded or recorded["path"] != relative or recorded["sha256"] != digest(path):
                    raise ValueError("Scoped curved shell requires the same verified authored-alpha input as the base bake")
                with Image.open(path) as image:
                    self.alphas[key] = np.asarray(image.convert("RGBA"))[:, :, 3].copy()
        return self.alphas[key]

    def rebuild(self, resource, record, hook):
        from hugo_assets.semantic_geometry import augment_surface
        candidates = [(key, value) for key, value in self.index["instances"].items() if value["path"] == resource]
        if not candidates:
            raise ValueError("A scoped resource has no native scene binding")
        identity, entry = candidates[0]
        relative, node_name = identity.split("|", 1)
        glb, level, bindings, transforms, boundaries, collisions = self.scene(relative)
        node = next(i for i, value in enumerate(glb.doc["nodes"]) if value.get("name") == node_name)
        mesh_index = glb.doc["nodes"][node]["mesh"]
        mesh = glb.doc["meshes"][mesh_index]
        nodes = [i for i, value in enumerate(glb.doc["nodes"]) if value.get("mesh") == mesh_index]
        terrain = any(bindings.get(glb.doc["nodes"][at].get("name", ""), {}).get("class_name") == "CDefaultSegment" for at in nodes)
        selected = [node] if terrain else nodes
        owners = [bindings.get(glb.doc["nodes"][at].get("name", ""), {}) for at in selected]
        owner_ids = sorted({owner["id"] for owner in owners if "id" in owner})
        classes = sorted({owner["class_name"] for owner in owners if "class_name" in owner}) or (["Hugo"] if relative.startswith("animations/") else [])
        source = mesh.get("extras", {})
        source_key = source.get("source_group", -1), source.get("source_record", -1)
        collision = collisions.get(source_key)
        surfaces, matched = source_surfaces(glb, mesh, collision)
        matrix = transforms[node] if terrain else np.eye(4)
        down = np.linalg.inv(matrix[:3, :3]) @ np.array((0., -1., 0.))
        down /= max(np.linalg.norm(down), 1e-12)
        closure = verified_boundary(level, owners[0], node, boundaries, glb) if terrain and owners else None
        contexts = []
        for surface, primitive in enumerate(mesh["primitives"]):
            material = glb.doc["materials"][primitive["material"]]
            texture = glb.texture(material)
            contexts.append({"scene_path": relative, "mesh_name": mesh["name"],
                "source_group": source_key[0], "source_record": source_key[1], "surface_index": surface,
                "material": material, "source_texture_key": texture["key"], "source_texture_size": texture["size"],
                "source_texture_aliases": material_aliases(material), "source_texture_opaque": texture["opaque"],
                "source_alpha": texture.get("alpha"), "replacement_alpha": self.alpha(texture["key"]) if not texture["opaque"] else None,
                "owner_classes": classes, "owner_ids": owner_ids, "world_matrix": matrix,
                "world_down_local": down if terrain else None,
                "exterior_edges": [edge["vertices"] for edge in boundaries.get((node, surface), [])] if terrain else [],
                "verified_closure": closure})
        if base_fingerprint(self.index, surfaces, contexts, collision, closure) != entry["bake_fingerprint"]:
            raise ValueError(f"Scoped reconstruction differs from the immutable base fingerprint: {identity}")

        def augment(surface, context):
            # Start from the same curved/semantic prefix. The corrected hook
            # builds the requested closed shells once, without retaining a
            # broken old shell underneath a second copy.
            return hook(augment_surface(surface, context), context)

        rebuilt, metadata = refine_mesh(surfaces, contexts, int(self.index["build_options"]["subdivisions"]), augment)
        metadata.update(source_group=source_key[0], source_record=source_key[1], owner_classes=classes,
            source_sha256=source.get("source_sha256", ""), source_bounds=record["source_bounds"],
            semantic_geometry=[surface.get("semantic_geometry", {}) for surface in rebuilt],
            cutout_geometry=[surface.get("cutout_geometry", {}) for surface in rebuilt],
            curved_cutout_geometry=[surface.get("curved_cutout_geometry", {}) for surface in rebuilt],
            permanent_boundary_closures=[closure] if closure else [])
        return mesh, rebuilt, metadata, collision, matched, relative


def complete(input_index: Path, output: Path, generated: Path) -> dict:
    from hugo_assets.curved_cutout_geometry import SOURCE_KEYS, augment_verified_cutout_surface
    repository = Path(__file__).resolve().parents[1]
    input_index, output, generated = input_index.resolve(), output.resolve(), generated.resolve()
    if input_index.parent == output:
        raise ValueError("The final stage must use a separate directory; the base bake is immutable")
    base_digest = digest(input_index)
    original = json.loads(input_index.read_text())
    if original.get("summary", {}).get("postprocess_chain"):
        raise ValueError("Use the immutable base bake as input, not an already finished index")
    if not original.get("summary") or original.get("failures"):
        raise ValueError("The base bake has not completed successfully")
    for relative, expected in original.get("pipeline_sha256", {}).items():
        if digest(safe_file(repository, relative)) != expected:
            raise ValueError(f"Stale base pipeline: {relative}")
    for relative, expected in original.get("source_inputs", {}).items():
        if digest(safe_file(generated, relative)) != expected:
            raise ValueError(f"Stale source input: {relative}")
    for row in original.get("replacement_alpha_inputs", {}).values():
        if digest(safe_file(generated.parent/"hd", row["path"])) != row["sha256"]:
            raise ValueError(f"Stale authored-alpha input: {row['path']}")
    glb = GLB(generated/SOURCE_SCENE)
    mesh = next(value for value in glb.doc["meshes"] if value.get("name") == SOURCE_MESH)
    sources, _ = source_surfaces(glb, mesh, None)
    if len(sources) != 2 or [len(source["indices"]) for source in sources] != [24, 8]:
        raise ValueError("Lantern source topology differs from the verified canopy")
    # Source faces 2..13 form the twelve-triangle canopy, including its top.
    roof_ids = set(int(v) for v in sources[0]["source_ids"][sources[0]["indices"][2:14], 0].ravel())
    final = copy.deepcopy(original)
    output.mkdir(parents=True, exist_ok=True)
    stage_files = [Path(__file__).resolve(), repository/"tools/hugo_assets/closed_shell_geometry.py",
                   repository/"tools/hugo_assets/curved_cutout_geometry.py",
                   repository/"tools/hugo_assets/boundary_material_geometry.py"]
    stage_hashes = {path.relative_to(repository).as_posix(): digest(path) for path in stage_files}
    final["pipeline_sha256"].update(stage_hashes)
    affected, replacements, examined_unchanged, closure_materials = [], {}, [], {}
    rebuilder = ScopedRebuilder(original, generated)

    def copy_original(source_path, target, sha):
        if not target.exists() or digest(target) != sha:
            temporary = target.with_suffix(target.suffix+".tmp")
            shutil.copyfile(source_path, temporary)
            os.replace(temporary, target)
    for name, row in original["resources"].items():
        source_path = safe_file(input_index.parent, row["input"])
        if digest(source_path) != row["sha256"]:
            raise ValueError(f"The base numerical resource changed: {name}")
        canopy = (int(row.get("source_group", -1)), int(row.get("source_record", -1))) == (SOURCE_GROUP, SOURCE_RECORD)
        curved = any(detail.get("source_texture_key") in SOURCE_KEYS and any(
            skipped.get("reason") in {"source_already_nonplanar", "no_opaque_layout"}
            for skipped in detail.get("skipped_reasons", [])) for detail in row.get("cutout_geometry", []))
        boundary = row.get("verified_scene_closure", {}).get("kind") == "beach_west_rock_bank"
        has_shell = any(detail.get("applied") and detail.get("added_triangles", 0)
                        for detail in row.get("cutout_geometry", []))
        target = output/row["input"]
        if not canopy and not curved and not has_shell and not boundary:
            copy_original(source_path, target, row["sha256"])
            continue
        header, surfaces, collision = read_geometry(source_path)
        broken = cutout_shell_defects(surfaces, header["metadata"])
        if not canopy and not curved and not broken and not boundary:
            copy_original(source_path, target, row["sha256"])
            continue
        original_collision = collision
        if boundary:
            scene, node_name = next(key for key, value in original["closures"].items()
                                    if value["path"] == name).split("|", 1)
            bank_glb, _, _, transforms, _, _ = rebuilder.scene(scene)
            node = next(i for i, value in enumerate(bank_glb.doc["nodes"]) if value.get("name") == node_name)
            rock_mesh = next(value for value in bank_glb.doc["meshes"] if value.get("name") == "mg008_r0000")
            rock_surface = next(i for i, primitive in enumerate(rock_mesh["primitives"])
                                if {"group": 6, "texture_id": 286} in material_aliases(bank_glb.doc["materials"][primitive["material"]]))
            rock = bank_glb.texture(bank_glb.doc["materials"][rock_mesh["primitives"][rock_surface]["material"]])
            if not rock["opaque"]:
                raise ValueError("The verified rock bank requires the same opaque Beach cliff material")
            surfaces[0], detail = map_rock_bank(surfaces[0], transforms[node])
            detail.update(source_material_mesh_name=rock_mesh["name"], source_material_surface_index=rock_surface,
                          source_texture_key=rock["key"])
            metadata = copy.deepcopy(header["metadata"])
            metadata["boundary_material_geometry"] = detail
            closure_materials[name] = {"material_source_mesh_name": rock_mesh["name"],
                                      "material_source_surface_index": rock_surface,
                                      "material_source_texture_key": rock["key"],
                                      "texture_repeat": True, "uv_tile_metres": detail["tile_metres"]}
            mesh, matched = {"extras": {"targetNames": header["blend_shape_names"]}}, set()
            evidence = {"kind": "boundary_rock_material_unwrap", "source_scene": scene,
                        "source_mesh": bank_glb.doc["meshes"][bank_glb.doc["nodes"][node]["mesh"]]["name"],
                        "geometry": detail}
        elif canopy:
            surfaces[0], detail = close_formed_canopy(surfaces[0], roof_ids)
            metadata = copy.deepcopy(header["metadata"])
            metadata["closed_shell_geometry"] = [{"surface": 0, **detail}]
            metadata["triangles"] = sum(len(surface["indices"]) for surface in surfaces)
            metadata["vertices"] = sum(surface["positions"].shape[1] for surface in surfaces)
            mesh, matched = {"extras": {"targetNames": header["blend_shape_names"]}}, set()
            evidence = {"kind": "formed_metal_canopy", "source_scene": SOURCE_SCENE,
                        "source_mesh": SOURCE_MESH, "source_faces": list(range(2, 14)), "geometry": detail}
        else:
            mesh, surfaces, metadata, collision, matched, scene = rebuilder.rebuild(name, row, augment_verified_cutout_surface)
            remaining = cutout_shell_defects(surfaces, metadata)
            if remaining:
                raise ValueError(f"Verified shell reconstruction still has nonmanifold edges: {name}: {remaining}")
            evidence = {"kind": "verified_alpha_shell_reconstruction", "source_scene": scene,
                        "source_mesh": mesh["name"], "base_shell_topology_defects": broken,
                        "final_shell_topology_defects": [], "geometry": metadata["curved_cutout_geometry"]}
            if not any(detail.get("applied") for detail in metadata["curved_cutout_geometry"]):
                examined_unchanged.append({"base_resource": name, **evidence})
                copy_original(source_path, target, row["sha256"])
                continue
        updated = write_geometry(target, mesh, surfaces, metadata, collision, matched)
        _, _, final_collision = read_geometry(target)
        if not np.array_equal(original_collision["faces"], final_collision["faces"]) or original_collision["types"] != final_collision["types"]:
            raise ValueError("A decorative shell changed the verified base collision")
        replacement = updated["sha256"][:32]+".res"
        entry = {"input": row["input"], **updated, "postprocess_stage": STAGE,
                 "base_hgm_sha256": row["sha256"]}
        del final["resources"][name]
        final["resources"][replacement] = entry
        replacements[name] = replacement
        affected.append({"base_resource": name, "base_input": row["input"], "base_hgm_sha256": row["sha256"],
                         "resource": replacement, "hgm_sha256": updated["sha256"],
                         "source_group": row["source_group"], "source_record": row["source_record"], **evidence})
        print("GEOMETRY_SHELL_RESOURCE", evidence["source_scene"], evidence["source_mesh"],
              "triangles", row["triangles"], "->", updated["triangles"], flush=True)
    if not affected:
        raise ValueError("The finished input does not contain the verified lantern mesh")
    for collection in ("meshes", "instances", "closures"):
        for entry in final.get(collection, {}).values():
            old = entry.get("path")
            if collection == "closures" and old in closure_materials:
                entry.update(closure_materials[old])
            if old in replacements:
                entry["path"] = replacements[old]
                if "bake_fingerprint" in entry:
                    entry["base_bake_fingerprint"] = entry["bake_fingerprint"]
                    entry["bake_fingerprint"] = hashlib.sha256(json.dumps(
                        [entry["base_bake_fingerprint"], stage_hashes, old, entry["path"]], sort_keys=True).encode()).hexdigest()
    if digest(input_index) != base_digest:
        raise ValueError("The base index changed while the final stage was running")
    summarise(final)
    final["summary"]["postprocess_chain"] = [{"stage": STAGE,
        "input_manifest": input_index.relative_to(repository).as_posix() if input_index.is_relative_to(repository) else str(input_index),
        "input_manifest_sha256": base_digest, "pipeline_sha256": stage_hashes,
        "affected_resources": affected,
        "examined_unchanged_resources": examined_unchanged,
        "unchanged_resources_copied_verbatim": len(original["resources"])-len(affected),
        "base_source_inputs_preserved": True, "base_directory_modified": False}]
    target_index = output/"index.json"
    temporary = target_index.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(final, indent=2, allow_nan=False)+"\n")
    os.replace(temporary, target_index)
    return final


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--generated", type=Path, default=Path("game/assets/generated"))
    args = parser.parse_args()
    result = complete(args.input, args.output, args.generated)
    affected = result["summary"]["postprocess_chain"][0]["affected_resources"]
    print("GEOMETRY_SHELL_COMPLETION", json.dumps({"resources": len(result["resources"]),
          "complete_campaign": result["complete_campaign"],
          "affected_resources": len(affected), "rebuilt_triangles": result["summary"]["rebuilt_triangles"],
          "index": str(args.output/"index.json")}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
