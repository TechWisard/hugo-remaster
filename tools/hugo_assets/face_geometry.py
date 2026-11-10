"""Replace Hugo's polygonal white eye rings and matching pupil boundaries.

The source head has two untextured white annuli with six-sided pupil holes.
Both annulus and pupil are rebuilt together around shared oval contours, using
existing per-pose surfaces and nonnegative original-vertex attribute anchors.
Teeth, eyebrows, hair and other white/dark head primitives are not selected.
"""
from __future__ import annotations

from collections import defaultdict

import numpy as np


def _components_and_loops(source):
    triangles = source["indices"]
    edges = defaultdict(list)
    for face, tri in enumerate(triangles):
        for a, b in zip(tri, np.roll(tri, -1)):
            edges[tuple(sorted((int(a), int(b))))].append(face)
    parents = list(range(len(triangles)))
    def root(i):
        while parents[i] != i:
            parents[i] = parents[parents[i]]; i = parents[i]
        return i
    for uses in edges.values():
        for face in uses[1:]: parents[root(face)] = root(uses[0])
    groups = defaultdict(list)
    for face in range(len(triangles)): groups[root(face)].append(face)
    result=[]
    for faces in groups.values():
        lookup=set(faces); adjacency=defaultdict(list)
        for (a,b), uses in edges.items():
            if sum(face in lookup for face in uses)==1:
                adjacency[a].append(b);adjacency[b].append(a)
        if not adjacency or any(len(v)!=2 for v in adjacency.values()):continue
        unused=set(adjacency);loops=[]
        while unused:
            start=min(unused);curve=[start];previous=-1;current=start
            while True:
                next_vertex=next(v for v in adjacency[current] if v!=previous)
                if next_vertex==start:break
                if next_vertex in curve:curve=[];break
                curve.append(next_vertex);previous,current=current,next_vertex
            if not curve:break
            loops.append(curve);unused.difference_update(curve)
        if not unused:result.append((faces,loops))
    return result


def _closest_bary(point, positions2, faces):
    triangles=positions2[faces]
    matrices=np.stack((triangles[:,1]-triangles[:,0],triangles[:,2]-triangles[:,0]),axis=-1)
    valid=np.abs(np.linalg.det(matrices))>1e-12
    inverse=np.zeros_like(matrices);inverse[valid]=np.linalg.inv(matrices[valid])
    bc12=np.einsum('tij,tj->ti',inverse,point-triangles[:,0])
    bary=np.column_stack((1.-bc12.sum(axis=1),bc12))
    contains=(bary.min(axis=1)>=-1e-7)&valid
    if contains.any():
        at=int(np.flatnonzero(contains)[0]);w=np.maximum(bary[at],0.);return at,w/w.sum()
    best=None
    for side in range(3):
        a,b=triangles[:,side],triangles[:,(side+1)%3]
        edge=b-a
        t=np.clip(np.sum((point-a)*edge,axis=1)/np.maximum(np.sum(edge*edge,axis=1),1e-15),0.,1.)
        closest=a+t[:,None]*edge
        distances=np.linalg.norm(closest-point,axis=1);distances[~valid]=np.inf
        at=int(np.argmin(distances))
        if best is None or distances[at]<best[0]:
            w=np.zeros(3);w[side]=1.-t[at];w[(side+1)%3]=t[at]
            best=(distances[at],at,w)
    return best[1],best[2]


def _corneal_lift(source, parent, bary, context):
    triangle=source['positions'][:,source['indices'][parent]]
    area=np.linalg.norm(np.cross(triangle[:,1]-triangle[:,0],triangle[:,2]-triangle[:,0]),axis=1)
    scale=np.sqrt(area/max(float(area[0]),1e-12))
    return context['normal_evaluator'](parent,bary)*(.003*scale[:,None])


