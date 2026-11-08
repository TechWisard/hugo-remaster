"""Native CEmitter/CPSXSprite/CFXEnviroment parameters, without guessed names."""
from __future__ import annotations

import hashlib
import math
from pathlib import Path

import numpy as np
from PIL import Image

from .binary import Reader, require
from .catalog import Catalog, Record
from .scene_graph import SceneIndex, SourceTransform


def resource_key(record: Record) -> str:
    return f"g{record.group:03d}_r{record.index:04d}"


def parse_sprite(record: Record, catalog: Catalog) -> dict:
    r = Reader(record.data, record.label)
    require(record.kind == 2002 and record.header_size == 16, f"{r.label}: unsupported CPSXSprite layout")
    zero, owner, mode, material = r.unpack("<4I", 0)
    require(zero == owner == 0 and mode in (0, 1, 2, 3) and material == 16,
            f"{r.label}: invalid sprite header")
    flags, count, table = r.unpack("<HHI", material)
    require(flags == 1 and count > 0 and table == material + 8,
            f"{r.label}: unsupported sprite texture sequence")
    r.check(table, count * 4, "sprite frame table")
    require(len(record.data) == table + count * 12, f"{r.label}: inconsistent sprite sequence size")
    frames = []
    for i in range(count):
        at = r.u32(table + 4 * i)
        require(at == table + 4 * count + 8 * i, f"{r.label}: invalid sprite texture reference")
        texture_id, byte4, byte5, width, height = r.unpack("<I4B", at)
        width, height = width or 256, height or 256
        texture = catalog.texture(record.group, texture_id)
        require((texture.width, texture.height) == (width, height), f"{r.label}: sprite texture dimensions disagree")
        frames.append(dict(texture_group=texture.group, texture_id=texture_id,
                           source_reference_offset=at, source_bytes_4_5=[byte4, byte5],
                           width=width, height=height, rgba_sha256=texture.sha256))
    return dict(source_group=record.group, source_record=record.index, source_type=2002,
                source_sha256=hashlib.sha256(record.data).hexdigest(), blend_mode=mode,
                blend_equation={0: "non_particle_sprite", 1: "destination * (1 - source_rgb)",
                                2: "source_rgb + destination", 3: "source_alpha_over"}[mode],
                frames=frames, frame_policy="min(floor(age_fraction * frame_count), frame_count-1)")


def parse_environment(record: Record, index: SceneIndex) -> dict:
    r = Reader(record.data, record.label)
    require(record.kind == 7000 and record.header_size == 40, f"{r.label}: unsupported particle environment")
    packed_particles, packed_indices = r.unpack("<2I", 4)
    capacity, particle_offset = packed_particles >> 16, packed_particles & 65535
    index_capacity, index_offset = packed_indices >> 16, packed_indices & 65535
    require(0 < capacity <= 65535 and capacity == index_capacity and particle_offset == 40
            and index_offset == 40 + capacity * 76 and len(record.data) == 40 + capacity * 80,
            f"{r.label}: invalid particle pool layout/capacity")
    r.check(particle_offset, capacity * 76, "native particle pool")
    r.check(index_offset, capacity * 4, "native particle free list")
    require(r.u32(16) == 0, f"{r.label}: pre-existing active particles are unsupported")
    multiplier, gravity = r.unpack("<2f", 32)
    require(bool(np.isfinite([multiplier, gravity]).all()) and multiplier >= 0,
            f"{r.label}: invalid particle environment parameters")
    templates = {}
    for i in range(capacity):
        sprite = index.resolve(record.group, r.u32(particle_offset + i * 76), (2002,))
        require(sprite is not None, f"{r.label}: missing particle template sprite")
        templates[resource_key(sprite)] = dict(group=sprite.group, record=sprite.index)
    return dict(source_group=record.group, source_record=record.index, source_type=7000,
                source_sha256=hashlib.sha256(record.data).hexdigest(), capacity=capacity,
                particle_stride=76, velocity_multiplier_per_update=multiplier,
                gravity_z_per_update_source=gravity, template_sprites=list(templates.values()),
                update_equations=["velocity *= velocity_multiplier_per_update",
                                  "velocity.z -= gravity_z_per_update_source",
                                  "position += velocity * delta_seconds"],
                update_frequency="source loop frequency is not encoded in this record")


