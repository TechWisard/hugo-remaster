#!/usr/bin/env python3
"""Address only the confirmed Mines end-wall material scale after shell baking.

All expensive numerical resources are reused exactly. This explicit stage has
its own immutable input receipt; it never changes the prior pipeline hashes.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
from pathlib import Path
import shutil

import numpy as np

from complete_geometry_shells import digest, safe_file, read_geometry, summarise
from build_geometry_quality import GLB, node_matrices, write_geometry
from hugo_assets.boundary_projection import map_stone_end_wall


STAGE = "mines_end_wall_metric_material_v1"


def complete(input_index: Path, output: Path, generated: Path):
    root = Path(__file__).resolve().parents[1]
    input_index, output, generated = input_index.resolve(), output.resolve(), generated.resolve()
    if input_index.parent == output:
        raise ValueError("The UV finishing stage must preserve its input directory")
    original = json.loads(input_index.read_text())
    before = digest(input_index)
    for path, expected in original["pipeline_sha256"].items():
        if digest(safe_file(root, path)) != expected:
            raise ValueError("Stale input pipeline: "+path)
    for path, expected in original["source_inputs"].items():
        if digest(safe_file(generated, path)) != expected:
            raise ValueError("Stale native source: "+path)
    for row in original.get("replacement_alpha_inputs", {}).values():
        if digest(safe_file(generated.parent/"hd", row["path"])) != row["sha256"]:
            raise ValueError("Stale authored alpha: "+row["path"])
    identity, closure = next((k, v) for k, v in original["closures"].items()
                             if v.get("kind") == "mines_rear_stone_wall")
    relative, node_name = identity.split("|", 1)
    glb = GLB(generated/relative)
    node = next(i for i, value in enumerate(glb.doc["nodes"]) if value.get("name") == node_name)
    native_mesh = glb.doc["meshes"][glb.doc["nodes"][node]["mesh"]]
    surface = int(closure["source_surface_index"])
    texture = glb.texture(glb.doc["materials"][native_mesh["primitives"][surface]["material"]])
    if not texture["opaque"]:
        raise ValueError("The confirmed Mines boundary material must remain opaque")
    final = copy.deepcopy(original)
    output.mkdir(parents=True, exist_ok=True)
    files = [Path(__file__).resolve(), root/"tools/hugo_assets/boundary_projection.py"]
    stage_hashes = {path.relative_to(root).as_posix(): digest(path) for path in files}
    final["pipeline_sha256"].update(stage_hashes)
    affected = []
    for name, row in original["resources"].items():
        source = safe_file(input_index.parent, row["input"])
        if digest(source) != row["sha256"]:
            raise ValueError("Changed input numerical resource: "+name)
        target = output/row["input"]
        if name != closure["path"]:
            if not target.exists() or digest(target) != row["sha256"]:
                temporary = target.with_suffix(".tmp")
                shutil.copyfile(source, temporary)
                os.replace(temporary, target)
            continue
        header, surfaces, collision = read_geometry(source)
        old_surface = surfaces[0]
        surfaces[0], detail = map_stone_end_wall(old_surface, node_matrices(glb.doc)[node])
        for field in ("positions", "normals", "indices", "colors", "source_ids", "source_weights"):
            if not np.array_equal(old_surface[field], surfaces[0][field]):
                raise ValueError("A material-only completion altered "+field)
        metadata = copy.deepcopy(header["metadata"])
        detail.update(source_texture_key=texture["key"], source_material_mesh_name=native_mesh["name"],
                      source_material_surface_index=surface)
        metadata["boundary_material_geometry"] = detail
        updated = write_geometry(target, {"extras": {"targetNames": header["blend_shape_names"]}},
                                 surfaces, metadata, collision, set())
        _, _, after = read_geometry(target)
        if not np.array_equal(collision["faces"], after["faces"]) or collision["types"] != after["types"]:
            raise ValueError("A material-only completion altered collision")
        replacement = updated["sha256"][:32]+".res"
        del final["resources"][name]
        final["resources"][replacement] = {"input": row["input"], **updated,
            "base_hgm_sha256": row["sha256"], "postprocess_stage": STAGE}
        final["closures"][identity].update(path=replacement, material_source_mesh_name=native_mesh["name"],
            material_source_surface_index=surface, material_source_texture_key=texture["key"],
            texture_repeat=True, uv_tile_metres=detail["tile_metres"])
        affected.append({"base_resource": name, "base_input": row["input"], "base_hgm_sha256": row["sha256"],
            "resource": replacement, "hgm_sha256": updated["sha256"], "kind": "boundary_wall_material_unwrap",
            "source_group": row["source_group"], "source_record": row["source_record"],
            "source_scene": relative, "source_mesh": native_mesh["name"], "geometry": detail})
    if len(affected) != 1 or digest(input_index) != before:
        raise ValueError("The immutable input or exact one-wall scope changed")
    summarise(final)
    final["summary"].setdefault("postprocess_chain", []).append({"stage": STAGE,
        "input_manifest": input_index.relative_to(root).as_posix(), "input_manifest_sha256": before,
        "pipeline_sha256": stage_hashes, "affected_resources": affected,
        "unchanged_resources_copied_verbatim": len(original["resources"])-1,
        "base_source_inputs_preserved": True, "base_directory_modified": False})
    temporary = output/"index.json.tmp"
    temporary.write_text(json.dumps(final, indent=2, allow_nan=False)+"\n")
    os.replace(temporary, output/"index.json")
    return final


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--generated", type=Path, default=Path("game/assets/generated"))
    args = parser.parse_args()
    result = complete(args.input, args.output, args.generated)
    print("GEOMETRY_BOUNDARY_MAPPING", json.dumps({"resources": len(result["resources"]),
        "affected": 1, "stages": len(result["summary"]["postprocess_chain"]), "index": str(args.output/"index.json")}))


if __name__ == "__main__":
    main()
