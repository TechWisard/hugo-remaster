"""Volume, authored holes and full native morph provenance of organic cards."""
import unittest

import numpy as np

from hugo_assets.cutout_geometry import (
    augment_cutout_surface, CUTOUT_PROFILES, WORLD_CUTOUT_PROFILES, SCULPTED_CUTOUT_PROFILES,
)
from hugo_assets.geometry_quality import validate_surface


TUFT = "32x32:428f362cfa9d3688f490f24d5a5f29d2e861462ada53bee32dadb907c306e3e1"


def card(two_islands=False):
    base = np.asarray(((0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0)), np.float32)
    uv = np.asarray(((0, 0), (1, 0), (1, 1), (0, 1)), np.float32)
    faces = np.asarray(((0, 1, 2), (0, 2, 3)), np.uint32)
    if two_islands:
        base = np.concatenate((base, base+[3, 0, 0]))
        uv = np.concatenate((uv, uv))
        faces = np.concatenate((faces, faces+4))
    angle = .61
    rotation = np.asarray(((np.cos(angle), 0, np.sin(angle)), (0, 1, 0),
                           (-np.sin(angle), 0, np.cos(angle))))
    poses = np.stack((base, (base*1.3)@rotation.T+[.3, -.2, 1.7])).astype(np.float32)
    count = len(base)
    normals = np.stack((np.tile((0., 0., 1.), (count, 1)), np.tile(rotation[:, 2], (count, 1)))).astype(np.float32)
    colors = np.column_stack((uv, np.full(count, .7), np.ones(count))).astype(np.float32)
    return {"positions": poses, "normals": normals, "uv": uv,
            "uv2": np.column_stack((np.arange(count), np.full(count, 7))).astype(np.float32),
            "colors": colors, "source_ids": np.repeat(np.arange(count)[:, None], 3, axis=1).astype(np.int32),
            "source_weights": np.tile((1., 0., 0.), (count, 1)).astype(np.float32),
            "indices": faces, "triangle_origin": np.column_stack((np.zeros(len(faces)), np.arange(len(faces)))).astype(np.int32),
            "collision_mask": np.zeros(len(faces), bool), "collision_surface_types": np.full(len(faces), -1, np.int32),
            "lod_indices": {}, "source_vertex_count": count, "part_index": 7}, rotation


def mask():
    y, x = np.mgrid[:64, :64]
    result = np.where(((x-31.5)/28.)**2+((y-31.5)/29.)**2 <= 1, 255, 0).astype(np.uint8)
    result[24:40, 24:40] = 0
    # A one-texel opening also must not receive an opaque solid triangle.
    result[15, 31] = 0
    return result


def rebuild(source, alpha=None, **extra):
    def evaluate(face, bary):
        return np.einsum('i,pic->pc', bary, source['positions'][:, source['indices'][face]])

    def normal(face, bary):
        return np.einsum('i,pic->pc', bary, source['normals'][:, source['indices'][face]])

    context = {"source_texture_key": TUFT, "source_texture_size": [32, 32],
               "owner_classes": ["CSimpleStateActor"], "original_surface": source,
               "source_alpha": mask() if alpha is None else alpha,
               "surface_evaluator": evaluate, "normal_evaluator": normal, **extra}
    result = augment_cutout_surface(source, context)
    validate_surface(result, len(source['positions']))
    return result


