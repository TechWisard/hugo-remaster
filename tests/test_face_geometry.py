"""Shared eye contours, skin-hole coverage, and native-pose correspondence."""
import unittest

import numpy as np

from hugo_assets.geometry_quality import refine_mesh, validate_surface
from test_geometry_quality import surface


def contains(point, triangles):
    edge1,edge2=triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0]
    matrix=np.stack((edge1,edge2),axis=-1)
    valid=np.abs(np.linalg.det(matrix))>1e-10
    bary=np.linalg.solve(matrix[valid],(np.broadcast_to(point,(len(triangles),2))[valid]-triangles[valid,0])[:,:,None])[:,:,0]
    return np.any((bary.min(axis=1)>-1e-5)&(bary.sum(axis=1)<1+1e-5))


class FaceGeometryTests(unittest.TestCase):
    def test_round_contours_cover_skin_opening_share_pupil_and_follow_all_poses(self):
        angle=np.arange(8)*2*np.pi/8
        outer=np.column_stack((np.cos(angle)*.4,np.sin(angle)*.55,np.zeros(8)))
        inner=np.column_stack((np.cos(angle)*.17,np.sin(angle)*.23,np.zeros(8)))
        ring=np.concatenate((outer,inner))
        white=surface(ring,[[i,(i+1)%8,8+i] for i in range(8)]+[[8+i,(i+1)%8,8+(i+1)%8] for i in range(8)])
        white['uv']=None
        white['colors'][:,:3]=.65
        pupil=surface(np.concatenate((inner,[[0,0,0]])),[[8,i,(i+1)%8] for i in range(8)])
        pupil['colors'][:,:3]=.02
        rotation=np.asarray([[1,0,0],[0,.8,-.6],[0,.6,.8]])
        for original in (white,pupil):
            original['positions'][1]=original['positions'][0]@rotation.T*1.7+[.5,.2,-.4]
        contexts=[{'owner_classes':['Hugo'],'source_texture_aliases':[{'group':6,'texture_id':381}]},
                  {'owner_classes':['Hugo'],'source_texture_aliases':[{'group':6,'texture_id':386}]}]
        rebuilt,report=refine_mesh([white,pupil],contexts)
        self.assertEqual(report['eye_geometry']['eyes'],1)
        white_out,pupil_out=rebuilt
        for original,out in zip((white,pupil),rebuilt):
            validate_surface(out,2)
            used=np.unique(out['indices'])
            np.testing.assert_allclose(out['positions'][1,used],out['positions'][0,used]@rotation.T*1.7+[.5,.2,-.4],atol=2e-6)
            self.assertTrue(np.all(out['source_weights']>=0))
            np.testing.assert_allclose(out['source_weights'].sum(axis=1),1,atol=1e-6)
        triangles=white_out['positions'][0,white_out['indices'],:2]
        for a,b in zip(outer,np.roll(outer,-1,axis=0)):
            for fraction in (0.,.25,.5,.75):
                self.assertTrue(contains((a*(1-fraction)+b*fraction)[:2],triangles),
                                'Rounded white must cover every old skin-hole edge, not reveal black wedges')
        white_points={tuple(np.round(p,6)) for p in white_out['positions'][0,np.unique(white_out['indices'])]}
        pupil_points={tuple(np.round(p,6)) for p in pupil_out['positions'][0,np.unique(pupil_out['indices'])]}
        self.assertGreaterEqual(len(white_points&pupil_points),48,'The complete pupil rim is shared exactly')


if __name__=='__main__':
    unittest.main()