def parse_emitter(record: Record, catalog: Catalog, index: SceneIndex | None = None) -> dict:
    r = Reader(record.data, record.label)
    require(record.kind == 7500 and record.header_size == 104 and len(record.data) == 104,
            f"{r.label}: unsupported CEmitter layout")
    index = index if index is not None else SceneIndex(catalog)
    sprite = index.resolve(record.group, r.u32(4), (2002,))
    environment = index.resolve(record.group, r.u32(16), (7000,))
    require(sprite is not None and environment is not None, f"{r.label}: missing emitter dependency")
    emission_rate = r.u32(32)
    cone, radius, life, life_percent = (r.unpack("<f", at)[0] for at in (44, 52, 56, 60))
    speed, speed_percent, spin, spin_percent = r.unpack("<4f", 64)
    end_size, end_percent, start_size, start_percent = r.unpack("<IfIf", 80)
    values = [cone, radius, life, life_percent, speed, speed_percent, spin, spin_percent, end_percent, start_percent]
    require(bool(np.isfinite(values).all()) and emission_rate > 0 and 0 <= cone <= 180
            and radius >= 0 and life > 0 and speed >= 0 and min(life_percent, speed_percent, spin_percent,
                                                             end_percent, start_percent) >= 0,
            f"{r.label}: invalid emitter parameters")
    return dict(key=resource_key(record), source_group=record.group, source_record=record.index,
                source_type=7500, source_record_offset=record.offset,
                source_sha256=hashlib.sha256(record.data).hexdigest(),
                emission_rate=emission_rate, cone_half_angle_degrees=cone, spawn_disk_radius_source=radius,
                lifetime=dict(base=life, percent=life_percent), speed_source=dict(base=speed, percent=speed_percent),
                spin_turns_per_0_06_seconds=dict(base=spin, percent=spin_percent),
                end_size=dict(base=end_size, percent=end_percent), start_size=dict(base=start_size, percent=start_percent),
                start_rgb=list(r.bytes(24, 3)), end_rgb=list(r.bytes(27, 3)),
                source_unknown_words={f"0x{at:02x}": r.u32(at) for at in (40, 96, 100)},
                sprite=parse_sprite(sprite, catalog), environment=parse_environment(environment, index),
                random_multiplier="(u * (100 - percent) + percent) / 100; u = native_rand / 32767",
                source_direction_axis="+Z", source_spawn_disk_plane="XY", billboard="screen facing",
                size_convention=dict(diagonal_radius_source_per_size=1.875,
                                     quad_side_source_per_size=1.875 * math.sqrt(2),
                                     zero_rotation_corner_pattern=[[-1, 0], [0, 1], [0, -1], [1, 0]]),
                color_neutral=128,
                evidence=dict(factory_branch="0x42018F/0x4201EC", constructor="0x4255F0",
                              spawn="0x425710", update="0x425BE0", draw="0x425EA0",
                              blend="0x411010 and 0x410B43"))


def export_emitter(record: Record, catalog: Catalog, output: Path, index: SceneIndex | None = None) -> dict:
    """Write only the exact source sprite PNGs used by this emitter."""
    result = parse_emitter(record, catalog, index)
    for frame in result["sprite"]["frames"]:
        texture = catalog.textures[(frame["texture_group"], frame["texture_id"])]
        pixels = catalog.container.payload(texture)
        relative = f"effects/textures/g{texture.group:03d}_id{texture.resource_id:04d}.png"
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            Image.frombytes("RGBA", (texture.width, texture.height), pixels).save(target, format="PNG")
        with Image.open(target) as check:
            check.load()
            require(check.mode == "RGBA" and check.size == (texture.width, texture.height)
                    and check.tobytes() == pixels, f"Emitter texture verification failed: {relative}")
        frame["texture_path"] = relative
    return result


def sample_native_spawn(emitter: dict, random_values: list[float], world: SourceTransform | None = None) -> dict:
    """Deterministic ten-random-value transcription of the native spawn equations.

    Values represent native rand()/32767 samples in native call order.  This is
    a specification/checking helper, not a replacement random generator or clock.
    """
    require(len(random_values) == 10 and all(math.isfinite(u) and 0 <= u <= 1 for u in random_values),
            "Native particle spawn requires ten random values in [0,1]")
    world = world if world is not None else SourceTransform.identity()

    def varied(parameter: dict, u: float) -> float:
        return parameter["base"] * (u * (100 - parameter["percent"]) + parameter["percent"]) / 100

    end_size = int(varied(emitter["end_size"], random_values[0]))
    start_size = int(varied(emitter["start_size"], random_values[1]))
    life = varied(emitter["lifetime"], random_values[2])
    spin = varied(emitter["spin_turns_per_0_06_seconds"], random_values[3])
    angle = random_values[4]
    phi = random_values[5] * math.tau
    radius = math.sqrt(random_values[6]) * emitter["spawn_disk_radius_source"]
    position = world.points(np.array([math.cos(phi) * radius, math.sin(phi) * radius, 0]))
    azimuth = random_values[7] * math.tau
    minimum_cosine = math.cos(math.radians(emitter["cone_half_angle_degrees"]))
    cosine = minimum_cosine + random_values[8] * (1 - minimum_cosine)
    speed = varied(emitter["speed_source"], random_values[9])
    sine = math.sqrt(max(0.0, 1 - cosine * cosine))
    velocity = world.matrix @ np.array([math.cos(azimuth) * sine * speed,
                                       math.sin(azimuth) * sine * speed, cosine * speed])
    return dict(source_position=position.tolist(), source_velocity=velocity.tolist(), lifetime=life,
                start_size=start_size, end_size=end_size, angle_turns=angle,
                angular_velocity_turns_per_second=spin * 16.66666603088379,
                start_rgb=list(emitter["start_rgb"]), end_rgb=list(emitter["end_rgb"]))
