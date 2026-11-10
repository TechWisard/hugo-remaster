#!/usr/bin/env python3
"""Bake curved/morph-preserving geometry from the user's imported GLBs.

The intermediate output is private numerical geometry, not a replacement game
download. Run game/tools/import_geometry_quality.gd afterwards to make native
ArrayMesh resources. Original models and collision metadata are never edited.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import hashlib
import io
import json
from pathlib import Path
import re
import struct
import sys

import numpy as np
from PIL import Image

from hugo_assets.geometry_quality import refine_mesh
from hugo_assets.boundary_geometry import verified_boundary, build_boundary_surface


COMPONENTS = {5120: "i1", 5121: "u1", 5122: "<i2", 5123: "<u2", 5125: "<u4", 5126: "<f4"}
WIDTHS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


class GLB:
    def __init__(self, path: Path):
        self.path = path
        raw = path.read_bytes()
        if struct.unpack_from("<III", raw) != (0x46546C67, 2, len(raw)):
            raise ValueError(f"Invalid GLB: {path.name}")
        size, kind = struct.unpack_from("<II", raw, 12)
        if kind != 0x4E4F534A:
            raise ValueError("GLB JSON chunk missing")
        self.doc = json.loads(raw[20:20+size])
        at = 20 + size
        binary_size, kind = struct.unpack_from("<II", raw, at)
        if kind != 0x004E4942:
            raise ValueError("GLB binary chunk missing")
        self.binary = raw[at+8:at+8+binary_size]
        self._arrays = {}
        self._images = {}

    def accessor(self, index: int) -> np.ndarray:
        if index in self._arrays:
            return self._arrays[index]
        accessor = self.doc["accessors"][index]
        if "sparse" in accessor:
            raise ValueError("Sparse accessors need explicit expansion before quality baking")
        view = self.doc["bufferViews"][accessor["bufferView"]]
        dtype = np.dtype(COMPONENTS[accessor["componentType"]])
        width, count = WIDTHS[accessor["type"]], accessor["count"]
        offset = view.get("byteOffset", 0) + accessor.get("byteOffset", 0)
        stride = view.get("byteStride", width * dtype.itemsize)
        value = np.ndarray((count, width), dtype=dtype, buffer=self.binary, offset=offset,
                           strides=(stride, dtype.itemsize)).copy()
        if accessor.get("normalized") and dtype.kind in "iu":
            value = np.maximum(value.astype(np.float64) / np.iinfo(dtype).max, -1.0)
        self._arrays[index] = value
        return value

    def texture(self, material: dict) -> dict:
        texture = material.get("pbrMetallicRoughness", {}).get("baseColorTexture", {}).get("index")
        if texture is None:
            return {"key": "", "size": [0, 0], "opaque": True, "alpha": None}
        index = self.doc["textures"][texture]["source"]
        if index not in self._images:
            descriptor = self.doc["images"][index]
            view = self.doc["bufferViews"][descriptor["bufferView"]]
            at = view.get("byteOffset", 0)
            with Image.open(io.BytesIO(self.binary[at:at + view["byteLength"]])) as image:
                rgba = np.asarray(image.convert("RGBA"))
            digest = hashlib.sha256(rgba.tobytes()).hexdigest()
            self._images[index] = {"key": f"{rgba.shape[1]}x{rgba.shape[0]}:{digest}",
                                   "size": [rgba.shape[1], rgba.shape[0]],
                                   "opaque": bool((rgba[:, :, 3] == 255).all()),
                                   "alpha": rgba[:, :, 3].copy()}
        return self._images[index]


def face_key(points: np.ndarray) -> tuple:
    return tuple(sorted(tuple(float(v) for v in row) for row in np.round(points, 4)))


def collision_catalog(level: dict) -> dict:
    result = {}
    for value in level.get("native_collision_meshes", {}).values():
        faces = np.asarray(value.get("faces", []), dtype=np.float64).reshape(-1, 3, 3)
        types = list(value.get("surface_types", []))
        extra = value.get("remaster_collision", {})
        if extra.get("policy") in {"authored_static_opaque_triangles_only", "authored_opaque_triangles_with_verified_animated_solids"}:
            faces = np.concatenate((faces, np.asarray(extra.get("faces", []), dtype=np.float64).reshape(-1, 3, 3)))
            types.extend(extra.get("surface_types", []))
        entries = {face_key(triangle): (index, int(types[index])) for index, triangle in enumerate(faces)}
        result[value["source_group"], value["source_record"]] = {"faces": faces, "types": types, "entries": entries}
    return result


def node_matrices(doc: dict) -> dict[int, np.ndarray]:
    parents = {child: index for index, node in enumerate(doc.get("nodes", [])) for child in node.get("children", [])}
    cache = {}

    def matrix(index):
        if index in cache:
            return cache[index]
        node = doc["nodes"][index]
        if "matrix" in node:
            local = np.asarray(node["matrix"], dtype=np.float64).reshape(4, 4).T
        else:
            local = np.eye(4)
            x, y, z, w = node.get("rotation", (0, 0, 0, 1))
            local[:3, :3] = [[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
                            [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
                            [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]]
            local[:3, :3] *= np.asarray(node.get("scale", (1, 1, 1)))[None, :]
            local[:3, 3] = node.get("translation", (0, 0, 0))
        cache[index] = matrix(parents[index]) @ local if index in parents else local
        return cache[index]

    for index in range(len(doc.get("nodes", []))):
        matrix(index)
    return cache


def source_surfaces(glb: GLB, mesh: dict, collision: dict | None) -> tuple[list[dict], set[int]]:
    pose_count = max((len(p.get("targets", [])) for p in mesh["primitives"]), default=0) + 1
    surfaces, matched_collision = [], set()
    for index, primitive in enumerate(mesh["primitives"]):
        if primitive.get("mode", 4) != 4:
            raise ValueError("Only explicitly triangulated source primitives can be reconstructed")
        attributes = primitive["attributes"]
        base = glb.accessor(attributes["POSITION"]).astype(np.float64)
        poses = [base]
        for pose in range(pose_count - 1):
            target = primitive.get("targets", [])[pose] if pose < len(primitive.get("targets", [])) else {}
            poses.append(base + glb.accessor(target["POSITION"]) if "POSITION" in target else base.copy())
        faces = (glb.accessor(primitive["indices"]).reshape(-1, 3) if "indices" in primitive
                 else np.arange(len(base)).reshape(-1, 3)).astype(np.uint32)
        uv = glb.accessor(attributes["TEXCOORD_0"]).astype(np.float32) if "TEXCOORD_0" in attributes else None
        uv2 = glb.accessor(attributes["TEXCOORD_1"]).astype(np.float32) if "TEXCOORD_1" in attributes else None
        colors = glb.accessor(attributes["COLOR_0"]).astype(np.float32) if "COLOR_0" in attributes else np.ones((len(base), 4), dtype=np.float32)
        if colors.shape[1] == 3:
            colors = np.column_stack((colors, np.ones(len(base), dtype=np.float32)))
        native_ids = np.rint(uv2[:, 0]).astype(np.int32) if uv2 is not None else np.arange(len(base), dtype=np.int32)
        ids = np.column_stack((native_ids, native_ids, native_ids))
        weights = np.tile(np.array((1, 0, 0), dtype=np.float32), (len(base), 1))
        solid = np.zeros(len(faces), dtype=bool)
        surface_types = np.full(len(faces), -1, dtype=np.int32)
        if collision:
            for face, vertices in enumerate(base[faces]):
                found = collision["entries"].get(face_key(vertices))
                if found is not None:
                    matched_collision.add(found[0])
                    solid[face], surface_types[face] = True, found[1]
        material = glb.doc.get("materials", [])[primitive.get("material", 0)]
        name = material.get("name", "")
        animation_key = name.split("__hugo_anim_", 1)[1].split("__hugo_blend_", 1)[0] if "__hugo_anim_" in name else ""
        surfaces.append({"positions": np.asarray(poses, dtype=np.float32), "normals": np.zeros((pose_count, len(base), 3), dtype=np.float32),
                         "uv": uv, "uv2": uv2, "colors": colors, "source_ids": ids,
                         "source_weights": weights, "indices": faces,
                         "triangle_origin": np.column_stack((np.full(len(faces), index), np.arange(len(faces)))).astype(np.int32),
                         "collision_mask": solid, "collision_surface_types": surface_types,
                         "lod_indices": {}, "part_index": int(round(float(uv2[0, 1]))) if uv2 is not None else -1,
                         "native_material_key": animation_key})
    return surfaces, matched_collision


def write_geometry(path: Path, mesh: dict, surfaces: list[dict], metadata: dict,
                   collision: dict | None, matched_collision: set[int]) -> dict:
    data = bytearray()

    def array(value, kind="f4"):
        value = np.asarray(value, dtype="<" + kind)
        data.extend(b"\0" * (-len(data) % 4))
        record = {"offset": len(data), "shape": list(value.shape), "type": kind}
        data.extend(value.tobytes())
        return record

    output = []
    solid_faces, solid_types = [], []
    for surface in surfaces:
        row = {"positions": array(surface["positions"]), "normals": array(surface["normals"]),
               "colors": array(surface["colors"]), "indices": array(surface["indices"], "i4"),
               "source_ids": array(surface["source_ids"], "i4"),
               "source_weights": array(surface["source_weights"]),
               "part_index": int(surface.get("part_index", -1)),
               "native_material_key": str(surface.get("native_material_key", "")),
               "source_vertex_count": int(surface.get("source_vertex_count", 0)),
               "lods": {str(distance): array(indices, "i4") for distance, indices in surface.get("lod_indices", {}).items()}}
        for name in ("uv", "uv2"):
            row[name] = array(surface[name]) if surface.get(name) is not None else None
        output.append(row)
        selected = surface["indices"][np.asarray(surface["collision_mask"], dtype=bool)]
        if len(selected):
            solid_faces.append(surface["positions"][0, selected].reshape(-1, 3))
            solid_types.extend(np.asarray(surface["collision_surface_types"])[surface["collision_mask"]].tolist())
    unmatched = []
    if collision:
        unmatched = [i for i in range(len(collision["faces"])) if i not in matched_collision]
        if unmatched:
            solid_faces.append(collision["faces"][unmatched].reshape(-1, 3))
            solid_types.extend(collision["types"][i] for i in unmatched)
    poses = surfaces[0]["positions"].shape[0]
    names = mesh.get("extras", {}).get("targetNames", [f"sample_{i:03d}" for i in range(1, poses)])
    if len(names) != poses - 1:
        raise ValueError("Morph target names do not match geometry samples")
    # A native record can occur in many clips/owners. Resource identity follows
    # its exact rebuilt arrays and role, not a GLB's incidental node label.
    stable_name = f"g{int(metadata.get('source_group', -1)):03d}_r{int(metadata.get('source_record', -1)):04d}"
    header = {"schema_version": 1, "mesh_name": stable_name, "pose_count": poses,
              "blend_shape_names": names, "surfaces": output, "metadata": metadata,
              "collision_faces": array(np.concatenate(solid_faces) if solid_faces else np.empty((0, 3))),
              "collision_surface_types": array(solid_types, "i4"),
              "unmatched_native_collision_triangles_preserved": len(unmatched)}
    encoded = json.dumps(header, separators=(",", ":"), allow_nan=False).encode()
    encoded += b" " * (-len(encoded) % 4)
    blob = b"HUGOGEO1" + struct.pack("<I", len(encoded)) + encoded + data
    digest = hashlib.sha256(blob).hexdigest()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(blob)
    return {"sha256": digest, "bytes": len(blob), "pose_count": poses,
            "surface_count": len(surfaces), "collision_triangles": len(solid_types),
            "numerical_pose_bytes": sum((s["positions"].size+s["normals"].size)*4 for s in surfaces),
            "numerical_attribute_bytes": sum(sum(np.asarray(s[k]).size*4 for k in ("colors","uv","uv2") if s.get(k) is not None) for s in surfaces),
            "numerical_provenance_bytes": sum((s["source_ids"].size+s["source_weights"].size)*4 for s in surfaces),
            "numerical_index_lod_bytes": sum(s["indices"].size*4+sum(np.asarray(v).size*4 for v in s.get("lod_indices",{}).values()) for s in surfaces),
            "lod_triangle_counts": [{str(error):len(faces) for error,faces in sorted(s.get("lod_indices",{}).items())} for s in surfaces],
            "collision_numerical_bytes": len(solid_types)*40, **metadata}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generated", type=Path, default=Path("game/assets/generated"))
    parser.add_argument("--output", type=Path, default=Path(".work/geometry_quality"))
    parser.add_argument("--subdivisions", type=int, choices=(2, 3, 4, 6), default=4)
    parser.add_argument("--scene", action="append", help="Limit a development bake to these relative GLB paths")
    parser.add_argument("--mesh", action="append", help="Limit a development bake to these mesh names")
    parser.add_argument("--without-semantics", action="store_true", help="Geometry-only diagnostic; never a complete volume-remaster claim")
    parser.add_argument("--resume", action="store_true", help="Reuse only exact matching input/pipeline/alpha fingerprints from this output directory")
    args = parser.parse_args()
    return build(args)


def material_aliases(material: dict) -> list[dict]:
    records = [material.get("extras", {})]
    records.extend(records[0].get("source_materials", []))
    pairs = {(int(item["source_texture_group"]), int(item["source_texture_id"]))
             for item in records if "source_texture_group" in item and "source_texture_id" in item}
    return [{"group": group, "texture_id": texture} for group, texture in sorted(pairs)]


def owner_bindings(level: dict) -> dict[str, dict]:
    return {str(mesh["name"]): owner for owner in level.get("owners", [])
            for mesh in owner.get("mesh_instances", [])}


def exterior_edges(glb: GLB, bindings: dict, transforms: dict) -> dict:
    """Classify edges across the whole static chapter in WORLD coordinates.

    A material split or neighbouring terrain segment is not an outside border.
    Returned indices still address each primitive's original local vertices.
    """
    uses = defaultdict(list)
    for node_index, node in enumerate(glb.doc.get("nodes", [])):
        if "mesh" not in node or bindings.get(node.get("name", ""), {}).get("class_name") != "CDefaultSegment":
            continue
        matrix = transforms[node_index]
        for surface, primitive in enumerate(glb.doc["meshes"][node["mesh"]]["primitives"]):
            points = glb.accessor(primitive["attributes"]["POSITION"])
            world = points @ matrix[:3, :3].T + matrix[:3, 3]
            faces = glb.accessor(primitive["indices"]).reshape(-1, 3)
            for face, triangle in enumerate(faces):
                for side in range(3):
                    a, b = int(triangle[side]), int(triangle[(side+1) % 3])
                    key = tuple(sorted((tuple(np.round(world[a], 4)), tuple(np.round(world[b], 4)))))
                    if key[0] != key[1]:
                        uses[key].append((node_index, surface, a, b, face, world[[a, b]].copy()))
    result = defaultdict(list)
    for values in uses.values():
        if len(values) == 1:
            node, surface, a, b, face, world = values[0]
            result[node, surface].append({"vertices": [a, b], "face": face, "world": world})
    return dict(result)


def build(args) -> int:
    generated = args.generated.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    previous = json.loads((output/"index.json").read_text()) if getattr(args,"resume",False) and (output/"index.json").exists() else {}
    campaign = json.loads((generated / "campaign.json").read_text())
    animation = json.loads((generated / "animation_manifest.json").read_text())
    chapter_paths = {entry["geometry_path"]: entry for entry in campaign["levels"]}
    paths = list(chapter_paths) + [path for path in animation["files"] if path.endswith(".glb")]
    if args.scene:
        paths = [path for path in paths if path in args.scene]
    if not paths:
        raise ValueError("No matching imported scene")
    semantic = None
    cutout = None
    if not args.without_semantics:
        from hugo_assets.semantic_geometry import augment_surface
        semantic = augment_surface
        try:
            from hugo_assets.cutout_geometry import augment_cutout_surface
        except ModuleNotFoundError as error:
            if error.name != "hugo_assets.cutout_geometry":
                raise
        else:
            cutout = augment_cutout_surface
    pack_base = generated.parent / "hd"
    pack_path = pack_base / "texture_pack.json"
    pack = json.loads(pack_path.read_text()).get("textures", {}) if pack_path.exists() else {}
    authored_alpha = {}
    alpha_inputs = {}

    def replacement_alpha(key):
        if key not in authored_alpha:
            authored_alpha[key] = None
            relative = pack.get(key, {}).get("path", "")
            path = (pack_base / relative).resolve()
            if relative and path.is_relative_to(pack_base.resolve()) and path.suffix.lower() == ".png" and path.exists():
                with Image.open(path) as image:
                    authored_alpha[key] = np.asarray(image.convert("RGBA"))[:, :, 3].copy()
                alpha_inputs[key] = {"path": relative, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
        return authored_alpha[key]

    index = {"schema_version": 1, "complete_campaign": not args.scene and not args.mesh,
             "semantic_stage_enabled": semantic is not None, "cutout_stage_enabled": cutout is not None,
             "meshes": {}, "instances": {}, "closures": {}, "resources": {}, "failures": [],
             "source_inputs": {}, "replacement_alpha_inputs": alpha_inputs,
             "build_options": {"subdivisions": args.subdivisions, "without_semantics": args.without_semantics},
             "pipeline_sha256": {}}
    repository = Path(__file__).resolve().parents[1]
    pipeline_files = [Path(__file__).resolve(), repository / "game/tools/import_geometry_quality.gd", *[repository / "tools/hugo_assets" / name for name in
                     ("geometry_quality.py", "bevel_geometry.py", "aircraft_geometry.py", "face_geometry.py", "boundary_geometry.py",
                      "semantic_geometry.py", "cutout_geometry.py")]]
    for path in pipeline_files:
        if path.exists():
            index["pipeline_sha256"][str(path.relative_to(repository))] = hashlib.sha256(path.read_bytes()).hexdigest()
    cached_bakes = {}
    for identity, entry in {**previous.get("meshes",{}), **previous.get("instances",{})}.items():
        resource = previous.get("resources",{}).get(entry.get("path"),{})
        closure = previous.get("closures",{}).get(identity)
        repair = previous.get("resources",{}).get(closure.get("path"),{}) if closure else None
        if entry.get("bake_fingerprint") and resource and (output/resource.get("input","")).is_file():
            if closure and (not repair or not (output/repair.get("input","")).is_file()):
                continue
            cached_bakes[entry["bake_fingerprint"]] = (entry,resource,closure,repair)
    verified_files = set()
    reused = 0
    pipeline_signature = json.dumps([index["pipeline_sha256"],index["build_options"]],sort_keys=True).encode()

    def fingerprint(surfaces,contexts,collision,closure):
        digest=hashlib.sha256(pipeline_signature)
        def add(value):
            if isinstance(value,np.ndarray):
                digest.update(str((value.shape,value.dtype)).encode());digest.update(value.tobytes())
            elif isinstance(value,dict):
                for key,item in sorted(value.items()):
                    digest.update(str(key).encode());add(item)
            elif isinstance(value,(list,tuple)):
                for item in value:add(item)
            else:digest.update(json.dumps(value,sort_keys=True).encode()+b"\0")
        for surface,context in zip(surfaces,contexts):
            add(surface)
            add({key:value for key,value in context.items() if key not in
                 {"scene_path","mesh_name","material","owner_ids"}})
        if collision is not None:add({"faces":collision["faces"],"types":collision["types"]})
        add(closure)
        return digest.hexdigest()

    def valid_cached(record):
        for resource in (record[1],record[3]):
            if resource is None:continue
            name=resource["input"]
            if name in verified_files:continue
            if hashlib.sha256((output/name).read_bytes()).hexdigest()!=resource["sha256"]:
                return False
            verified_files.add(name)
        return True
    def input_hash(relative):
        index["source_inputs"][relative] = hashlib.sha256((generated / relative).read_bytes()).hexdigest()
    for relative in ("campaign.json", "animation_manifest.json", "material_animation_manifest.json"):
        if (generated / relative).exists(): input_hash(relative)
    for relative in paths:
        input_hash(relative)
        glb = GLB(generated / relative)
        level = json.loads((generated / chapter_paths[relative]["manifest_path"]).read_text()) if relative in chapter_paths else {}
        if relative in chapter_paths:
            input_hash(chapter_paths[relative]["manifest_path"])
        bindings = owner_bindings(level)
        transforms = node_matrices(glb.doc)
        boundaries = exterior_edges(glb, bindings, transforms) if level else {}
        collisions = collision_catalog(level)
        usages = defaultdict(list)
        for node, item in enumerate(glb.doc.get("nodes", [])):
            if "mesh" in item:
                usages[item["mesh"]].append(node)
        for mesh_index, mesh in enumerate(glb.doc["meshes"]):
            name = mesh.get("name", f"mesh_{mesh_index}")
            if args.mesh and name not in args.mesh:
                continue
            source = mesh.get("extras", {})
            source_key = (source.get("source_group", -1), source.get("source_record", -1))
            source_collision = collisions.get(source_key)
            surfaces, matched = source_surfaces(glb, mesh, source_collision)
            nodes = usages.get(mesh_index, [])
            terrain = any(bindings.get(glb.doc["nodes"][node].get("name", ""), {}).get("class_name") == "CDefaultSegment" for node in nodes)
            variants = nodes if terrain else [None]
            for node in variants:
                selected_nodes = [node] if node is not None else nodes
                owners = [bindings.get(glb.doc["nodes"][at].get("name", ""), {}) for at in selected_nodes]
                owner_ids = sorted({owner["id"] for owner in owners if "id" in owner})
                classes = sorted({owner["class_name"] for owner in owners if "class_name" in owner}) or (["Hugo"] if relative.startswith("animations/") else [])
                matrix = transforms[node] if node is not None else np.eye(4)
                down = np.linalg.inv(matrix[:3, :3]) @ np.array((0., -1., 0.))
                down /= max(np.linalg.norm(down), 1e-12)
                closure = verified_boundary(level, owners[0], node, boundaries, glb) if node is not None and owners else None
                contexts = []
                for surface, primitive in enumerate(mesh["primitives"]):
                    material = glb.doc["materials"][primitive["material"]]
                    texture = glb.texture(material)
                    contexts.append({"scene_path": relative, "mesh_name": name,
                                     "source_group": source_key[0], "source_record": source_key[1],
                                     "surface_index": surface, "material": material,
                                     "source_texture_key": texture["key"], "source_texture_size": texture["size"],
                                     "source_texture_aliases": material_aliases(material),
                                     "source_texture_opaque": texture["opaque"], "source_alpha": texture.get("alpha"),
                                     "replacement_alpha": replacement_alpha(texture["key"]) if not texture["opaque"] and cutout is not None else None,
                                     "owner_classes": classes,
                                     "owner_ids": owner_ids, "world_matrix": matrix,
                                     "world_down_local": down if terrain else None,
                                     "exterior_edges": [edge["vertices"] for edge in boundaries.get((node, surface), [])],
                                     "verified_closure": closure})

                def augment(surface, context):
                    if semantic is not None:
                        surface = semantic(surface, context)
                    if cutout is not None:
                        surface = cutout(surface, context)
                    return surface

                signature=fingerprint(surfaces,contexts,source_collision,closure)
                found=cached_bakes.get(signature)
                if found is not None and valid_cached(found):
                    entry,details,repair_entry,repair_details=found
                    index["resources"][entry["path"]]=details
                    index["meshes"].setdefault(relative+"|"+name,entry)
                    for used_node in selected_nodes:
                        identity=relative+"|"+glb.doc["nodes"][used_node]["name"]
                        index["instances"][identity]=entry
                        if repair_entry is not None:
                            index["closures"][identity]=repair_entry
                            index["resources"][repair_entry["path"]]=repair_details
                    reused+=1
                    print("GEOMETRY_REUSE",relative+"|"+name,flush=True)
                    continue
                rebuilt, metadata = refine_mesh(surfaces, contexts, args.subdivisions, augment)
                metadata.update(source_group=source_key[0], source_record=source_key[1], owner_classes=classes,
                                source_sha256=source.get("source_sha256", ""),
                                source_bounds=[np.concatenate([s["positions"][0] for s in surfaces]).min(axis=0).tolist(),
                                               np.concatenate([s["positions"][0] for s in surfaces]).max(axis=0).tolist()],
                                semantic_geometry=[s.get("semantic_geometry", {}) for s in rebuilt],
                                cutout_geometry=[s.get("cutout_geometry", {}) for s in rebuilt],
                                permanent_boundary_closures=[closure] if closure else [])
                identity = relative + "|" + (glb.doc["nodes"][node]["name"] if node is not None else name)
                filename = hashlib.sha256(identity.encode()).hexdigest()[:24] + ".hgm"
                details = write_geometry(output / filename, mesh, rebuilt, metadata, source_collision, matched)
                resource = details["sha256"][:32] + ".res"
                index["resources"][resource] = {"input": filename, **details}
                entry = {"path": resource, "source_mesh_name": name, "source_surface_count": len(surfaces),
                         "bake_fingerprint": signature,
                         "source_pose_count": surfaces[0]["positions"].shape[0],
                         "source_index_counts": [len(s["indices"]) * 3 for s in surfaces],
                         "source_bounds": metadata["source_bounds"], "source_record": source_key[1], "source_group": source_key[0]}
                index["meshes"].setdefault(relative + "|" + name, entry)
                for used_node in selected_nodes:
                    index["instances"][relative + "|" + glb.doc["nodes"][used_node]["name"]] = entry
                repair_entry,repair_details=None,None
                if closure is not None:
                    repair = build_boundary_surface(closure, surfaces[closure["surface"]], matrix)
                    repair_metadata = {"source_group": source_key[0], "source_record": source_key[1],
                                       "source_triangles": 0, "triangles": len(repair["indices"]),
                                       "vertices": repair["positions"].shape[1],
                                       "source_vertices": 0, "method": "permanent_visible_boundary_completion",
                                       "verified_scene_closure": repair["verified_scene_closure"]}
                    repair_filename = hashlib.sha256((identity+"|boundary").encode()).hexdigest()[:24]+".hgm"
                    repair_details = write_geometry(output / repair_filename, {"extras": {}}, [repair], repair_metadata, None, set())
                    repair_resource = repair_details["sha256"][:32]+".res"
                    index["resources"][repair_resource] = {"input": repair_filename, **repair_details}
                    repair_details=index["resources"][repair_resource]
                    repair_entry={"path": repair_resource, "source_surface_index": closure["surface"],
                                  "native_owner": closure["native_owner"], "kind": closure["kind"],
                                  "always_present": True, "source_mesh_name": name}
                    for used_node in selected_nodes:
                        index["closures"][relative+"|"+glb.doc["nodes"][used_node]["name"]] = repair_entry
                cached_bakes[signature]=(entry,index["resources"][resource],repair_entry,repair_details)
                print("GEOMETRY_BAKE", identity, "triangles", metadata["source_triangles"], "->", metadata["triangles"], flush=True)
                if len(index["meshes"])%10==0:
                    (output/"index.json").write_text(json.dumps(index,indent=2,allow_nan=False)+"\n")
        (output / "index.json").write_text(json.dumps(index, indent=2, allow_nan=False) + "\n")
    index["summary"] = {"scenes": len(paths), "mesh_bindings": len(index["meshes"]), "instance_bindings": len(index["instances"]),
                        "resources": len(index["resources"]), "permanent_boundary_instances": len(index["closures"]), "source_triangles": sum(v["source_triangles"] for v in index["resources"].values()),
                        "rebuilt_triangles": sum(v["triangles"] for v in index["resources"].values()),
                        "bytes": sum(v["bytes"] for v in index["resources"].values()), "reused_mesh_bindings": reused}
    for key in ("numerical_pose_bytes","numerical_attribute_bytes","numerical_provenance_bytes","numerical_index_lod_bytes","collision_numerical_bytes"):
        index["summary"][key]=sum(v.get(key,0) for v in index["resources"].values())
    index["summary"]["largest_twenty_resources"]=[{"path":name,"source_group":v.get("source_group"),"source_record":v.get("source_record"),
        "triangles":v["triangles"],"vertices":v["vertices"],"poses":v["pose_count"],"hgm_bytes":v["bytes"],
        "lod_triangle_counts":v.get("lod_triangle_counts",[])}
        for name,v in sorted(index["resources"].items(),key=lambda item:item[1]["triangles"],reverse=True)[:20]]
    (output / "index.json").write_text(json.dumps(index, indent=2, allow_nan=False) + "\n")
    print("GEOMETRY_BAKE_SUMMARY", json.dumps(index["summary"]), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
