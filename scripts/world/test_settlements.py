"""Layout contracts: data preservation, connected paths and stable spare plots."""
import math
import unittest
from unittest.mock import patch
import numpy as np
import world


def build(kind,days=8,realms=1):
    work={f'2026-10-{i+1:02}':[dict(realmKey=f'kingdom{r}',realm=f'Kingdom {r}',key=f'plot{i}',plot=f'Plot {i}',bill=70,other=70) for r in range(realms)] for i in range(days)}
    with patch.object(world,'choose_archetype',return_value=kind):
        w=world.build_world(work,{'water':{},'rest':{}},{})[0]
        world.dress_towns(w)
        return w


class OrganicSettlements(unittest.TestCase):
    def check_plan(self,w):
        for realm in w.realm_list:
            p=realm.get('plan')
            if not p or not p.get('organic'):continue
            homes=[i for i in w.things if i['kind']=='house' and i['realm']==realm['index']]
            self.assertEqual(len(homes),p['used'])
            self.assertGreaterEqual(len(p['slots'])-p['used'],3)
            slots=p['slots']
            for i,a in enumerate(slots):
                for b in slots[i+1:]:
                    self.assertGreater(math.hypot(a[1]-b[1],(a[2]-b[2])/world.FLAT),30.9)
            start,end=realm['nodes'];seen={start};todo=[start]
            while todo:
                for n in w.path_links[todo.pop()]-seen:
                    seen.add(n);todo.append(n)
            self.assertTrue(set(range(start,end))<=seen)
            self.assertTrue(all(not i.get('block') for i in homes))

    def test_neighbours_vary_and_boundaries_have_openings(self):
        w=build('hill',12,2)
        for realm in w.realm_list:
            homes=[i for i in w.things if i['kind']=='house' and i['realm']==realm['index']]
            choices=realm['house_choices']
            for item in homes:
                near=min((other for other in homes if other is not item),key=lambda other:math.hypot(item['x']-other['x'],(item['z']-other['z'])/world.FLAT))
                a,b=choices[item['lot']],choices[near['lot']]
                self.assertNotEqual((a[0],a[1] if a[0]=='house' else 0),(b[0],b[1] if b[0]=='house' else 0))
            boundary=realm['plan']
            self.assertEqual(len(boundary['boundary']),49)
            self.assertEqual(len([i for i in w.things if i['realm']==realm['index'] and i['make']()[0]=='kingdom_wall']),48)
            self.assertEqual(boundary['gate_width'],28)

    def test_small_kingdoms_are_enclosed(self):
        w=build('grove',2)
        realm=w.realm_list[0]
        self.assertIsNone(realm.get('plan'))
        self.assertEqual(len(realm['boundary_plan']['boundary']),49)
        self.assertEqual(realm['boundary_plan']['wall_theme'],'stone')

    def test_every_ground_archetype(self):
        for kind in world.ARCHETYPES:
            with self.subTest(kind=kind):self.check_plan(build(kind))

    def test_multiple_realms_and_larger_history(self):
        w=build('hill',24,3);self.check_plan(w)
        for i,p in enumerate(w.plans):
            for q in w.plans[i+1:]:
                self.assertGreater(math.hypot(p['x']-q['x'],(p['z']-q['z'])/world.FLAT),p['wall']+q['wall']-1)

    def test_repeatable_and_archetype_variety(self):
        def layout(w):return [(i['x'],i['z']) for i in w.things if i['kind']=='house']
        self.assertEqual(layout(build('hill')),layout(build('hill')))
        self.assertNotEqual(layout(build('hill')),layout(build('grove')))

    def test_terrain_and_understory(self):
        w=build('grove');g=world.make_ground(w)
        self.assertTrue(np.isfinite(g['field']).all())
        self.assertTrue(((g['wet']>=0)&(g['wet']<=1)).all())
        world.fit_boundaries_to_shore(w,g)
        for item in w.things:
            if item['kind'] != 'wall':continue
            art=item['make']()
            if art[0]=='kingdom_wall':
                for t in range(9):
                    self.assertLess(world.paint.sample_wet(g,item['x']+art[1]*t/8,item['z']+art[2]*t/8),.08)
        before=len(w.things);world.dress_wilderness(w,g)
        self.assertGreater(len(w.things),before)
        homes=[i for i in w.things if i['kind'] in ('house','seat')]
        for item in w.things[before:]:
            self.assertLessEqual(world.paint.sample_wet(g,item['x'],item['z']),.3)
            self.assertTrue(all(math.hypot(item['x']-h['x'],(item['z']-h['z'])/world.FLAT)>=19 for h in homes))


if __name__=='__main__':unittest.main()
