"""Procedural fantasy house studies, exported as live WebGL geometry.

Shared house geometry for the world and the interactive design preview.
Run python scripts/world/house_study.py to rebuild the offline contact sheet.
"""
import argparse
import base64
import gzip
import json
import math
from pathlib import Path

import numpy as np
from iso import Model, asset_seed
from sprites import rgb, shade

TAU=math.tau
WOOD='#66503b'
PLASTER='#e2cfaa'
STONE='#aca58c'


class House(Model):
    def __init__(self,seed):
        super().__init__(seed)
        self.smoke=[]
        self.lights=[]
        self.flags=[]

    def scale(self,factor):
        super().scale(factor)
        self.smoke=[[v*factor for v in point] for point in self.smoke]
        self.flags=[[v*factor for v in point] for point in self.flags]
        self.lights=[[v*factor for v in point] for point in self.lights]

    def beam(self,a,b,r=.16,color=WOOD):
        self.rod(a,b,r,color)
        av,bv=np.array(a),np.array(b)
        for i in (-1,1):
            offset=np.array([r*.6*i,r*.6,r*.2])
            self.rod(av+offset,bv+offset,.017,shade(color,.24 if i<0 else -.3))

    def masonry_block(self,x,y,z,w,d,h):
        self.block(x,y,z,w,d,h,'#726f60')
        rows=max(1,round(h/.65))
        for front,length in ((True,w),(False,d)):
            for row in range(rows):
                count=max(1,round(length/1.15))
                for col in range(-1,count+1):
                    u=max(0,(col+row%2*.5)*length/count)
                    v=min(length,(col+1+row%2*.5)*length/count)
                    if v-u<.1:continue
                    zz=z+row*h/rows+.035
                    color=shade(STONE,self.rng.uniform(-.12,.15))
                    if front:self.block(x+u+.03,y+d-.02,zz,v-u-.06,.12,h/rows-.065,color)
                    else:self.block(x+w-.02,y+u+.03,zz,.12,v-u-.06,h/rows-.065,shade(color,-.1))

    def roof_tiles(self,x,y,z,w,d,rise,color):
        """Curved roof pitches with individually shaped, overlapping shingles."""
        x-=.85;y-=.85;w+=1.7;d+=1.7
        def height(t):
            return z+rise*(1-t)**1.55+.3*math.sin(t*math.pi*2)
        for side in (-1,1):
            # Dark continuous under-roof behind the separated shingle courses.
            for j in range(20):
                a,b=j/20,(j+1)/20
                self.poly([(x,y+d/2+side*a*d/2,height(a)-.035),(x+w,y+d/2+side*a*d/2,height(a)-.035),(x+w,y+d/2+side*b*d/2,height(b)-.035),(x,y+d/2+side*b*d/2,height(b)-.035)],shade(color,-.35))
            for row in range(11):
                t0=row/11;t1=min(1,(row+1.3)/11)
                cols=max(5,round(w/.72))
                for col in range(-1,cols):
                    xx=x+(col+.5*(row%2))*w/cols
                    x1=max(x,xx+.025);x2=min(x+w,xx+w/cols-.025)
                    if x2-x1<.12:continue
                    yy0=y+d/2+side*t0*d/2;yy1=y+d/2+side*t1*d/2
                    zz0,zz1=height(t0)+.09,height(t1)+.09
                    xxmid=(x1+x2)/2
                    face=self.poly([(x1,yy0,zz0),(x2,yy0,zz0),(x2,yy1,zz1+.025),(xxmid,yy1+side*.1,zz1),(x1,yy1,zz1+.025)],shade(color,self.rng.uniform(-.12,.15)+(.04 if side<0 else -.06)))
                    self.beam((x1,yy1,zz1),(x2,yy1,zz1),.025,shade(color,.28))
                    if (col+row)%4==0:
                        self.rod((xxmid,yy0,zz0+.02),(xxmid+.05,yy1,zz1+.03),.012,shade(color,-.24))
            for xx in (x,x+w):
                for j in range(12):
                    a,b=j/12,(j+1)/12
                    self.beam((xx,y+d/2+side*a*d/2,height(a)),(xx,y+d/2+side*b*d/2,height(b)),.13)
        # Plastered gables and their structural diagonals.
        for xx in (x+.45,x+w-.45):
            self.poly([(xx,y+.4,z),(xx,y+d-.4,z),(xx,y+d/2,z+rise-.2)],PLASTER)
            for yy in (y+.5,y+d-.5):self.beam((xx,yy,z),(xx,y+d/2,z+rise-.2),.14)
            self.beam((xx,y+d/2,z),(xx,y+d/2,z+rise-.3),.14)
        for i in range(max(2,round(w/.8))):
            xx=x+i*.8
            self.drum(xx,y+d/2,z+rise+.06,.23,.25,shade(color,.16),n=8)

    def front(self,x,y,z,w,h,color=PLASTER,timber=True):
        self.poly([(x,y,z),(x+w,y,z),(x+w,y,z+h),(x,y,z+h)],color)
        # Irregular limewash; actual surface polygons, not a bitmap texture.
        for _ in range(round(w*h*1.3)):
            xx,zz=x+self.rng.random()*w,z+self.rng.random()*h
            ww,hh=self.rng.uniform(.08,.3),self.rng.uniform(.05,.18)
            self.poly([(xx,y+.012,zz),(min(x+w,xx+ww),y+.012,zz),(min(x+w,xx+ww),y+.012,min(z+h,zz+hh)),(xx,y+.012,min(z+h,zz+hh))],shade(color,self.rng.uniform(-.05,.05)))
        if timber:
            for zz in (z,z+h*.48,z+h):self.beam((x,y+.07,zz),(x+w,y+.07,zz),.16)
            bays=max(2,round(w/2.8))
            for i in range(bays+1):
                xx=x+i*w/bays
                self.beam((xx,y+.08,z),(xx,y+.08,z+h),.15)
            for i in range(bays):
                a=x+i*w/bays;b=x+(i+1)*w/bays
                self.beam((a,y+.08,z+h*.48),(b,y+.08,z+h*.9),.085)

    def arch(self,x,y,z,w,h,color):
        r=w/2;shoulder=h-r
        points=[(x-r,y,z),(x+r,y,z),(x+r,y,z+shoulder)]
        points += [(x+math.cos(i*math.pi/12)*r,y,z+shoulder+math.sin(i*math.pi/12)*r) for i in range(13)]
        self.poly(points,color)

    def window(self,x,y,z,w=1.25,h=2,shutters=True):
        self.arch(x,y,z,w+.3,h+.2,'#c6ad7b')
        self.arch(x,y+.03,z+.12,w,h-.08,'#263c40')
        self.arch(x,y+.05,z+.22,w-.16,h-.3,'#d8ac63')
        self.lights.append([x,y+.07,z+h*.5,w*.5])
        for off in (-.22,.22):self.beam((x+off*w,y+.09,z+.2),(x+off*w,y+.09,z+h-.18),.035,'#5a4936')
        for zz in (z+.6,z+1.15):self.beam((x-w*.43,y+.1,zz),(x+w*.43,y+.1,zz),.035,'#5a4936')
        self.block(x-w*.7,y-.06,z-.15,w*1.4,.55,.2,'#b8a078')
        if shutters:
            for sign in (-1,1):
                xx=x+sign*w*.8
                self.block(xx-.22,y,z+.1,.44,.18,h*.75,'#58766c')
                for zz in (z+.35,z+h*.6):self.beam((xx-.22,y+.2,zz),(xx+.22,y+.2,zz),.035,WOOD)
                for j in range(3):self.beam((xx-.16+j*.16,y+.2,z+.15),(xx-.16+j*.16,y+.2,z+h*.72),.015,'#9ba381')

    def door(self,x,y,z):
        self.arch(x,y,z,2.5,4,'#bda57d')
        self.arch(x,y+.03,z,2.05,3.7,'#483b2e')
        for i in range(6):
            xx=x-.9+i*.3
            self.poly([(xx,y+.06,z+.1),(xx+.27,y+.06,z+.1),(xx+.27,y+.06,z+2.8),(xx,y+.06,z+2.8)],shade('#90704a',self.rng.uniform(-.1,.1)))
        for zz in (.65,2):
            self.block(x-.9,y+.07,z+zz,1.8,.1,.1,'#3d4540')
            for xx in (-.7,.7):self.drum(x+xx,y+.18,z+zz+.05,.065,.08,'#bd9a58',n=6)
        self.drum(x+.55,y+.22,z+1.45,.13,.12,'#d2ad65',n=10)
        self.arch(x,y+.08,z+2.7,1.65,.88,'#e6bd70')
        for j in (-.4,0,.4):self.beam((x+j,y+.12,z+2.7),(x+j*.6,y+.12,z+3.45),.045,WOOD)

    def planter(self,x,y,z,w=2.5):
        self.block(x-w/2,y,z,w,.7,.5,'#8d6143')
        for j in range(6):
            xx=x-w*.42+j*w/7
            self.beam((xx,y+.3,z+.4),(xx+.12,y+.3,z+.9),.025,'#658251')
            self.leaf(xx,y+.3,z+.7,.28,'#6c8b55')
            self.flower(xx+.12,y+.3,z+.95,('#c46f70','#edd5a0','#ba8db0')[j%3])

    def leaf(self,x,y,z,r,color):
        a=self.rng.random()*TAU
        v=np.array([math.cos(a),math.sin(a),.5])*r
        c=np.array([x,y,z]);u=np.array([-v[1],v[0],0])*.4
        self.poly([c-v,c+u,c+v,c-u],shade(color,self.rng.uniform(-.12,.16)))
        self.rod(c-v,c+v,.012,shade(color,.2))

    def flower(self,x,y,z,color):
        for j in range(5):
            a=j*TAU/5
            self.poly([(x,y,z),(x+math.cos(a)*.17,y+math.sin(a)*.17,z+.08),(x+math.cos(a+.7)*.17,y+math.sin(a+.7)*.17,z+.05)],color)
        self.drum(x,y,z+.06,.055,.04,'#e3b760',n=6)

    def ivy(self,x,y,z,h):
        for k in range(3):
            for i in range(round(h*6)):
                zz=z+i/6;xx=x+math.sin(i*.4+k)*.35+k*.23
                self.leaf(xx,y+.15,zz,self.rng.uniform(.13,.28),'#648058')
                if i%3==0:self.beam((xx,y,zz),(xx+.07,y,zz+.18),.018,'#786e48')

    def lantern(self,x,y,z):
        self.beam((x,y-.4,z+1.6),(x,y+.5,z+1.6),.06)
        self.beam((x,y+.5,z+1.6),(x,y+.5,z+1.1),.025,'#3f4943')
        self.block(x-.25,y+.25,z,.5,.5,.9,'#e5bb6c')
        for dx in (-.25,.25):
            for dy in (.25,.75):self.beam((x+dx,y+dy,z),(x+dx,y+dy,z+.95),.035,'#4b5143')
        self.drum(x,y+.5,z+.95,.43,.3,'#776c4b',n=4,r2=.1)
        self.lights.append([x,y+.5,z+.45,.6])

    def chimney(self,x,y,z,h=4):
        self.masonry_block(x,y,z,1.5,1.6,h)
        self.block(x-.16,y-.16,z+h,1.82,1.92,.3,'#c4b494')
        self.drum(x+.75,y+.8,z+h+.3,.46,.9,'#a36b47',n=10)
        self.drum(x+.75,y+.8,z+h+1.2,.52,.15,'#594937',n=10)
        self.smoke.append([x+.75,y+.8,z+h+1.35])

    def barrel(self,x,y,z=0):
        self.drum(x,y,z,.64,.3,'#78573c',n=12,r2=.78)
        self.drum(x,y,z+.3,.78,1.1,'#9c7850',n=12,r2=.78)
        self.drum(x,y,z+1.4,.78,.3,'#88663f',n=12,r2=.64)
        for zz in (.25,1.35):self.drum(x,y,z+zz,.8,.12,'#4e574d',n=12)
        for i in range(10):
            a=i*TAU/10
            self.beam((x+math.cos(a)*.78,y+math.sin(a)*.78,z+.35),(x+math.cos(a)*.78,y+math.sin(a)*.78,z+1.35),.015,WOOD)