class CutoutGeometryTests(unittest.TestCase):
    def test_real_curved_shell_tracks_rotation_scale_and_translation_in_both_poses(self):
        source, rotation = card()
        result = rebuild(source)
        info = result['cutout_geometry']
        self.assertTrue(info['applied'])
        self.assertEqual(info['volumetric_components'], 1)
        self.assertGreater(info['added_vertices'], 100)
        self.assertGreater(info['contour_wall_triangles'], 30)
        self.assertGreater(np.ptp(result['positions'][0, 4:, 2]), .035)
        np.testing.assert_array_equal(result['positions'][:, :4], source['positions'])
        np.testing.assert_array_equal(result['indices'][:2], source['indices'])
        expected = (result['positions'][0, 4:]*1.3)@rotation.T+[.3, -.2, 1.7]
        np.testing.assert_allclose(result['positions'][1, 4:], expected, atol=2e-6)
        np.testing.assert_allclose(result['normals'][1, 4:], result['normals'][0, 4:]@rotation.T, atol=2e-5)
        self.assertFalse(result['collision_mask'].any())
        self.assertTrue(np.all(result['uv2'][4:] == [-1, 7]))
        interpolated = np.einsum('ni,nic->nc', result['source_weights'][4:], source['colors'][result['source_ids'][4:]])
        np.testing.assert_allclose(result['colors'][4:], interpolated, atol=2e-6)
        self.assertTrue(all(np.array_equal(faces, source['indices']) for faces in result['lod_indices'].values()))

    def test_replacement_silhouette_and_interior_holes_are_not_capped(self):
        source, _ = card()
        alpha = mask()
        result = rebuild(source, np.full((64, 64), 255, np.uint8), replacement_alpha=alpha)
        self.assertEqual(result['cutout_geometry']['alpha_source'], 'replacement')
        self.assertTrue(result['cutout_geometry']['source_alpha_fringe_retained'])
        faces = result['indices'][2:]
        points = result['uv'][faces]
        # Pixel centres throughout both the large hole and the single-texel hole.
        yy, xx = np.nonzero(alpha == 0)
        samples = np.column_stack(((xx+.5)/64, (yy+.5)/64))
        for triangle in points:
            a, b = triangle[1]-triangle[0], triangle[2]-triangle[0]
            det = a[0]*b[1]-a[1]*b[0]
            if abs(det) < 1e-12:  # Contour walls have zero UV area.
                continue
            rel = samples-triangle[0]
            u = (rel[:, 0]*b[1]-rel[:, 1]*b[0])/det
            v = (a[0]*rel[:, 1]-a[1]*rel[:, 0])/det
            self.assertFalse(np.any((u >= -1e-8) & (v >= -1e-8) & (u+v <= 1+1e-8)))
        # Every new topological edge has two incident faces, including the hole wall.
        edges = {}
        for face in faces:
            for a, b in zip(face, np.roll(face, -1)):
                key = tuple(sorted((int(a), int(b))))
                edges[key] = edges.get(key, 0)+1
        self.assertTrue(all(count == 2 for count in edges.values()))

    def test_identical_uv_on_separate_cards_does_not_bridge_them(self):
        source, _ = card(True)
        result = rebuild(source)
        self.assertEqual(result['cutout_geometry']['volumetric_components'], 2)
        ids = result['source_ids'][8:]
        self.assertTrue(np.all((ids.max(axis=1) < 4) | (ids.min(axis=1) >= 4)))
        new_x = result['positions'][0, 8:, 0]
        self.assertFalse(np.any((new_x > 1.1) & (new_x < 2.9)))
        self.assertTrue(np.all(np.ptp(result['positions'][0, result['indices'][4:], 0], axis=1) < 1.1))

    def test_unknown_material_missing_assets_and_non_character_owner_are_safe(self):
        source, _ = card()
        self.assertEqual(len(CUTOUT_PROFILES), 10)
        self.assertIs(augment_cutout_surface(source, {'source_texture_key': 'unknown'}), source)
        self.assertIs(augment_cutout_surface(source, {'source_texture_key': TUFT, 'owner_classes': ['CDefaultSegment']}), source)
        result = augment_cutout_surface(source, {'source_texture_key': TUFT, 'original_surface': source})
        self.assertFalse(result['cutout_geometry']['applied'])
        self.assertEqual(result['cutout_geometry']['reason'], 'alpha_unavailable')
        np.testing.assert_array_equal(result['positions'], source['positions'])

    def test_collapsed_initial_pose_does_not_explode_when_later_pose_opens(self):
        source, _ = card()
        source['positions'][0] = 0
        result = rebuild(source)
        self.assertTrue(result['cutout_geometry']['applied'])
        self.assertTrue(np.isfinite(result['positions']).all())
        np.testing.assert_array_equal(result['positions'][0], np.zeros_like(result['positions'][0]))
        self.assertLess(result['cutout_geometry']['maximum_normal_offset_metres'], .1)
        self.assertGreater(np.ptp(result['positions'][1, 4:, 2]), .1)

    def test_verified_world_frame_gains_thickness_without_filling_window_or_collision(self):
        source, _ = card()
        source['collision_mask'][:] = True
        source['collision_surface_types'][:] = 3
        frame_key = '64x64:ae12001f14540610881fb308d02676cbe4157dec1b0f4b952c2c1b0162602e87'
        self.assertEqual(len(WORLD_CUTOUT_PROFILES), 13)
        alpha = np.full((32, 32), 255, np.uint8)
        alpha[4:28, 4:28] = 0
        result = rebuild(source, alpha, source_texture_key=frame_key, owner_classes=['CDefaultSegment'])
        self.assertTrue(result['cutout_geometry']['applied'])
        self.assertEqual(result['cutout_geometry']['profile'], 'wood')
        self.assertGreater(np.ptp(result['positions'][0, 4:, 2]), .04)
        np.testing.assert_array_equal(result['collision_mask'][:2], source['collision_mask'])
        self.assertFalse(result['collision_mask'][2:].any())
        np.testing.assert_array_equal(result['collision_surface_types'][:2], source['collision_surface_types'])
        points = result['uv'][4:]
        self.assertFalse(np.any(np.all((points > .20) & (points < .80), axis=1)))
        # The verified warning badge is a shallow explicit relief; its inherited
        # platform collision is unchanged and no generic deep extrusion is used.
        disc_key = '64x64:b64be15c766a9b146a08be4f0ac09ee7e7cd9087e9ba0c7ef3c0cd5f766c99f0'
        badge = rebuild(source, alpha, source_texture_key=disc_key, owner_classes=['CPlatform'])
        self.assertEqual(badge['cutout_geometry']['profile'], 'warning_badge')
        self.assertLess(badge['cutout_geometry']['maximum_normal_offset_metres'], .05)
        self.assertFalse(badge['collision_mask'][2:].any())

    def test_explicit_round_objects_have_curved_volume_instead_of_parallel_cards(self):
        source, rotation = card()
        self.assertEqual(len(SCULPTED_CUTOUT_PROFILES), 8)
        tested = set()
        for key, profile in SCULPTED_CUTOUT_PROFILES.items():
            if profile in tested:
                continue
            tested.add(profile)
            with self.subTest(profile=profile):
                result = rebuild(source, source_texture_key=key, owner_classes=['COrnemental'])
                self.assertTrue(result['cutout_geometry']['applied'])
                self.assertGreater(np.ptp(result['positions'][0, 4:, 2]), .02)
                # A rounded surface has genuinely varying normals, not only an
                # offset duplicate of its flat source quad.
                normals = result['normals'][0, 4:]
                self.assertGreater(np.ptp(normals[:, 0]), .1)
                expected = (result['positions'][0, 4:]*1.3)@rotation.T+[.3, -.2, 1.7]
                np.testing.assert_allclose(result['positions'][1, 4:], expected, atol=2e-6)
                np.testing.assert_array_equal(result['positions'][:, :4], source['positions'])
                self.assertFalse(result['collision_mask'].any())

    def test_unhandled_repeating_uv_is_reported_instead_of_silent_partial_geometry(self):
        source, _ = card()
        source['uv'] *= 2
        result = rebuild(source)
        info = result['cutout_geometry']
        self.assertFalse(info['applied'])
        self.assertEqual(info['skipped_components'], 1)
        self.assertEqual(info['skipped_reasons'][0]['reason'], 'uv_outside_unit_tile')
        np.testing.assert_array_equal(result['positions'], source['positions'])

    def test_existing_base_lods_cannot_discard_visible_volume_at_tiny_error(self):
        source, _ = card()
        source['lod_indices'] = {.002: source['indices'].copy(), .006: source['indices'][:1].copy()}
        result = rebuild(source)
        floor = 2*result['cutout_geometry']['maximum_normal_offset_metres']
        self.assertEqual(len(result['lod_indices']), 2)
        errors = sorted(result['lod_indices'])
        self.assertGreaterEqual(errors[0], floor)
        self.assertGreater(errors[1], errors[0])
        np.testing.assert_array_equal(result['lod_indices'][errors[0]], source['indices'])
        np.testing.assert_array_equal(result['lod_indices'][errors[1]], source['indices'][:1])


if __name__ == '__main__':
    unittest.main()