def round_eyes(sources, refined, contexts, segments=48, rings=3):
    aliases={(int(item['group']),int(item['texture_id'])) for context in contexts for item in context.get('source_texture_aliases',[])}
    if not {(6,381),(6,386)}.issubset(aliases):
        return refined,{"applied":False,"eyes":0}
    from .bevel_geometry import _Surface,_unit
    components=[_components_and_loops(s) for s in sources]
    selected=[]
    for surface,source in enumerate(sources):
        if source.get('uv') is not None:continue
        for faces,loops in components[surface]:
            if len(loops)!=2 or min(map(len,loops))<5:continue
            vertices=np.unique(source['indices'][faces])
            colors=source['colors'][vertices,:3]
            if np.max(np.ptp(colors,axis=1))>.025 or colors.mean()<.22:continue
            all_points=source['positions'][0,vertices]
            center=all_points.mean(axis=0)
            _,_,basis=np.linalg.svd(all_points-center,full_matrices=False)
            axes=basis[:2].T
            projected=(source['positions'][0]-center)@axes
            areas=[]
            for loop in loops:
                xy=projected[loop]
                areas.append(abs(np.sum(xy[:,0]*np.roll(xy[:,1],-1)-xy[:,1]*np.roll(xy[:,0],-1))*.5))
            outer=loops[int(np.argmax(areas))];inner=loops[int(np.argmin(areas))]
            inner_signatures={tuple(np.round(p,6)) for p in source['positions'][0,inner]}
            pupil=None
            for other, rows in enumerate(components):
                if other==surface:continue
                for pupil_faces,pupil_loops in rows:
                    if len(pupil_loops)!=1:continue
                    signatures={tuple(np.round(p,6)) for p in sources[other]['positions'][0,pupil_loops[0]]}
                    if signatures==inner_signatures:
                        pupil=(other,pupil_faces,pupil_loops[0]);break
                if pupil is not None:break
            if pupil is None:continue
            selected.append({'surface':surface,'faces':faces,'outer':outer,'inner':inner,
                             'pupil':pupil,'center':center,'axes':axes,'projected':projected})
    if not selected:return refined,{"applied":False,"eyes":0}
    builders=[_Surface(source,target) for source,target in zip(sources,refined)]
    omitted=defaultdict(set)
    for eye in selected:
        omitted[eye['surface']].update(eye['faces']);omitted[eye['pupil'][0]].update(eye['pupil'][1])
    for surface,target in enumerate(refined):
        for i,triangle in enumerate(target['indices']):
            if int(target['triangle_origin'][i,1]) not in omitted[surface]:
                builders[surface].triangle(triangle,target['triangle_origin'][i],bool(target['collision_mask'][i]),int(target['collision_surface_types'][i]))
    for eye in selected:
        white=eye['surface'];pupil,pupil_faces,_=eye['pupil']
        # The white ring fills a real opening in the skin. An inscribed ellipse
        # would expose the old hole at each polygon corner. Interpolate the
        # original outer skin boundary instead, with smooth outward arc spans.
        outer_controls=eye['projected'][eye['outer']]
        outer_center=(outer_controls.min(axis=0)+outer_controls.max(axis=0))*.5
        order=np.argsort(np.arctan2(outer_controls[:,1]-outer_center[1],outer_controls[:,0]-outer_center[0]))
        outer_controls=outer_controls[order]
        per_edge=max(4,int(np.ceil(segments/len(outer_controls))))
        curved=[]
        for edge in range(len(outer_controls)):
            p0,p1,p2,p3=[outer_controls[(edge+offset)%len(outer_controls)] for offset in (-1,0,1,2)]
            direction=p2-p1
            outward=np.array([direction[1],-direction[0]])
            outward/=max(np.linalg.norm(outward),1e-12)
            for sample in range(per_edge):
                t=sample/per_edge
                value=.5*(2*p1+(-p0+p2)*t+(2*p0-5*p1+4*p2-p3)*t*t+(-p0+3*p1-3*p2+p3)*t*t*t)
                linear=p1*(1.-t)+p2*t
                inward=float((value-linear)@outward)
                if inward<0:value-=outward*inward
                curved.append(value)
        outer_xy=np.asarray(curved)
        segments=len(outer_xy)
        angles=np.arctan2(outer_xy[:,1]-outer_center[1],outer_xy[:,0]-outer_center[0])
        inner_controls=eye['projected'][eye['inner']]
        inner_middle=(inner_controls.min(axis=0)+inner_controls.max(axis=0))*.5
        inner_radius=(inner_controls.max(axis=0)-inner_controls.min(axis=0))*.5
        inner_xy=inner_middle+np.column_stack((np.cos(angles),np.sin(angles)))*inner_radius
        pupil_center=inner_xy.mean(axis=0)
        shared_positions=[]
        # Every shared inner-rim point has exactly the same position in both
        # materials, so the new rounded pupil can never leave a seam or hole.
        for coordinate in inner_xy:
            loop=eye['inner'];best=None
            for i,a in enumerate(loop):
                b=loop[(i+1)%len(loop)];pa,pb=eye['projected'][[a,b]]
                direction=pb-pa;t=float(np.clip(np.dot(coordinate-pa,direction)/max(np.dot(direction,direction),1e-12),0.,1.))
                projected=pa+t*direction;distance=float(np.linalg.norm(projected-coordinate))
                if best is None or distance<best[0]:best=(distance,a,b,t,projected)
            _,a,b,t,projected=best
            source=sources[white]
            point=source['positions'][:,a]*(1.-t)+source['positions'][:,b]*t
            # Tangent offset is transformed by the same least-squares native
            # pose deformation as the original ring, not a frozen world offset.
            offset=(coordinate-projected)@eye['axes'].T
            all_vertices=np.unique(source['indices'][eye['faces']])
            base=source['positions'][0,all_vertices];origin=base.mean(axis=0)
            for pose in range(len(point)):
                target=source['positions'][pose,all_vertices]
                matrix=np.linalg.lstsq(base-origin,target-target.mean(axis=0),rcond=None)[0]
                point[pose]+=offset@matrix
            parent=next(face for face in eye['faces'] if a in source['indices'][face] and b in source['indices'][face])
            bary=np.zeros(3)
            bary[int(np.flatnonzero(source['indices'][parent]==a)[0])]=1.-t
            bary[int(np.flatnonzero(source['indices'][parent]==b)[0])]=t
            point+=_corneal_lift(source,parent,bary,contexts[white])
            shared_positions.append(point)
        shared_positions=np.stack(shared_positions,axis=1)
        for surface,face_indices,is_pupil in ((white,eye['faces'],False),(pupil,pupil_faces,True)):
            source=sources[surface];builder=builders[surface]
            face_array=source['indices'][face_indices]
            coordinates2=(source['positions'][0]-eye['center'])@eye['axes']
            all_vertices=np.unique(face_array)
            base=source['positions'][0,all_vertices];origin=base.mean(axis=0)
            matrices=[np.linalg.lstsq(base-origin,source['positions'][p,all_vertices]-source['positions'][p,all_vertices].mean(axis=0),rcond=None)[0] for p in range(len(source['positions']))]
            def vertex(coordinate,shared_index=None):
                local,bary=_closest_bary(coordinate,coordinates2,face_array)
                parent=face_indices[local];face=source['indices'][parent]
                original_xy=bary@coordinates2[face]
                point=contexts[surface]['surface_evaluator'](parent,bary)
                offset=(coordinate-original_xy)@eye['axes'].T
                for pose,matrix in enumerate(matrices):point[pose]+=offset@matrix
                if shared_index is not None:point=shared_positions[:,shared_index].copy()
                normal=contexts[surface]['normal_evaluator'](parent,bary)
                # A slight corneal lift avoids coplanar fighting where the
                # rounded outer contour extends over its original skin edge.
                if shared_index is None:
                    point += _corneal_lift(source,parent,bary,contexts[surface])
                at=builder.vertex(point,normal,source['source_ids'][face,0],bary,
                                  bary@source['uv'][face] if source.get('uv') is not None else None,
                                  bary@source['colors'][face],[-1.,source.get('part_index',-1)])
                return at,parent
            row_ids=[]
            outward=np.cross(eye['axes'][:,0],eye['axes'][:,1])
            if outward[2]<0:outward=-outward
            if is_pupil:
                centre,parent=vertex(pupil_center)
                for ring in range(1,rings+1):
                    fraction=ring/rings;row=[]
                    for a in range(segments):
                        at,parent=vertex(pupil_center+(inner_xy[a]-pupil_center)*fraction,a if ring==rings else None);row.append(at)
                    row_ids.append(row)
                for a in range(segments):
                    builder.triangle([centre,row_ids[0][a],row_ids[0][(a+1)%segments]],
                                     [surface,parent],False,-1,orient=outward)
            else:
                for ring in range(rings+1):
                    fraction=ring/rings;row=[]
                    for a in range(segments):
                        at,parent=vertex(inner_xy[a]*(1.-fraction)+outer_xy[a]*fraction,a if ring==0 else None);row.append(at)
                    row_ids.append(row)
            for ring in range(len(row_ids)-1):
                for a in range(segments):
                    b=(a+1)%segments
                    for tri in ([row_ids[ring][a],row_ids[ring+1][a],row_ids[ring][b]],
                                [row_ids[ring][b],row_ids[ring+1][a],row_ids[ring+1][b]]):
                        builder.triangle(tri,[surface,parent],False,-1,orient=outward)
    result=[]
    for at,builder in enumerate(builders):
        target=builder.finish(.015)
        if builder.positions:
            if 'bevel_geometry' in refined[at]:target['bevel_geometry']=refined[at]['bevel_geometry']
            else:target.pop('bevel_geometry',None)
            target['eye_geometry']={'method':'smooth_skin_boundary_and_shared_oval_pupil','added_vertices':len(builder.positions),'triangles':builder.extra_triangles,'contour_segments':segments}
        result.append(target)
    return result,{'applied':True,'eyes':len(selected),'contour_segments':segments,'shared_rims':True}
