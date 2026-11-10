"""Bent sheets gain real thickness without changing source animation or UVs."""
import unittest

import numpy as np

from hugo_assets.cutout_geometry import augment_cutout_surface
from hugo_assets.curved_cutout_geometry import (
    SOURCE_KEYS, _constrained_layout, _open_sheet_proof, augment_curved_cutout_surface,
    augment_verified_cutout_surface,
)
from hugo_assets.geometry_quality import validate_surface


LEAF = '32x53:f56c73f169e21fad592f378cf699135e7437d72389928147a366c6c06f497a56'


def sheet(rank_one=False):
    if rank_one:
        uv = np.asarray(((1., 0.), (0., 1.), (0., 1.)), np.float32)
        base = np.asarray(((0., 0., 0.), (1., 0., 0.), (0., 1., 0.)), np.float32)
        normals = np.tile((0., 0., 1.), (3, 1))
        faces = np.asarray(((0, 1, 2),), np.uint32)
    else:
        uv = np.asarray([(x/3, y/3) for y in range(4) for x in range(4)], np.float32)
        angle = (uv[:, 0]-.5)*2.8
        base = np.column_stack((np.sin(angle), uv[:, 1], np.cos(angle)))
        normals = np.column_stack((np.sin(angle), np.zeros(len(uv)), np.cos(angle)))
        faces = np.asarray([(a, a+1, a+5) if side == 0 else (a, a+5, a+4)
                            for y in range(3) for x in range(3) for a in [y*4+x] for side in range(2)], np.uint32)
    angle = .63
    rotation = np.asarray(((np.cos(angle), 0, np.sin(angle)), (0, 1, 0),
                           (-np.sin(angle), 0, np.cos(angle))))
    count = len(base)
    positions = np.stack((base, (base*1.3)@rotation.T+[.4, -.7, 1.2])).astype(np.float32)
    normals = np.stack((normals, normals@rotation.T)).astype(np.float32)
    surface = {'positions': positions, 'normals': normals, 'uv': uv,
        'uv2': np.column_stack((np.arange(count), np.full(count, 8))).astype(np.float32),
        'colors': np.column_stack((uv, np.full(count, .7), np.ones(count))).astype(np.float32),
        'source_ids': np.repeat(np.arange(count)[:, None], 3, axis=1).astype(np.int32),
        'source_weights': np.tile((1., 0., 0.), (count, 1)).astype(np.float32),
        'indices': faces, 'triangle_origin': np.column_stack((np.zeros(len(faces)), np.arange(len(faces)))).astype(np.int32),
        'collision_mask': np.zeros(len(faces), bool), 'collision_surface_types': np.full(len(faces), -1, np.int32),
        'lod_indices': {.001: faces.copy()}, 'source_vertex_count': count, 'part_index': 8}
    return surface, rotation


def rebuild(source, alpha, key=LEAF):
    def evaluate(face, bary):
        return np.einsum('i,pic->pc', bary, source['positions'][:, source['indices'][face]])

    def normal(face, bary):
        return np.einsum('i,pic->pc', bary, source['normals'][:, source['indices'][face]])

    context = {'source_texture_key': key, 'source_texture_size': (32, 53),
               'owner_classes': ['COrnemental'], 'original_surface': source,
               'source_alpha': alpha, 'replacement_alpha': alpha,
               'surface_evaluator': evaluate, 'normal_evaluator': normal}
    prior = augment_cutout_surface(source, context)
    result = augment_curved_cutout_surface(prior, context)
    validate_surface(result, len(source['positions']))
    return prior, result


def closed_edges(faces):
    edges = {}
    for face in faces:
        for a, b in zip(face, np.roll(face, -1)):
            key = tuple(sorted((int(a), int(b))))
            edges[key] = edges.get(key, 0)+1
    return bool(edges) and all(count == 2 for count in edges.values())


