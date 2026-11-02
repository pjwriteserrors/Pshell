"""Bounded contract tests for the fantasy sprite replacement.
Run: python -m unittest discover -s scripts/world -p test_assets.py
"""
import os
from pathlib import Path
import subprocess
import sys
import unittest

import iso
import sprites


class FantasyAssets(unittest.TestCase):
    def test_all_asset_families_render(self):
        culture={'name':'alpine'}
        arts=[(name,2) for name in ('ferns','reeds','fallen_log','dead_tree','shrine','lantern_post','palm','great_tree','sheep','flowers','rock','cart','crates','statue','milestone','fire','ruin','market','tourney','lighthouse','boat','harbour_ship','bridge','spring_head','mist','elf_tower','stall','field','hedge','forge','arena','theatre','mountain','tavern')]
        arts += [(name,'leaf',2) for name in ('oak','birch','pine')]
        arts += [('house',{'name':c},2,3) for c in iso.CULTURES]
        arts += [('fhouse',style,culture,2,3) for style in ('turret','crooked','mushroom','treehouse','dome','dwarf','crystal','wizard')]
        arts += [('seatx',style,culture,3,2) for style in ('spires','palace','gate','tree','citadel','wizard')]
        arts += [('landmark',style,2) for style in ('tree','stones','crystal','portal','dragon')]
        arts += [('seat',culture,3,2),('temple',culture,2),('windmill',culture,2),('wall_tower',culture),('gatehouse',culture),('world_tree',1),('fountain',0),('well',0),('gold_pile',3,2),('terrace',30,16,8,2,[.7]),('terrace',30,16,8,2,[.7],'water'),('ground_square',24,2),('plaza',14),('steps',15,-12,5),('wall',-14,8),('floating_isle',20,2),('isle_shadow',20),('rope',16,-9)]
        for art in arts:
            with self.subTest(asset=art):
                image,ax,ay=iso.draw(art)
                self.assertEqual(image.mode,'RGBA')
                self.assertIsNotNone(image.getbbox())
                self.assertGreaterEqual(ax,0)
                self.assertGreaterEqual(ay,0)
                self.assertLessEqual(ax,image.width/sprites.FINAL)
                self.assertLessEqual(ay,image.height/sprites.FINAL)

    def test_live_animation_contracts(self):
        for frame in (0,1):
            self.assertEqual(iso.person(3,frame)[0].size,(36,48))
            self.assertEqual(iso.golem(frame)[0].size,(72,96))
        for make in (iso.sails,lambda:iso.smoke(0),lambda:iso.flag(0),lambda:iso.foundation(0),lambda:iso.scaffold(0)):
            self.assertIsNotNone(make()[0].getbbox())

    def test_effect_sockets_are_on_the_new_sprites(self):
        culture={'name':'alpine'}
        for art in (('house',culture,2,3),('seat',culture,3,2),('seatx','palace',culture,3,2),('windmill',culture,2)):
            image,ax,ay=iso.draw(art)
            for points in iso.attachments(art).values():
                for x,y in points:
                    self.assertTrue(0<ax+x<image.width/sprites.FINAL,art)
                    self.assertTrue(0<ay+y<image.height/sprites.FINAL,art)

    def test_depth_is_independent_of_face_insertion(self):
        def render(reverse):
            m=iso.Model();m.shadow=(0,0)
            back=[(-2,0,0),(2,0,0),(2,0,4),(-2,0,4)]
            front=[(x+2,y+2,z+2) for x,y,z in back]
            faces=[(back,'#ff0000'),(front,'#00ff00')]
            for p,c in (reversed(faces) if reverse else faces):m.poly(p,c)
            return m.finish()[0]
        self.assertEqual(render(False).tobytes(),render(True).tobytes())

    def test_rebuild_is_stable_across_processes(self):
        path=str(Path(__file__).resolve().parent)
        code=f"import sys,hashlib;sys.path.insert(0,{path!r});import iso;print(hashlib.sha256(iso.draw(('house',{{'name':'alpine'}},2,3))[0].tobytes()).hexdigest())"
        hashes=[subprocess.check_output([sys.executable,'-c',code],env={**os.environ,'PYTHONHASHSEED':str(seed)}) for seed in (1,937)]
        self.assertEqual(*hashes)


if __name__=='__main__':unittest.main()