def build(kind,seed,tier=2):
    m=House((kind,seed));r=m.rng
    variant=seed%8
    w=(8,12,9,11,8.5,10,12,9.5)[variant];d=8;h=(8.3,10.1,9.2,6.9)[kind]+(seed%2)*.5
    wall=('#e2cfaa','#d6c8a7','#d9c9b5')[seed%3]
    roof=('#a95e42','#496f6c','#536a7b','#727946')[kind]
    # Irregular ground stones, rather than a flat square pedestal.
    for i in range(54):
        x,y=r.uniform(-8,8),r.uniform(-5,8)
        if abs(x)<w*.47 and -3<y<3:continue
        m.block(x,y,-.1,r.uniform(.4,.9),r.uniform(.35,.7),r.uniform(.12,.26),shade(STONE,r.uniform(-.12,.14)))
    m.masonry_block(-w/2,-4,0,w,d,2.3)
    m.block(-w/2,-4,2.3,w,d,h-2.3,wall)
    m.front(-w/2,4.03,2.3,w,h-2.3,wall)
    # Detailed end wall, made by building in local front coordinates then rotating.
    start=len(m.faces);lights=len(m.lights)
    m.front(-4,w/2+.03,2.3,8,h-2.3,shade(wall,-.14))
    for yy in (-2,1.4):m.window(yy,w/2+.16,4.8,1.15,2,False)
    for f in m.faces[start:]:f.points=[(y,x,z) for x,y,z in f.points]
    for i in range(lights,len(m.lights)):
        x,y,z,rr=m.lights[i];m.lights[i]=[y,x,z,rr]
    m.door(-1,4.18,0)
    for x in (-3.2,2.6):m.window(x,4.2,4.7,1.15,2.1)
    m.planter(2.6,4.35,4.25)
    m.lantern(.7,4.25,2.6)
    for i in range(4):m.masonry_block(-2.4,7-i*.65,0,2.8,.66,(i+1)*.25)
    m.roof_tiles(-w/2,-4,h,w,d,(5,6.4,7.5,5.5,7,6,4.8,7.2)[variant],roof)
    m.chimney(-3,-2,h+2,5)
    # Dormer: a real intersecting room, with its own shingled gable and corbels.
    if kind!=2:
        m.block(-2,1.4,h+1,3,2.5,2.6,wall)
        m.front(-2,3.93,h+1,3,2.6,wall)
        m.window(-.5,4.08,h+1.2,1,1.8,False)
        m.roof_tiles(-2.2,1.3,h+3.6,3.4,2.8,2,roof)
    # Leaded circular attic window set into the visible gable.
    start=len(m.faces);old_lights=len(m.lights)
    m.window(0,w/2+.48,h+.65,1.25,2.1,False)
    for f in m.faces[start:]:f.points=[(y,x,z) for x,y,z in f.points]
    for j in range(old_lights,len(m.lights)):
        x,y,z,rr=m.lights[j];m.lights[j]=[y,x,z,rr]
    # Gable finials and a bent ornamental fascia.
    for xx in (-w/2-.8,w/2+.8):
        m.beam((xx,0,h+6.5),(xx,0,h+7.8),.09,'#ae9360')
        m.drum(xx,0,h+7.8,.18,.24,'#d0af69',n=8)
    for x in (-w/2+.3,w/2-.3):m.ivy(x,4.4,.4,6)
    m.barrel(w/2+1,2);m.barrel(w/2+1.4,.4)
    # Eight distinct building profiles, shared across the regional crafts.
    if variant in (1,4):
        ah=4.8 if variant==1 else 7.2
        m.masonry_block(w/2,-3,0,3,6,1.3)
        m.block(w/2,-3,1.3,3,6,ah-1.3,wall)
        m.front(w/2,3.04,1.3,3,ah-1.3,wall)
        m.window(w/2+1.5,3.15,2,.9,1.7,False)
        m.roof_tiles(w/2,-3,ah,3,6,2.7,roof)
    elif variant==2:
        m.block(-3,4,3.6,6,2.5,.4,'#8a6846')
        for x in (-3,0,3):m.beam((x,6,0),(x,6,7),.13)
        for x in range(-3,4):m.beam((x,6.3,4),(x,6.3,5.2),.07)
        m.beam((-3,6.3,5.2),(3,6.3,5.2),.1)
        m.roof_tiles(-3.3,4,7,6.6,2.8,2.2,roof)
    elif variant==3:
        m.masonry_block(-w/2-2,-3,0,2,6,5)
        m.roof_tiles(-w/2-2.4,-3.3,5,2.8,6.6,2.1,roof)
        m.barrel(-w/2-2,4)
    elif variant==5:
        m.masonry_block(-2.6,4,0,5.2,3,3.5)
        m.door(-.2,7.1,0)
        m.roof_tiles(-2.9,3.8,3.5,5.8,3.6,3.1,roof)
    elif variant==6:
        for x in (-3,2):
            m.block(x,1,h,2.5,3,2.8,wall)
            m.window(x+1.2,4.15,h+.4,.9,1.7,False)
            m.roof_tiles(x-.2,1,h+2.8,2.9,3.2,2.2,roof)
    elif variant==7:
        m.masonry_block(w/2-1,-3,0,3,4,h+2)
        m.roof_tiles(w/2-1.4,-3.4,h+2,3.8,4.8,4,roof)
        m.window(w/2+.5,1.2,h-1,1,1.7,False)
    # Structural brackets under the wide eave.
    for x in (-4,-2,0,2,4):
        m.beam((x,3.8,h-1),(x,4.7,h-.1),.09)
        m.beam((x,3.8,h-.1),(x,4.7,h-.1),.09)
    if kind==0:
        # Hearth cottage: lower bakehouse, awning and seasoned log stack.
        m.masonry_block(-8,-1,0,3,5,2)
        m.block(-8,-1,2,3,5,2.5,wall)
        m.window(-6.5,4.12,2.4,1,1.5,False)
        m.roof_tiles(-8,-1,4.5,3,5,2.4,roof)
        for i in range(9):
            x=-7+(i%3)*.6;z=.4+(i//3)*.5
            m.beam((x,5,z),(x,6.5,z),.24,'#9b784d')
            m.drum(x,6.5,z,.2,.05,'#ceb17d',n=8)
    elif kind==1:
        # Merchant home: projecting upper bay and a striped linen shop canopy.
        m.block(1,4.3,4.5,3,1.5,2.5,wall)
        m.front(1,5.82,4.5,3,2.5,wall)
        for x in (1.7,3.1):m.window(x,5.9,4.8,.85,1.7,False)
        m.roof_tiles(1,4.3,7,3,1.5,1.2,roof)
        for x in (1,4):m.beam((x,4.3,3.4),(x,5.8,4.5),.15)
        for i in range(10):
            x=1+i*.42;col='#d4bd91' if i%2 else '#567e71'
            m.poly([(x,4.4,3.3),(x+.42,4.4,3.3),(x+.42,7,2.7),(x,7,2.7)],col)
            m.poly([(x,7,2.7),(x+.42,7,2.7),(x+.42,7,2.35),(x+.21,7,2.2),(x,7,2.35)],col)
        for x in (1,5.2):m.beam((x,7,0),(x,7,2.8),.09)
        m.block(1,6,.2,4,1,1,'#947044')
        for i in range(12):m.flower(1.3+(i%6)*.6,6.3+i//6*.4,1.25,'#b58756')
        m.beam((5,3,6),(5,6,6),.09)
        m.block(4.3,5.5,3.9,1.4,.2,1.5,'#365952')
        m.flags.append([5,5.8,5.3])
    elif kind==2:
        # Alchemist: hexagonal turret, curved conical shingles, astrolabe.
        m.drum(4,-2,0,2.6,14,wall,n=12,r2=2.2)
        for zz in (1,7,12):m.drum(4,-2,zz,2.65,.22,'#958970',n=12)
        for j in range(20):
            t=j/20;rr=3.5*(1-t)**.8+.1
            m.drum(4,-2,14+t*9,rr,.46,shade(roof,-.3),n=20,r2=max(.05,3.5*(1-(j+1)/20)**.8+.1))
        for row in range(13):
            t=row/13;radius=3.5*(1-t)**.8+.1;z=14+t*9
            for j in range(20):
                a=(j+.5*(row%2))*TAU/20;b=a+TAU/20*.96
                rr=max(.06,3.5*(1-min(1,t+1.15/13))**.8+.1)
                m.poly([(4+math.cos(a)*radius,-2+math.sin(a)*radius,z),(4+math.cos(b)*radius,-2+math.sin(b)*radius,z),(4+math.cos(b)*rr,-2+math.sin(b)*rr,z+.9),(4+math.cos(a)*rr,-2+math.sin(a)*rr,z+.9)],shade(roof,r.uniform(-.12,.12)))
        m.beam((4,-2,23),(4,-2,25),.08,'#d2ac61')
        for j in range(24):
            a,b=j*TAU/24,(j+1)*TAU/24
            m.beam((4+math.cos(a)*.7,-2,24+math.sin(a)*.7),(4+math.cos(b)*.7,-2,24+math.sin(b)*.7),.035,'#d2ac61')
        m.window(3.9,.3,10,.8,1.7,False)
        m.flags.append([4,-2,24.5])
        for x in (-3,2.6):
            for j in range(4):m.drum(x+j*.25,4.8,4.25,.09,.3,('#7d9c8b','#b28264','#9a87ad')[j%3],n=7)
    else:
        # Herbalist: raised timber conservatory and an irregular root pergola.
        m.block(-8,0,1,3,5,3,WOOD)
        for x in (-8,-5):
            for y in (0,5):m.beam((x,y,0),(x,y,5),.18)
        for i in range(5):
            x=-8+i*.7
            m.poly([(x,0,4.3),(x+.6,0,4.3),(x+.6,5,4.8),(x,5,4.8)],'#9bb8a1')
            m.beam((x,0,4.4),(x,5,4.9),.055,WOOD)
        for x in (-7.5,-6.5,-5.5):m.planter(x,3.5,1.5,.8)
        for y in (0,2.5,5):m.beam((-8,y,4.5),(-5,y,4.5),.07)
        for j in range(8):
            x=-5+j*.6
            m.beam((x,4.5,7),(x,4.5,6.3),.02,'#b4a078')
            for i in range(4):m.leaf(x+(i-2)*.06,4.6,6.2-i*.12,.18,'#92915b')
        m.ivy(-5,4.6,0,9)
    for j in range(24):
        x,y=r.uniform(-8,8),r.uniform(4.5,8)
        if -2.5<x<.5:continue
        m.leaf(x,y,.4,.24,'#6c8b55')
        if j%3==0:m.flower(x,y,.65,'#cf8b89')
    if tier != 2: m.scale(.85+max(0,min(5,tier))*.075)
    return m


def export(model):
    """Triangles with vertex color and emission; no rendered images/textures."""
    data=[]
    for face in model.faces:
        if len(face.points)<3:continue
        col=rgb(face.color) if isinstance(face.color,str) else face.color
        color=[round(c/255,4) for c in col[:3]]
        emission=1 if col[0]>185 and col[1]>140 and col[2]<150 else 0
        # All study polygons are convex; roof shingles are fan-triangulated.
        for i in range(1,len(face.points)-1):
            for p in (face.points[0],face.points[i],face.points[i+1]):data.extend([round(float(v),4) for v in p]+color+[emission*.12])
    return dict(vertices=data,smoke=model.smoke,lights=model.lights,flags=model.flags,faces=len(model.faces))


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--out',type=Path,default=Path(__file__).resolve().parents[2]/'previews/world-houses');args=parser.parse_args()
    args.out.mkdir(parents=True,exist_ok=True)
    samples=[dict(name=name,subtitle=subtitle,variants=[export(build(i,seed)) for seed in range(3)]) for i,(name,subtitle) in enumerate((('Hearth Cottage','Timber frame · Bakehouse · Curved tile roofs'),('Guild House','Erker · Marketstand · grüne Schindeln'),('Alchemist House','Spired tower · Astrolabe · Leaded glass'),('Herbalist House','Climbing vines · Conservatory · Drying herbs')))]
    payload=gzip.compress(json.dumps(samples,separators=(',',':')).encode(),compresslevel=9)
    (args.out/'houses.js').write_text('window.HOUSE_DATA='+json.dumps(base64.b64encode(payload).decode())+';\n')
    print(f'Exported {len(samples)} houses × 3 seeds to {args.out}')


if __name__=='__main__':main()