class CurvedCutoutGeometryTests(unittest.TestCase):
    def test_bent_open_sheet_gains_closed_volume_in_both_native_poses(self):
        source, rotation = sheet()
        alpha = np.full((64, 64), 255, np.uint8)
        alpha[25:39, 25:39] = 0
        alpha[13, 31] = 0
        prior, result = rebuild(source, alpha)
        self.assertFalse(prior['cutout_geometry']['applied'])
        self.assertEqual(prior['cutout_geometry']['skipped_reasons'][0]['reason'], 'source_already_nonplanar')
        info = result['curved_cutout_geometry']
        self.assertTrue(info['applied'])
        self.assertEqual(info['volumetric_components'], 1)
        self.assertEqual(result['cutout_geometry']['skipped_components'], 0)
        self.assertEqual(result['cutout_geometry']['volumetric_components'], 1)
        count, faces = source['positions'].shape[1], len(source['indices'])
        np.testing.assert_array_equal(result['positions'][:, :count], source['positions'])
        np.testing.assert_array_equal(result['indices'][:faces], source['indices'])
        self.assertTrue(closed_edges(result['indices'][faces:]))
        np.testing.assert_allclose(result['positions'][1, count:], (result['positions'][0, count:]*1.3)@rotation.T+[.4, -.7, 1.2], atol=3e-6)
        np.testing.assert_allclose(result['normals'][1, count:], result['normals'][0, count:]@rotation.T, atol=4e-5)
        native = np.einsum('ni,nic->nc', result['source_weights'][count:], source['positions'][0, result['source_ids'][count:]])
        self.assertGreater(np.linalg.norm(result['positions'][0, count:]-native, axis=1).max(), .01)
        np.testing.assert_allclose(result['uv'][count:], np.einsum('ni,nic->nc', result['source_weights'][count:], source['uv'][result['source_ids'][count:]]), atol=2e-6)
        self.assertFalse(result['collision_mask'].any())
        self.assertGreaterEqual(min(result['lod_indices']), 2*result['cutout_geometry']['maximum_normal_offset_metres'])
        # The authored large opening and one-pixel hole remain open in 3D.
        yy, xx = np.nonzero(alpha == 0)
        samples = np.column_stack(((xx+.5)/64, (yy+.5)/64))
        for triangle in result['uv'][result['indices'][faces:]]:
            a, b = triangle[1]-triangle[0], triangle[2]-triangle[0]
            determinant = a[0]*b[1]-a[1]*b[0]
            if abs(determinant) < 1e-12:
                continue
            rel = samples-triangle[0]
            u = (rel[:, 0]*b[1]-rel[:, 1]*b[0])/determinant
            v = (a[0]*rel[:, 1]-a[1]*rel[:, 0])/determinant
            self.assertFalse(np.any((u >= -1e-8) & (v >= -1e-8) & (u+v <= 1+1e-8)))

    def test_rank_one_uv_preserves_visible_strip_and_transparent_gap(self):
        source, rotation = sheet(True)
        alpha = np.full((64, 64), 255, np.uint8)
        alpha[:, 28:36] = 0
        prior, result = rebuild(source, alpha)
        self.assertEqual(prior['cutout_geometry']['skipped_reasons'][0]['reason'], 'no_opaque_layout')
        info = result['curved_cutout_geometry']['components'][0]
        self.assertEqual(info['proof']['method'], 'physical_triangle_rank_one_uv')
        self.assertEqual(len(info['opaque_intervals']), 2)
        self.assertTrue(info['applied'])
        self.assertTrue(closed_edges(result['indices'][1:]))
        np.testing.assert_allclose(result['uv'][3:].sum(axis=1), 1., atol=2e-7)
        np.testing.assert_allclose(result['positions'][1, 3:], (result['positions'][0, 3:]*1.3)@rotation.T+[.4, -.7, 1.2], atol=2e-6)
        for triangle in result['uv'][result['indices'][1:]]:
            self.assertFalse(triangle[:, 0].min() < .5 < triangle[:, 0].max())
        self.assertFalse(result['collision_mask'].any())

    def test_closed_volume_and_unknown_keys_are_rejected_and_overlap_requires_partition(self):
        source, _ = sheet(True)
        self.assertEqual(len(SOURCE_KEYS), 31)
        self.assertIs(augment_curved_cutout_surface(source, {'source_texture_key': 'unknown'}), source)
        volume = dict(source)
        volume['positions'] = np.asarray([[(0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1)]], np.float32)
        volume['indices'] = np.asarray(((0, 1, 2), (0, 3, 1), (0, 2, 3), (1, 3, 2)), np.uint32)
        volume['uv'] = np.asarray(((0, 0), (1, 0), (0, 1), (.3, .3)))
        self.assertEqual(_open_sheet_proof(volume, list(range(4)))['reason'], 'closed_or_nonmanifold_source')
        overlap = dict(volume)
        overlap['indices'] = np.asarray(((0, 1, 2), (0, 1, 3)), np.uint32)
        self.assertEqual(_open_sheet_proof(overlap, [0, 1])['reason'], 'overlapping_uv_domain')

    def test_overlapping_uv_layers_get_separate_closed_shells_at_their_native_positions(self):
        source, _ = sheet()
        # Three adjacent curved strips reuse one UV range, with the middle
        # strip mirrored. Joining by UV alone would collapse them together.
        source['uv'][:, 0] = np.tile((0., 1., 0., 1.), 4)
        alpha = np.full((32, 32), 255, np.uint8)
        wood = '64x64:ae12001f14540610881fb308d02676cbe4157dec1b0f4b952c2c1b0162602e87'
        prior, result = rebuild(source, alpha, wood)
        self.assertFalse(prior['cutout_geometry']['applied'])
        info = result['curved_cutout_geometry']['components'][0]
        self.assertTrue(info['applied'])
        self.assertEqual(info['uv_chart_partition'], 'connected_injective_source_charts')
        self.assertEqual(len(info['charts']), 3)
        self.assertTrue(closed_edges(result['indices'][len(source['indices']):]))
        count = source['positions'].shape[1]
        native = np.einsum('ni,nic->nc', result['source_weights'][count:], source['positions'][0, result['source_ids'][count:]])
        distances = np.linalg.norm(result['positions'][0, count:]-native, axis=1)
        self.assertGreater(distances.min(), .005)
        self.assertLess(distances.max(), .081)
        self.assertEqual(result['cutout_geometry']['volumetric_components'], 1)
        self.assertEqual(result['cutout_geometry']['skipped_components'], 0)
        np.testing.assert_array_equal(result['positions'][:, :count], source['positions'])
        # The error depends on the thickest chart, not the sum over charts.
        self.assertLessEqual(min(result['lod_indices']), 2*info['maximum_normal_offset_metres']+.002)

    def test_short_uv_edges_do_not_absorb_nearby_off_edge_vertices(self):
        # The small triangle has a real interior vertex 10 microunits above a
        # short boundary. An absolute cross-product tolerance incorrectly
        # inserts that interior vertex into the boundary and overlaps faces.
        a, b, c, d = np.asarray(((.5, .5), (.50001, .5), (.5, 1.), (.500005, .50001)))
        masked = np.asarray(((a, b, d), (b, c, d), (c, a, d)))
        layout = _constrained_layout(('short_edge_regression',), masked, np.asarray(((a, b, c),)))
        points, _, _, faces = layout
        self.assertEqual(len(points), 4)
        self.assertEqual(len(faces), 3)
        edges = {}
        for face in faces:
            for first, last in zip(face, np.roll(face, -1)):
                key = tuple(sorted((int(first), int(last))))
                edges[key] = edges.get(key, 0)+1
        self.assertEqual(sum(value == 1 for value in edges.values()), 3)
        self.assertEqual(sum(value == 2 for value in edges.values()), 3)

    def test_coincident_reverse_faces_keep_source_attributes_without_duplicate_volume(self):
        source, _ = sheet()
        alpha = np.full((32, 32), 255, np.uint8)
        _, reference = rebuild(source, alpha)
        original_faces = source['indices'].copy()
        source['indices'] = np.concatenate((source['indices'], source['indices'][:2, ::-1]))
        source['triangle_origin'] = np.concatenate((source['triangle_origin'], source['triangle_origin'][:2]))
        source['collision_mask'] = np.zeros(len(source['indices']), bool)
        source['collision_surface_types'] = np.full(len(source['indices']), -1, np.int32)
        _, result = rebuild(source, alpha)
        info = result['curved_cutout_geometry']['components'][0]
        self.assertTrue(info['applied'])
        self.assertEqual(len(info['coincident_source_faces_retained']), 2)
        self.assertEqual(result['cutout_geometry']['added_triangles'], reference['cutout_geometry']['added_triangles'])
        np.testing.assert_array_equal(result['indices'][:len(original_faces)+2], source['indices'])
        np.testing.assert_array_equal(result['positions'][:, :source['positions'].shape[1]], source['positions'])
        self.assertTrue(closed_edges(result['indices'][len(source['indices']):]))

    def test_verified_constructor_preserves_all_profile_families_and_native_morphs(self):
        from hugo_assets.curved_cutout_geometry import _PROFILES
        source, rotation = sheet()
        alpha = np.full((48, 48), 255, np.uint8)
        alpha[18:30, 18:30] = 0
        tested = set()
        for key, profile in _PROFILES.items():
            if profile in tested:
                continue
            tested.add(profile)
            with self.subTest(profile=profile):
                context = {'source_texture_key': key, 'source_texture_size': (32, 32),
                    'owner_classes': ['CSimpleStateActor'], 'original_surface': source,
                    'source_alpha': alpha, 'replacement_alpha': alpha,
                    'surface_evaluator': lambda face, bc: np.einsum('i,pic->pc', bc, source['positions'][:, source['indices'][face]]),
                    'normal_evaluator': lambda face, bc: np.einsum('i,pic->pc', bc, source['normals'][:, source['indices'][face]])}
                result = augment_verified_cutout_surface(source, context)
                validate_surface(result, 2)
                self.assertTrue(result['cutout_geometry']['applied'])
                self.assertEqual(result['cutout_geometry']['profile'], profile)
                self.assertTrue(result['curved_cutout_geometry']['reconstructed_from_semantic_stage'])
                self.assertGreater(result['cutout_geometry']['maximum_normal_offset_metres'], .015)
                count = source['positions'].shape[1]
                np.testing.assert_array_equal(result['positions'][:, :count], source['positions'])
                np.testing.assert_allclose(result['positions'][1, count:], (result['positions'][0, count:]*1.3)@rotation.T+[.4, -.7, 1.2], atol=4e-6)
                self.assertTrue(closed_edges(result['indices'][len(source['indices']):]))
                self.assertFalse(result['collision_mask'].any())
        self.assertEqual(len(tested), 12)


if __name__ == '__main__':
    unittest.main()
