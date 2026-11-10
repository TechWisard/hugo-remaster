"""Visible border repairs cannot depend on optional graphics quality."""
import unittest
from collections import Counter

import numpy as np

from hugo_assets.boundary_geometry import build_boundary_surface, verified_boundary


def source():
    return {"positions": np.asarray([[[0,0,0],[1,0,0],[0,1,0]]],np.float32),
            "indices":np.asarray([[0,1,2]],np.uint32),
            "colors":np.asarray([[.4,.5,.6,1]]*3,np.float32),
            "source_ids":np.repeat(np.asarray([7,12,19],np.int32)[:,None],3,axis=1)}


def hit(points, triangles, start, finish):
    start, finish=np.asarray(start),np.asarray(finish)
    direction=finish-start
    tri=points[triangles]
    a,b=tri[:,1]-tri[:,0],tri[:,2]-tri[:,0]
    cross=np.cross(np.broadcast_to(direction,a.shape),b)
    determinant=(a*cross).sum(axis=1)
    valid=np.abs(determinant)>1e-8
    inverse=np.divide(1.,determinant,out=np.zeros_like(determinant),where=valid)
    offset=start-tri[:,0]
    u=(offset*cross).sum(axis=1)*inverse
    q=np.cross(offset,a)
    v=(q*direction).sum(axis=1)*inverse
    t=(b*q).sum(axis=1)*inverse
    return np.any(valid&(u>=-1e-6)&(v>=-1e-6)&(u+v<=1.+1e-6)&(t>=0)&(t<=1))


class BoundaryGeometryTests(unittest.TestCase):
    def test_mines_wall_exact_visible_collision_and_native_provenance(self):
        original=source(); before=original["positions"].copy()
        transform=np.eye(4);transform[:3,3]=[12,-3,7]
        info={"kind":"mines_rear_stone_wall","surface":4,"anchor_face":0,
              "x_min":-4.,"x_max":4.,"bottom":-.25,"top":5.,"front_z":6.,"thickness":.55}
        out=build_boundary_surface(info,original,transform)
        world=out["positions"][0]+transform[:3,3]
        self.assertTrue(out["collision_mask"].all())
        self.assertTrue(np.all(out["collision_surface_types"]==-1))
        self.assertEqual(out["positions"].shape[0],1)
        np.testing.assert_array_equal(original["positions"],before)
        np.testing.assert_array_equal(out["source_ids"],np.tile([7,12,19],(len(world),1)))
        np.testing.assert_allclose(out["source_weights"].sum(axis=1),1.)
        for x in (-3.5,0.,3.5):
            for y in (.1,1.,3.):
                self.assertTrue(hit(world,out["indices"],[x,y,4],[x,y,8]))
        self.assertFalse(hit(world,out["indices"],[0,0,0],[0,-10,0]),"No invented horizontal gameplay floor")

    def test_beach_bank_has_solid_volume_above_each_confirmed_edge(self):
        chain=[[0,0,-8],[.2,.1,-4],[0,0,0],[1.,-.1,4]]
        info={"kind":"beach_west_rock_bank","surface":1,"anchor_face":0,"chain_world":chain}
        out=build_boundary_surface(info,source(),np.eye(4))
        points=out["positions"][0]
        for a,b in zip(np.asarray(chain[:-1]),np.asarray(chain[1:])):
            for fraction in (.1,.5,.9):
                p=a*(1-fraction)+b*fraction
                for height in (.15,1.,2.5,3.4):
                    self.assertTrue(hit(points,out["indices"],p+[2,height,0],p+[-4,height,0]))
        self.assertGreater(float(np.ptp(points[:,0])),3.)
        self.assertGreater(float(points[:,1].max()),4.)
        self.assertTrue(out["collision_mask"].all())
        self.assertFalse(hit(points,out["indices"],[3,1,0],[3,-20,0]),"Unmodified eastward gameplay route is open")
        welded=[tuple(row) for row in np.round(points,5)]
        edges=Counter(tuple(sorted((welded[a],welded[b]))) for face in out["indices"]
                      for a,b in zip(face,np.roll(face,-1)))
        self.assertEqual(set(edges.values()),{2},"The rounded bank and both end caps form a closed volume")

    def test_no_generalized_pit_or_unknown_owner_closure(self):
        self.assertIsNone(verified_boundary({"id":"g046"},{"id":"lava_pit"},0,{},None))
        self.assertIsNone(verified_boundary({"id":"g006"},{"id":"different_beach_owner"},0,{},None))
        with self.assertRaisesRegex(ValueError,"static"):
            original=source();original["positions"]=np.repeat(original["positions"],2,axis=0)
            build_boundary_surface({"kind":"unreachable"},original,np.eye(4))


if __name__=="__main__":
    unittest.main()
