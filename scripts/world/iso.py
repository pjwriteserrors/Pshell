"""Atelier: a wholly new isometric asset library.

Geometry is constructed in three dimensions, with surface-bound ornament and
stable seeded variations. Only the sprite names and ground anchors are shared
with the previous library. One warm north-west light unifies the miniatures.
"""
import hashlib
import math
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
import sprites as sp
from sprites import Sheet, rgb, shade

TAU = math.tau
CULTURES = {
    'nordic': ('#a88661', '#3f625f', '#dac9a0', '#493e36'),
    'alpine': ('#e8d6b4', '#aa5140', '#e9b85d', '#574338'),
    'southern': ('#ecd7ae', '#c67e52', '#4d9290', '#715343'),
    'hanse': ('#b27659', '#40556a', '#d6ad59', '#483b35'),
    'eastern': ('#e1d6be', '#427d79', '#c75d45', '#4c4543'),
    'arcane': ('#bdc1be', '#585a82', '#a7d8cd', '#44495d'),
}


def asset_seed(*parts):
    return int.from_bytes(hashlib.blake2b(repr(parts).encode(), digest_size=8).digest(), 'big')


def project(p):
    x, y, z = p
    return x - y, (x + y) * .5 - z


class Surface:
    """Ornament lives on its parent plane, never floating in front of a roof."""
    def __init__(self, points, color):
        self.points, self.color, self.marks = points, color, []
        self.flecks = []

    def rect(self, u, v, w, h, color):
        self.marks.append(([(u,v),(u+w,v),(u+w,v+h),(u,v+h)], color, 0))

    def line(self, points, color, width=.12):
        self.marks.append((points, color, width))

    def at(self, uv):
        u,v = uv
        a,b,c,d = [project(p) for p in self.points]
        return tuple((a[i]*(1-u)+b[i]*u)*(1-v)+(d[i]*(1-u)+c[i]*u)*v for i in (0,1))


class Model:
    def __init__(self, seed=0):
        self.rng = random.Random(asset_seed(seed))
        self.faces = []
        self.shadow = (8,4)

    def poly(self, points, color):
        f = Surface(points, color)
        self.faces.append(f)
        return f

    def block(self, x,y,z,w,d,h,color, dress=None):
        a = self.poly([(x,y+d,z+h),(x+w,y+d,z+h),(x+w,y+d,z),(x,y+d,z)],shade(color,.08))
        b = self.poly([(x+w,y+d,z+h),(x+w,y,z+h),(x+w,y,z),(x+w,y+d,z)],shade(color,-.22))
        self.poly([(x,y,z+h),(x+w,y,z+h),(x+w,y+d,z+h),(x,y+d,z+h)],shade(color,.23))
        if dress:
            for face,length in ((a,w),(b,d)):
                self.masonry(face,length,h,dress)
        return a,b

    def masonry(self, face,w,h,kind):
        rows = max(2,round(h/(.75 if kind=='brick' else 1.7)))
        cols = max(2,round(w/(1.3 if kind=='brick' else 2.8)))
        for row in range(rows):
            face.line([(0,(row+1)/rows),(1,(row+1)/rows)],shade(face.color,-.16),.09)
            for col in range(cols):
                u = (col + .5*(row%2))/cols
                face.line([(u,row/rows),(u,(row+1)/rows)],shade(face.color,-.18),.08)
                if self.rng.random()<.3:
                    face.rect(u+.015,row/rows+.025,min(.7/cols,1-u-.015),.65/rows,shade(face.color,self.rng.uniform(-.06,.06)))

    def rod(self,a,b,r,color):
        # A square beam follows any spatial direction.
        av,bv=np.array(a,float),np.array(b,float)
        axis=bv-av
        if np.linalg.norm(axis)<1e-6: return
        side=np.cross(axis,[0,0,1])
        if np.linalg.norm(side)<1e-6: side=np.array([1.,0,0])
        side=side/np.linalg.norm(side)*r
        up=np.cross(axis,side); up=up/np.linalg.norm(up)*r
        ring=[side+up,-side+up,-side-up,side-up]
        for i in range(4):
            self.poly([av+ring[i],bv+ring[i],bv+ring[(i+1)%4],av+ring[(i+1)%4]],shade(color,(.12,-.18,-.26,.02)[i]))

    def drum(self,x,y,z,r,h,color,n=10,top=None,r2=None):
        r2=r if r2 is None else r2
        base=[(x+math.cos(i*TAU/n)*r,y+math.sin(i*TAU/n)*r,z) for i in range(n)]
        rim=[(x+math.cos(i*TAU/n)*r2,y+math.sin(i*TAU/n)*r2,z+h) for i in range(n)]
        for i in range(n):
            lum=.13*math.cos(i*TAU/n+2)-.08
            self.poly([base[i],base[(i+1)%n],rim[(i+1)%n],rim[i]],shade(color,lum))
        self.poly(rim,top or shade(color,.2))

    def roof(self,x,y,z,w,d,rise,color,kind='gable'):
        x-=.7; y-=.7; w+=1.4; d+=1.4
        if kind=='hip':
            ridge=[(x+w*.25,y+d*.5,z+rise),(x+w*.75,y+d*.5,z+rise)]
            planes=[[(x,y,z),(x+w,y,z),ridge[1],ridge[0]],[(x+w,y,z),(x+w,y+d,z),ridge[1]],[(x+w,y+d,z),(x,y+d,z),ridge[0],ridge[1]],[(x,y+d,z),(x,y,z),ridge[0]]]
        elif kind=='butterfly':
            return self.roof(x+.7,y+.7,z,w-1.4,d-1.4,rise*1.8,color,'gable')
        else:
            # Storybook roof: steep upper pitch and swept, overhanging eaves.
            profile=[(0,.5),(.18,rise*.42),(.46,rise*1.5),(.74,rise*.5),(1,.35)]
            planes=[]
            for (t0,h0),(t1,h1) in zip(profile,profile[1:]):
                planes.append([(x,y+d*t0,z+h0),(x+w,y+d*t0,z+h0),(x+w,y+d*t1,z+h1),(x,y+d*t1,z+h1)])
            self.poly([(x+w,y,z),(x+w,y+d,z)]+[(x+w,y+d*t,z+h) for t,h in reversed(profile)],shade(color,-.3))
            self.poly([(x,y,z)]+[(x,y+d*t,z+h) for t,h in profile]+[(x,y+d,z)],shade(color,-.1))
        for index,points in enumerate(planes):
            f=self.poly(points,shade(color,.08 if index==0 else -.12))
            if len(points)==4:
                for row in range(1,8):
                    f.line([(0,row/8),(1,row/8)],shade(color,-.27),.12)
                    for col in range(1,max(3,round(w/1.8))):
                        u=(col-.4*(row%2))/max(3,round(w/1.8))
                        f.line([(u,(row-1)/8),(u,row/8)],shade(color,-.2),.065)
                f.line([(0,1),(1,1)],shade(color,.3),.22)
        self.rod((x,y+d,z),(x+w,y+d,z),.22,shade(color,-.4))

    def foliage(self,x,y,z,rx,ry,rz,color,seed=0):
        rng=random.Random(asset_seed('foliage',seed))
        rings=[]; n=9
        for j in range(5):
            a=-math.pi/2+(j+.15)*math.pi/4.3
            rings.append([(x+math.cos(i*TAU/n)*math.cos(a)*rx*rng.uniform(.83,1.13),y+math.sin(i*TAU/n)*math.cos(a)*ry*rng.uniform(.83,1.13),z+math.sin(a)*rz*rng.uniform(.9,1.08)) for i in range(n)])
        for j in range(4):
            for i in range(n):
                a,b,c,d=rings[j][i],rings[j][(i+1)%n],rings[j+1][(i+1)%n],rings[j+1][i]
                light=.12*(j-1)-.14*math.sin(i*TAU/n)+rng.uniform(-.05,.05)
                for triangle,tone in (([a,b,c],light),([a,c,d],light+.035)):
                    face=self.poly(triangle,shade(color,tone))
                    for _ in range(4):
                        u,v=rng.random(),rng.random()
                        if u+v>1: u,v=1-u,1-v
                        point=tuple(triangle[0][k]*(1-u-v)+triangle[1][k]*u+triangle[2][k]*v for k in range(3))
                        face.flecks.append((point,rng.uniform(.16,.35),shade(color,tone+.15)))
        self.poly(rings[-1],shade(color,.26))

    def scale(self, factor):
        for face in self.faces:
            face.points=[tuple(float(v)*factor for v in point) for point in face.points]
            face.flecks=[(tuple(v*factor for v in point),radius*factor,color) for point,radius,color in face.flecks]
        self.shadow=tuple(v*factor for v in self.shadow)

    def finish(self):
        pts=[project(p) for f in self.faces for p in f.points]
        if not pts: raise ValueError('empty asset')
        rx,ry=self.shadow
        width=math.ceil(2*max(rx+4,max(abs(p[0]) for p in pts)+2))
        up=math.ceil(max(ry+3,-min(p[1] for p in pts)+3))
        down=math.ceil(max(ry+4,max(p[1] for p in pts)+3))
        # Per-pixel depth avoids the intersecting roofs and hollow mushroom caps
        # that sorting entire polygons by their centres would produce.
        scale=sp.FINAL if width>180 else sp.FINAL*2
        size=(width*scale,(up+down)*scale)
        canvas=np.zeros((size[1],size[0],4),dtype=np.uint8)
        depth=np.full((size[1],size[0]),-np.inf,dtype=np.float32)
        def screen(p):
            px,py=project(p)
            return (px+width/2)*scale,(py+up)*scale
        for f in self.faces:
            pp=np.array([screen(p) for p in f.points])
            left=max(0,int(math.floor(pp[:,0].min()))-1); right=min(size[0],int(math.ceil(pp[:,0].max()))+2)
            top=max(0,int(math.floor(pp[:,1].min()))-1); bottom=min(size[1],int(math.ceil(pp[:,1].max()))+2)
            if right<=left or bottom<=top:continue
            matrix=np.column_stack((pp,np.ones(len(pp))))
            coef,_,rank,_=np.linalg.lstsq(matrix,np.array([sum(p) for p in f.points]),rcond=None)
            if rank<3:continue
            tile=Image.new('RGBA',(right-left,bottom-top));draw=ImageDraw.Draw(tile)
            points=[(float(x-left),float(y-top)) for x,y in pp]
            tone=rgb(f.color) if isinstance(f.color,str) else f.color
            draw.polygon(points,fill=tuple(tone))
            def local(p):return (p[0]+width/2)*scale-left,(p[1]+up)*scale-top
            for point,radius,color in f.flecks:
                px,py=project(point)
                draw.polygon([local(q) for q in ((px-radius,py),(px,py-radius*.65),(px+radius,py-.05),(px,py+radius*.4))],fill=color)
            for points,color,line in f.marks:
                points=[local(f.at(p)) for p in points]
                tone=rgb(color) if isinstance(color,str) else color
                if line: draw.line(points,fill=tone,width=max(1,round(line*scale)))
                else: draw.polygon(points,fill=tone)
            # Surface ornament cannot protrude through another plane at its edge.
            mask=Image.new('L',tile.size);ImageDraw.Draw(mask).polygon([(float(x-left),float(y-top)) for x,y in pp],fill=255)
            pixels=np.asarray(tile).copy();pixels[:,:,3]=np.minimum(pixels[:,:,3],np.asarray(mask))
            yy,xx=np.ogrid[top:bottom,left:right]
            zz=coef[0]*xx+coef[1]*yy+coef[2]
            take=(pixels[:,:,3]>0)&(zz>=depth[top:bottom,left:right]-.00001)
            canvas[top:bottom,left:right][take]=pixels[take]
            depth[top:bottom,left:right][take]=zz[take]
        shadow=Image.new('L',size)
        if rx>0 and ry>0:
            ImageDraw.Draw(shadow).ellipse(((width/2+2-rx)*scale,(up+1-ry)*scale,(width/2+2+rx)*scale,(up+1+ry)*scale),fill=65)
            shadow=shadow.filter(ImageFilter.GaussianBlur(scale*.8))
        out=Image.new('RGBA',size,(33,43,40,0));out.putalpha(shadow)
        out.alpha_composite(Image.fromarray(canvas))
        out=out.resize((width*sp.FINAL,(up+down)*sp.FINAL),Image.Resampling.LANCZOS)
        return out,width/2,up



def model(seed=0):
    # All world geometry uses the same detailed materials as the approved study.
    from detailed import RichModel
    return RichModel(seed)


def opening(face,u,v,w=.15,h=.26,trim='#efe1b7',lit=False):
    face.rect(u-.025,v-.025,w+.05,h+.05,trim)
    face.rect(u,v,w,h,'#edc47f' if lit else '#283e48')
    face.rect(u+.025,v+.02,w*.36,h*.38,'#98b7b2')
    face.line([(u+w*.5,v),(u+w*.5,v+h)],trim,.13)
    face.line([(u,v+h*.52),(u+w,v+h*.52)],trim,.12)
    face.rect(u-.04,v+h,w+.08,.035,shade(trim,-.17))


def facade(m,face,count=3,timber=False,door=False):
    if timber:
        for u in (0,.33,.66,1): face.line([(u,0),(u,1)],'#5a473c',.32)
        face.line([(0,.56),(1,.56)],'#5a473c',.3)
        for u in (0,.66): face.line([(u,.56),(u+.3,.03)],'#5a473c',.22)
    for i in range(count):
        opening(face,(i+.3)/count,.15,.48/count,.26,lit=i%3==0)
    if door:
        face.rect(.41,.59,.19,.41,'#574d40')
        face.rect(.435,.64,.12,.31,'#2e4142')
        face.rect(.52,.8,.025,.035,'#eac57c')
    else:
        for i in range(count): opening(face,(i+.3)/count,.62,.48/count,.23)


def pot(m,x,y,z=0,color='#a95f48',flowers=False):
    m.drum(x,y,z,.65,1,color,n=7,r2=.9)
    m.foliage(x,y,z+1.6,1.1,.9,.9,'#6f8e58',int(x*17+y*31))
    if flowers:
        for a in range(3): m.drum(x+math.cos(a*2)*.55,y+math.sin(a*2)*.55,z+2.2,.25,.12,'#efc77c',n=5)


def stairs(m,x,y,z,w,n=3,axis='y'):
    for i in range(n):
        if axis=='y': m.block(x,y-i*.8,z,w,.85,(i+1)*.5,'#b7ad91')
        else: m.block(x-i*.8,y,z,.85,w,(i+1)*.5,'#b7ad91')


def residence(culture,tier,seed,style=None):
    """Six architectural families with different massing, not recolored copies."""
    m=model(('home',culture,tier,seed,style)); wall,roof,accent,wood=CULTURES.get(culture,CULTURES['alpine'])
    tier=max(0,min(4,int(tier))); h=6+tier*1.3
    m.shadow=(13,6)
    # Broken stone doorstep: no square lawn tile around every house.
    for x,y in ((-4,7),(-2,8),(0,8),(2,8),(4,7)):
        m.block(x,y,0,1.7,1.3,.25,'#b4ac91')
    if culture=='nordic':
        # Long boathouse, steep roof, raised side porch, stacked firewood.
        a,b=m.block(-7,-4,1,14,8,h,wall)
        for face in (a,b):
            for row in range(8): face.line([(0,row/8),(1,row/8)],wood,.18)
        facade(m,a,3,door=True); facade(m,b,2)
        m.roof(-7,-4,1+h,14,8,6,roof)
        m.block(-8,4,0,8,3,1,wood)
        for x in (-7,-4,-1): m.rod((x,6,1),(x,6,4),.14,wood)
        m.rod((-7,6,3),(-1,6,3),.12,accent)
        for i in range(4): m.drum(6,5+i*.55,.4,.45,2,wood,n=6)
        m.rod((-8,0,h+9),(8,0,h+9),.25,wood)
        for xx in (-8,8):
            m.rod((xx,0,h+9),(xx*1.15,0,h+11),.3,wood)
            m.poly([(xx*1.15,0,h+10),(xx*1.35,0,h+11),(xx*1.15,0,h+12)],accent)
    elif culture=='southern':
        # L-shaped courtyard residence, roof terrace and shaded pergola.
        a,b=m.block(-6,-5,0,7,10,h,wall); facade(m,a,2,door=True); facade(m,b,2)
        c,d=m.block(1,-5,0,6,5,h*.65,wall); facade(m,c,2)
        m.roof(-6,-5,h,7,10,4.5,roof)
        m.drum(-2,-2,h+6,2.2,2,accent,n=10,r2=2.7)
        m.drum(-2,-2,h+8,2.7,4,accent,n=10,r2=.1)
        m.block(1,-5,h*.65,6,5,.4,'#e7d7ac')
        for px,py,pw,pd in ((1,-5,6,.4),(6.6,-5,.4,5),(1,-.4,6,.4)): m.block(px,py,h*.65,pw,pd,1.3,wall)
        for x in (2,6): m.rod((x,5,0),(x,5,5.5),.18,wood)
        for x in range(2,7): m.rod((x,0,5.5),(x,5.5,5.5),.12,wood)
        for y in (1,3,5): m.rod((1.5,y,5.5),(6.5,y,5.5),.14,wood)
        pot(m,4,3,flowers=True)
    elif culture=='hanse':
        # Tall narrow merchant house with stepped gable and hanging hoist.
        a,b=m.block(-4,-6,0,8,11,h+4,wall,'brick'); facade(m,a,2,door=True); facade(m,b,3)
        m.roof(-4,-6,h+4,8,11,4,roof)
        for i in range(4): m.block(-4+i,-6,h+4,8-2*i,.7,i+1.2,wall)
        m.block(-5,5,0,10,2,.8,'#aaa18a')
        m.rod((3,4,h+3),(3,8,h+3),.22,wood)
        m.rod((3,8,h+3),(3,8,h-1),.06,'#b29d74')
        m.block(2.2,7.2,h-2,1.6,1.6,1.4,'#af8958')
    elif culture=='eastern':
        # Teahouse on an open ground-floor arcade and a broad tiered roof.
        for x in (-5,0,5):
            for y in (-4,4): m.rod((x,y,0),(x,y,4.2),.3,wood)
        m.block(-5.8,-4.8,3.8,11.6,9.6,.7,wood)
        a,b=m.block(-5,-4,4.5,10,8,h*.7,wall); facade(m,a,3); facade(m,b,2)
        m.roof(-6,-5,4.5+h*.7,12,10,4.5,roof)
        m.roof(-3,-2,9.5+h*.7,6,4,3.2,roof)
        for x in (-5,5):
            m.rod((x,5,2),(x,5,5),.12,wood); m.drum(x,5,2.2,.7,1.2,accent,n=8)
        stairs(m,-2,7,0,4,4)
    elif culture=='arcane':
        # Observatory loft: octagonal tower, offset glass lantern and workshop.
        m.drum(-1,0,0,5,h+4,wall,n=8)
        m.drum(-1,0,h+4,6,.7,wood,n=8)
        m.drum(-1,0,h+4.7,5,11,roof,n=8,r2=.2)
        m.drum(-1,0,h+16,1.2,2,accent,n=8,r2=.1)
        a,b=m.block(2,-3,0,5,7,5,wall); facade(m,a,2,door=True)
        m.roof(2,-3,5,5,7,2,roof,'butterfly')
        for i in range(4):
            ang=i*math.pi/2
            m.rod((-1+math.cos(ang)*5,math.sin(ang)*5,2),(-1+math.cos(ang)*5,math.sin(ang)*5,h+3),.16,wood)
        m.drum(-1,0,h+18,1.2,.7,'#ecd38b',n=8)
    else:
        # Asymmetric chalet: stone lower floor, overhanging loft, side stair.
        a,b=m.block(-5,-4,0,10,8,4,'#a7a390','stone'); facade(m,a,2,door=True)
        a,b=m.block(-6,-4.5,4,12,9,h-1,wall); facade(m,a,3,True); facade(m,b,2,True)
        m.roof(-6,-4.5,h+3,12,9,5,roof)
        spire(m,5,-3,4,1.8,h+3,wall,roof)
        m.block(-6,4.5,4,12,2,.45,wood)
        for x in range(-6,7,2): m.rod((x,6.3,4.4),(x,6.3,6),.12,wood)
        m.rod((-6,6.3,6),(6,6.3,6),.12,wood)
        stairs(m,5,7,0,2.5,7)
    if culture not in ('arcane','eastern'):
        a,b=m.block(-2,-2,h+3,1.5,1.7,9,'#b3a793','brick')
        m.block(-2.2,-2.2,h+12,1.9,2.1,.5,'#e2d3b1')
    # Occupied details: lantern, signboard and clustered ceramic planters.
    pot(m,-6,6,flowers=True); pot(m,-7,3)
    m.rod((4,5,3.5),(4,6.5,3.5),.1,wood)
    m.block(3.6,6.1,2.4,.8,.8,1.1,'#f0c77c')
    if seed%2:
        m.block(-7,0,0,1.5,3,1.2,wood)
        for i in range(3): m.drum(-6.3,.5+i,.9,.35,.4,accent,n=6)
    return m.finish()


def house(culture,tier,seed): return residence(culture,tier,seed)


def tree(kind,colors,seed,scale=1):
    m=model(('tree',kind,seed)); r=m.rng
    base=colors[0]; m.shadow=(9*scale,4*scale)
    height=(19+seed%5)*scale
    if kind=='pine':
        m.rod((0,0,0),(.5,0,height+7),.55*scale,'#665346')
        # Individual whorls made of drooping boughs, not stacked triangles.
        for level in range(7):
            z=(5+level*3)*scale; reach=(7-level*.75)*scale
            for j in range(5):
                a=j*TAU/5+level*.9
                ex,ey=math.cos(a)*reach,math.sin(a)*reach
                m.rod((0,0,z+1),(ex,ey,z-.9),.12*scale,'#665346')
                m.foliage(ex*.65,ey*.65,z,reach*.46,reach*.38,1.9*scale,base,seed+level*9+j)
        m.foliage(0,0,26*scale,1.1*scale,1.1*scale,3.1*scale,base,seed)
    elif kind=='palm':
        for i in range(9): m.rod((i*i*.025,0,i*2),( (i+1)**2*.025,0,(i+1)*2),.55,'#9a7954')
        for j in range(9):
            a=j*TAU/9; ex,ey=math.cos(a)*9,math.sin(a)*9
            m.poly([(2,0,18),(2+ex*.6,ey*.6,20),(2+ex,ey,15),(2+ex*.4-ey*.14,ey*.4+ex*.14,18)],shade(base,.1 if j<4 else -.12))
    else:
        stems=3 if kind=='birch' else 1
        for stem in range(stems):
            sx=(stem-1)*1.2 if stems>1 else 0
            lean=r.uniform(-2.8,2.8)*scale
            bark='#d4d1b4' if kind=='birch' else '#78604b'
            m.rod((sx,0,0),(sx+lean,.4,height*.75),(.35 if stems>1 else .95)*scale,bark)
            for j in range(5):
                a=j*2.4+seed*.3+stem
                z=height*(.4+j*.105)
                spread=(3 if stems>1 else 6)*scale*(1-abs(j-2)*.13)
                ex,ey=sx+lean+math.cos(a)*spread,math.sin(a)*spread
                m.rod((sx+lean*.5,0,z-3*scale),(ex,ey,z+2*scale),(.16 if stems>1 else .35)*scale,bark)
                m.foliage(ex,ey,z+3*scale,(2.7 if stems>1 else 4.6)*scale,(2.1 if stems>1 else 3.7)*scale,(3.5 if stems>1 else 3)*scale,base,seed*41+stem*7+j)
                if kind=='oak':
                    for side in (-1,1):
                        m.foliage(ex*.72+side*2*scale,ey*.7,z+2*scale+side*.7,3.2*scale,2.6*scale,2.4*scale,shade(base,.04*side),seed+j*7+side)
                    m.rod((sx+lean*.4,0,z-3*scale),(ex*.6,ey*.6,z),.22*scale,shade(bark,.14))
            if kind=='birch':
                for j in range(6): m.rod((sx-.3,0,j*2.1+1),(sx+.3,0,j*2.1+1.2),.08,'#626559')
        if kind=='oak':
            for a in range(5): m.rod((0,0,.6),(math.cos(a*1.3)*2.8,math.sin(a*1.3)*2.8,.1),.3,'#78604b')
    return m.finish()


def oak(colors,seed): return tree('oak',colors,seed)
def birch(colors,seed): return tree('birch',colors,seed)
def pine(colors,seed): return tree('pine',colors,seed)
def palm(seed): return tree('palm',('#4f8f70',),seed)
def great_tree(seed): return tree('oak',('#6c926c',),seed,2.4)
def world_tree(scale): return tree('oak',('#4f948a',),9,3.2*min(1.7,max(1,float(scale))))


def spire(m,x,y,z,r,h,wall,roof):
    m.drum(x,y,z,r,h,wall,n=8,r2=r*.84)
    for zz in (z+2,z+h*.55,z+h-1): m.drum(x,y,zz,r*1.03,.5,'#bfb69d',n=8)
    m.drum(x,y,z+h,r*1.35,1,roof,n=8,r2=r*1.15)
    m.drum(x,y,z+h+1,r*1.15,r*3.6,roof,n=8,r2=.1)
    m.drum(x,y,z+h+1+r*3.6,.4,.9,'#edc57c',n=6)
    for a in (.4,1.3,2.1):
        xx,yy=x+math.cos(a)*r*.95,y+math.sin(a)*r*.95
        m.rod((xx,yy,z+h*.6),(xx,yy,z+h*.6+2),.18,'#f2ce89')


def mushroom(m,x,y,z,r,h,seed):
    m.drum(x,y,z,r*.3,h,'#d6c8a6',n=9,r2=r*.22)
    n=28; rings=[(r*.25,h+3),(r*.65,h+2.5),(r,h+.5),(r*.94,h)]
    previous=None
    for radius,zz in rings:
        points=[(x+math.cos(i*TAU/n)*radius,y+math.sin(i*TAU/n)*radius,z+zz) for i in range(n)]
        if previous is None: m.poly(points,'#bf6854')
        if previous:
            for i in range(n):
                f=m.poly([previous[i],previous[(i+1)%n],points[(i+1)%n],points[i]],shade('#b35a4d',.1*math.cos(i)))
                for j in range(3):
                    u=.13+j*.28
                    f.line([(u,.02),(u+.04,.45),(u-.015,.96)],shade(f.color,-.08),.045)
                if (i+seed)%3==0:
                    for u,v,rr in ((.3,.2,.13),(.6,.58,.08),(.15,.75,.06)):
                        f.marks.append(([(u+math.cos(j*TAU/7)*rr,v+math.sin(j*TAU/7)*rr) for j in range(7)],'#e3cf9f',0))
        previous=points
    m.poly(points,'#cbb69c')
    for i in range(56):
        a=i*TAU/56
        m.rod((x+math.cos(a)*r*.24,y+math.sin(a)*r*.24,z+h-.12),(x+math.cos(a)*r*.92,y+math.sin(a)*r*.92,z+h-.07),.035,'#9f8d70')


def fhouse(style,culture,tier,seed):
    m=model(('fantasy',style,culture,tier,seed)); wall,roof,accent,wood=CULTURES[culture]
    h=8+min(4,tier)*1.5; m.shadow=(12,6)
    if style=='mushroom':
        # Hollow stalk dwelling with an exterior spiral stair and two caps.
        mushroom(m,0,0,0,9,h,seed)
        mushroom(m,6,-3,0,4,h*.55,seed+1)
        m.block(-1,3,0,2,.5,3,'#695448')
        for i in range(11):
            a=i*.28; x,y=math.cos(a)*3.5,math.sin(a)*3.5
            m.block(x-.7,y-.5,i*.45,1.4,1,.45,'#b89f73')
        for x in (-2,2): m.block(x,2.3,h*.58,.8,.2,1.4,'#f0ca83')
        pot(m,-5,3,flowers=True)
    elif style in ('treehouse','crooked'):
        # Exposed roots carry a crooked, cantilevered timber room.
        for a in range(4): m.rod((0,0,5),(math.cos(a*1.7)*6,math.sin(a*1.7)*6,0),.7,wood)
        m.rod((0,0,0),(-2,0,15),1.3,wood)
        a,b=m.block(-5,-4,5,10,8,h*.65,wall); facade(m,a,2,True,True); facade(m,b,2,True)
        m.roof(-6,-4.5,5+h*.65,12,9,6,roof)
        m.block(-6,4,4.5,13,2,.6,wood)
        for i in range(8): m.rod((6,5-i*.55,i*.6),(8,5-i*.55,i*.6),.13,wood)
        for i in range(4): m.foliage(-5+i*3,-4,14+i%2*3,3,2.5,2.5,'#7b9658',seed+i)
        m.rod((-6,5,6),(-6,5,10),.13,wood)
        m.block(-6.5,5,8.2,1,.6,1.2,'#f4d084')
    elif style=='dwarf':
        # Mountain lodge cut into a crag, huge stone lintel and brass gate.
        m.foliage(0,0,4,10,7,7,'#898d82',seed)
        a,b=m.block(-5,3,0,10,3,7,'#b5b09a','stone')
        a.rect(.29,.3,.42,.7,'#3b4545'); a.rect(.34,.38,.32,.62,'#af8650')
        for u in (.39,.52,.65): a.line([(u,.4),(u,1)],'#514738',.2)
        m.block(-6,2,7,12,5,1.4,'#c6b88f')
        for x in (-6,5): m.block(x,3,0,1.2,3,8,'#827c6d','stone')
        stairs(m,-3,8,0,6,3)
        m.foliage(-3,-2,8,4,3,2,'#6f8561',seed)
    elif style=='crystal':
        # A hexagonal apothecary beneath a cluster of translucent crystal roofs.
        m.drum(0,0,0,6,h*.7,wall,n=6)
        for j in range(3):
            a=j*2.1; x,y=math.cos(a)*3,math.sin(a)*3
            crystal(m,x,y,h*.7,2.8,9+j*3,('#8fc7c8','#b1a4cb','#8fb7bd')[j])
        m.block(-3,4,0,6,3,3,wood)
        for x in (-3,3):m.rod((x,6,0),(x,6,6),.16,wood)
        m.roof(-4,3,6,8,5,2,roof)
        pot(m,-6,2,flowers=True)
    elif style=='dome':
        # Desert alchemist: squat octagonal hall under a ribbed onion cupola.
        m.drum(0,0,0,6,h,wall,n=8)
        m.drum(0,0,h,7,2,roof,n=12,r2=6)
        m.drum(0,0,h+2,6,4,roof,n=12,r2=3)
        m.drum(0,0,h+6,3,4,roof,n=12,r2=.15)
        a,b=m.block(-2,5,0,4,3,5,wall); facade(m,a,1,door=True)
        m.roof(-2,5,5,4,3,2,roof,'hip')
        m.rod((0,0,h+10),(0,0,h+13),.12,'#d7ae56')
        for x in (-6,6): pot(m,x,2,flowers=True)
    else:
        # Wizard/crystal/turret homes: uneven stone shaft, hovering crystal cage.
        spire(m,-1,0,0,4,h+6,wall,roof)
        a,b=m.block(1,0,0,6,6,5,wall,'stone'); facade(m,a,2,door=True)
        m.roof(1,0,5,6,6,3,roof)
        m.drum(-1,0,h*.6,5,.6,wood,n=8)
        for j in range(6):
            a=j*TAU/6
            m.rod((-1+math.cos(a)*4.8,math.sin(a)*4.8,h*.6),(-1+math.cos(a)*4.8,math.sin(a)*4.8,h*.6+1.8),.12,accent)
        if style=='crystal':
            for x,y in ((-5,3),(5,-4),(-3,-5)): crystal(m,x,y,0,1.3,7,accent)
    if style=='crooked':
        for face in m.faces:
            face.points=[(x+max(0,z-4)*.19,y,z) for x,y,z in face.points]
    return m.finish()


def crystal(m,x,y,z,r,h,color):
    m.drum(x,y,z,r,h*.7,color,n=5,r2=r*.8)
    m.drum(x,y,z+h*.7,r*.8,h*.3,shade(color,.2),n=5,r2=0)


def civic(kind,culture='alpine',level=2,seed=0):
    m=model(('civic',kind,culture,level,seed)); wall,roof,accent,wood=CULTURES[culture]
    m.shadow=(24,11); h=11+min(5,level)*1.8
    if kind in ('keep','citadel','gate','palace'):
        # A nested keep with courtyard, unequal towers and a bridge-like gate.
        a,b=m.block(-10,-8,0,16,12,h,wall,'stone'); facade(m,a,4,True,True); facade(m,b,3)
        m.roof(-10,-8,h,16,12,7,roof)
        spire(m,-10,-5,0,3.5,h+7,wall,roof)
        spire(m,8,-3,0,3,h+3,wall,roof)
        m.rod((-10,-5,h+21.5),(-10,-5,h+25.5),.1,wood)
        m.rod((8,-3,h+15.7),(8,-3,h+19.7),.1,wood)
        a,b=m.block(-7,4,0,15,4,5,wall,'stone')
        a.rect(.39,.24,.22,.76,'#344441')
        for x in range(-7,9,3): m.block(x,7,5,1.6,1,1.4,wall)
        stairs(m,-2,11,0,4,4)
        m.block(-1,-4,h+3,3,3,5,wall,'stone')
        m.roof(-1,-4,h+8,3,3,3,roof)
        if kind=='palace':
            for x in (-5,0,5): spire(m,x,-9,h*.3,1.4,h*.7,'#e7d9ba',roof)
        if kind=='gate':
            m.block(-12,6,0,4,4,h*.7,wall,'stone'); m.block(8,6,0,4,4,h*.7,wall,'stone')
            m.block(-12,6,h*.7,24,4,3,wall,'stone'); m.roof(-12,6,h*.7+3,24,4,4,roof)
    elif kind=='temple':
        # Forest sanctuary with a clerestory and a separate bell tower.
        a,b=m.block(-10,-5,0,18,10,9,'#d8ceb1','stone'); facade(m,a,5); facade(m,b,2,door=True)
        m.roof(-10,-5,9,18,10,6,roof)
        a,b=m.block(-8,-2,13,13,4,4,wall); facade(m,a,5)
        m.roof(-8,-2,17,13,4,3,roof)
        spire(m,9,-3,0,3,20,wall,roof)
        for x in range(-9,9,4): m.block(x,5,0,1,2,7,'#b2ac94')
        stairs(m,7,7,0,4,4)
    elif kind=='tavern':
        a,b=m.block(-8,-5,0,16,10,10,wall); facade(m,a,4,True,True); facade(m,b,2,True)
        m.roof(-8,-5,10,16,10,6,roof)
        a,b=m.block(-10,3,0,6,5,5,wall); facade(m,a,1)
        m.roof(-10,3,5,6,5,3,roof)
        for y in (7,10):
            m.block(1,y,1.3,6,1.3,.3,wood)
            for x in (1,6): m.rod((x,y,0),(x,y,1.5),.16,wood)
        m.rod((-8,5,6),(-8,9,6),.13,wood)
        f,_=m.block(-8.7,8,3.6,1.4,.4,2,wood); f.rect(.2,.2,.6,.4,'#e7c367')
        for x in (-4,7): pot(m,x,6,flowers=True)
    elif kind=='windmill':
        m.drum(0,0,0,5,18,wall,n=8,r2=3)
        m.drum(0,0,18,5,8,roof,n=8,r2=.1)
        m.rod((0,0,22.3),(1.5,3.1,22.3),.3,wood)
        m.drum(0,0,10,6,.6,wood,n=10)
        for j in range(10):
            a=j*TAU/10; m.rod((math.cos(a)*5.8,math.sin(a)*5.8,10),(math.cos(a)*5.8,math.sin(a)*5.8,12),.12,wood)
        a,b=m.block(3,0,0,5,6,4,wall); facade(m,a,1,door=True)
        m.roof(3,0,4,5,6,3,roof)
    elif kind=='forge':
        a,b=m.block(-6,-5,0,10,8,6,'#8e8b7b','stone'); facade(m,b,2)
        a.rect(.1,.22,.8,.78,'#302f2b')
        m.roof(-6,-5,6,10,8,4,roof)
        m.block(-5,-4,7,3,3,13,'#a18f78','brick')
        m.block(-5.5,-4.5,20,4,4,.7,'#d0b68c')
        m.block(-3,2,1,3,2,1.7,'#d1793d'); m.block(-2.6,2.2,2.7,2.2,1.4,.3,'#f1bb57')
        m.block(5,3,0,2,2,1.8,wood); m.block(4.5,2.7,1.8,3,2.6,.7,'#465455')
        m.rod((7,-3,0),(7,-3,7),.2,wood); m.rod((3,-3,7),(7,-3,7),.2,wood)
    elif kind in ('arena','theatre'):
        for j in range(15):
            a=math.pi*.15+j*math.pi*1.7/14
            x,y=math.cos(a)*15,math.sin(a)*12
            m.block(x-1.6,y-1.5,0,3.2,3,4+j%3,'#b4aa90','stone')
            m.block(x-1.7,y-1.7,4+j%3,3.4,3.4,.5,wood)
        m.block(-7,-6,0,14,9,1.3,wood)
        for x in (-7,7): m.rod((x,-5,0),(x,-5,12),.3,wood)
        m.roof(-8,-7,11,16,5,4,roof)
        for x in (-6,6): m.block(x,-4,1.3,1.2,.5,8,'#af514b')
    elif kind in ('spires','elf_tower','tree'):
        for x,y,r,tall in ((-5,-3,2.5,26),(5,-2,2,21),(0,3,3,31)):
            spire(m,x,y,3,r,tall,'#d4d4b8','#54867b')
            for j in range(3):
                a=j*2.2
                m.rod((x,y,9),(x+math.cos(a)*6,y+math.sin(a)*6,0),.8,'#7c6b4c')
        m.block(-7,-3,14,14,3,.6,'#a7b18d')
        for x in (-8,8): m.foliage(x,-4,18,4,3,3,'#769c69',seed+int(x))
    else:
        # Crystal observatory with buttresses and a levitating central prism.
        m.drum(0,0,0,9,7,wall,n=8)
        for j in range(5):
            a=j*TAU/5; x,y=math.cos(a)*9,math.sin(a)*9
            spire(m,x,y,0,1.6,12,wall,roof)
        crystal(m,0,0,12,4,17,'#8dd7d6')
        m.drum(0,0,9,5,.5,'#d6b673',n=12)
    if kind in ('keep','citadel','gate','palace','spires','tree'):
        m.scale(.85+min(5,max(0,level))*.18)
    return m.finish()


def keep(culture,level,seed): return civic('keep',culture,level,seed)
def seatx(style,culture,level,seed): return civic(style,culture,level,seed)
def temple(culture,seed): return civic('temple',culture,2,seed)
def tavern(culture,seed): return civic('tavern',culture,2,seed)
def windmill(culture,seed): return civic('windmill',culture,2,seed)
def forge(seed): return civic('forge',seed=seed)
def round_hall(kind,seed=0): return civic(kind,seed=seed)
def elf_tower(seed): return civic('elf_tower','arcane',seed=seed)


def stall_model(m,x=0,y=0,seed=0):
    wood='#79583f'; cloth=('#b85145','#467e85','#bea04d')[seed%3]
    m.block(x-3,y-2,0,6,4,2,wood)
    for xx in (-3,3):
        for yy in (-2,2): m.rod((x+xx,y+yy,0),(x+xx,y+yy,6),.16,wood)
    # Bowed canvas, with a scalloped apron and baskets of produce.
    for i in range(6):
        tone=cloth if i%2 else '#e8d6b1'
        m.poly([(x-3+i,y-2,6.6),(x-2+i,y-2,6.6),(x-2+i,y+3,5.5),(x-3+i,y+3,5.5)],tone)
        m.poly([(x-3+i,y+3,5.5),(x-2+i,y+3,5.5),(x-1.9+i,y+3,4.7),(x-2.5+i,y+3,4.5),(x-3+i,y+3,4.7)],tone)
    for i in range(3):
        m.block(x-2.6+i*1.8,y+.2,2,1.5,1.4,.4,'#ae865a')
        for j in range(3): m.drum(x-2.2+i*1.8+(j%2)*.5,y+.5+(j//2)*.4,2.4,.3,.35,('#cf8050','#9fba65','#d6b856')[i],n=6)


def prop(kind,seed=0,amount=1):
    m=model(('prop',kind,seed)); wood='#826044'; stone='#b6b09a'; m.shadow=(9,4)
    if kind in ('stall','market','tourney'):
        if kind=='stall': stall_model(m,seed=seed)
        elif kind=='market':
            stall_model(m,-5,-2,seed); stall_model(m,5,2,seed+1)
            m.block(-1,5,0,3,2,1.5,wood); pot(m,0,6,1.5,flowers=True)
        else:
            for x in (-8,8):
                m.drum(x,0,0,4,5,'#e5d3af',n=8)
                m.drum(x,0,5,4.8,6,'#9e5360' if x<0 else '#547e88',n=8,r2=.1)
                m.rod((x,0,10),(x,0,14),.1,wood)
                m.poly([(x,0,14),(x+3,0,13),(x,0,12)],'#d9ad5c')
            m.rod((-8,5,2),(8,5,2),.18,wood)
    elif kind in ('fountain','well','spring_head'):
        m.drum(0,0,0,5.5,.8,stone,n=10)
        m.drum(0,0,.8,4.6,.2,'#538e91',n=10)
        if kind=='fountain':
            m.drum(0,0,1,1,4,stone,n=8)
            m.drum(0,0,5,3,.7,stone,n=8,r2=3.4)
            m.drum(0,0,5.7,2.8,.1,'#80bec0',n=8)
            crystal(m,0,0,6,.8,3,'#c6d6c2')
            for a in range(5):
                x,y=math.cos(a*TAU/5),math.sin(a*TAU/5)
                m.rod((x*2.5,y*2.5,5.7),(x*3.8,y*3.8,1),.08,'#b4d9cb')
        elif kind=='well':
            m.drum(0,0,.8,3.2,2,stone,n=10)
            m.drum(0,0,2.8,2.7,.1,'#33494d',n=10)
            for x in (-4,4): m.rod((x,0,0),(x,0,8),.22,wood)
            m.roof(-5,-3,8,10,6,3,'#677f6d')
            m.rod((-4,0,5),(4,0,5),.22,wood)
            m.rod((0,0,5),(0,0,2),.05,'#c6ae7c')
        else:
            m.foliage(-2,-2,3,4,3,4,'#868c7d',seed)
            m.poly([(-2,0,4),(0,0,4),(1,2,1),(-1,2,1)],'#9acbc1')
            for x in (-4,4): m.foliage(x,0,1,2,1.5,1.5,'#688b61',seed+int(x))
    elif kind in ('flowers','field','hedge'):
        if kind=='field':
            m.block(-8,-5,0,16,10,.3,'#82694e')
            for x in range(-7,8,2):
                for y in range(-4,5,2):
                    m.rod((x,y,0),(x+.25,y,1.7),.07,'#b1a565')
                    m.drum(x+.25,y,1.7,.25,.7,'#d9be73',n=5,r2=.05)
            for x in (-9,9):
                m.rod((x,-5,0),(x,-5,2),.15,wood); m.rod((x,5,0),(x,5,2),.15,wood)
                m.rod((x,-5,1.5),(x,5,1.5),.1,wood)
        elif kind=='hedge':
            for x in range(-6,7,3): m.foliage(x,0,1.6,2.4,1.5,2,'#567756',seed+x)
        else:
            for i in range(24):
                x,y=m.rng.uniform(-8,8),m.rng.uniform(-4,4); h=m.rng.uniform(.7,2)
                m.rod((x,y,0),(x+.2,y,h),.045,'#6e8c5a')
                m.drum(x+.2,y,h,.27,.12,('#d9b16a','#bd7183','#e6d9ac','#7e91c2')[i%4],n=5)
                m.poly([(x,y,.6),(x+.7,y+.2,1),(x+.1,y,.9)],'#789c62')
    elif kind in ('rock','mountain','ruin'):
        big=4 if kind=='mountain' else 1
        for x,y,r,h in ((-3,0,3,4),(2,-2,4,6),(3,2,2,3)):
            m.foliage(x*big,y*big,h*.4*big,r*big,r*.8*big,h*.7*big,'#8d9387',seed+int(x))
        if kind=='mountain':
            m.foliage(2*big,-2*big,6.5*big,2.2*big,1.8*big,2*big,'#dddcc6',seed)
            m.shadow=(30,14)
        if kind=='ruin':
            for x,h in ((-5,8),(4,5)): m.block(x,-2,0,2,3,h,stone,'stone')
            m.block(-5,-2,8,5,3,1,stone,'stone')
            m.foliage(-4,0,1,3,2,1.5,'#68865a',seed)
    elif kind in ('crates','cart'):
        for x,y,z in ((-2,0,0),(1,0,0),(-1,-2,0),(-1,-1,2)):
            a,b=m.block(x,y,z,2.4,2.2,2,'#a78458')
            for f in (a,b):
                for u in (.2,.4,.6,.8): f.line([(u,0),(u,1)],wood,.09)
                f.line([(0,0),(1,1)],'#cfaf7c',.2)
                f.line([(1,0),(0,1)],'#cfaf7c',.2)
        if kind=='cart':
            m.block(-4,-3,0,8,5,.6,wood)
            for x in (-3,3):
                m.rod((x,0,0),(x,0,2),.9,'#544b3d')
                m.rod((x,-1,1),(x,-7,1.5),.15,wood)
            for y in (-3,2): m.block(-4,y,1,8,.3,1.8,wood)
    elif kind=='sheep':
        for x in (-1.5,1.5):
            for y in (-.8,.8): m.rod((x,y,0),(x,y,1.5),.15,'#504b42')
        m.foliage(0,0,2,2.3,1.4,1.5,'#e0d7ba',seed)
        m.foliage(2,0,2.1,.7,.65,.85,'#61594e',seed)
        m.rod((2,-.7,2.4),(2,.7,2.4),.13,'#c4b898')
    elif kind in ('statue','milestone','gold_pile','fire'):
        if kind=='gold_pile':
            for i in range(min(45,8+int(amount)*3)):
                x,y=m.rng.uniform(-4,4),m.rng.uniform(-2,2)
                m.drum(x,y,m.rng.uniform(0,1),.4,.18,'#d6ae58',n=8)
            m.block(-3,-2,0,3,2,2,wood); m.block(-3,-2,2,3,.3,2,wood)
        elif kind=='fire':
            for i in range(7):
                a=i*TAU/7; m.foliage(math.cos(a)*2.3,math.sin(a)*2.3,.3,.7,.6,.5,stone,i)
            for a in range(3): m.rod((-1.4,a*.5,.4),(1.4,-a*.5,.4),.25,wood)
            for x,y,h in ((-.4,0,3),(.5,.2,2),(0,-.2,4)):
                crystal(m,x,y,.5,.5,h,'#eda758')
        elif kind=='milestone':
            m.rod((0,0,0),(0,0,6),.25,wood)
            m.block(-2,-.2,4,4,.4,1,'#b79c6f'); m.block(-1,-.2,2.6,3,.4,1,'#b79c6f')
        else:
            m.block(-3,-3,0,6,6,1.4,stone,'stone')
            m.drum(0,0,1.4,1.7,5,'#8d9a8c',n=6,r2=1)
            m.foliage(0,0,7,1,1,1.4,'#a5b09b',seed)
            # Winged guardian, not a generic plinth.
            for sign in (-1,1):
                m.poly([(sign*.5,0,5),(sign*6,-1,10),(sign*4,-1,5),(sign*2,0,3)],'#839b8e')
    elif kind=='lighthouse':
        m.drum(0,0,0,4,22,stone,n=8,r2=2.5)
        for z in (6,12,18): m.drum(0,0,z,4-z*.065,.65,'#8a6a58',n=8)
        m.drum(0,0,22,4,1,'#785b43',n=8)
        m.drum(0,0,23,2.7,4,'#edcf86',n=8)
        for i in range(6):
            a=i*TAU/6; m.rod((math.cos(a)*2.8,math.sin(a)*2.8,23),(math.cos(a)*2.8,math.sin(a)*2.8,27),.12,'#4c615c')
        m.drum(0,0,27,4,6,'#52796d',n=8,r2=.1)
    else: raise ValueError(f'Unknown prop: {kind}')
    return m.finish()


def ship(seed,large=False):
    m=model(('ship',seed,large)); m.shadow=(0,0)
    length=13 if large else 7; beam=3.2 if large else 2.1
    keel=[(-length,0,0),(-length*.7,beam,1),(length*.65,beam,1),(length+2,0,3),(length*.65,-beam,1),(-length*.7,-beam,1)]
    deck=[(x,y,z+3) for x,y,z in keel]
    for i in range(6):
        f=m.poly([keel[i],keel[(i+1)%6],deck[(i+1)%6],deck[i]],'#8b6243')
        for v in (.25,.5,.75): f.line([(0,v),(1,v)],'#4f4838',.12)
    m.poly(deck,'#c3a371')
    for y in (-beam,beam): m.rod((-length*.7,y,4),(length*.65,y,4),.15,'#5d4c3a')
    # Tall swept prow and a lantern hung beneath the stern cabin.
    m.rod((length,0,4),(length+3,0,8),.25,'#6a4d39')
    if large:
        a,b=m.block(-length*.8,-2,4,5,4,4,'#b89868'); facade(m,a,2)
        m.roof(-length*.8,-2,8,5,4,2,'#607e71')
    for x,h in ((0,20 if large else 13),)+(((7,16),) if large else ()):
        m.rod((x,0,3),(x,0,h),.18,'#66513c')
        m.rod((x,0,h),(length,0,5),.035,'#c3af84')
        m.rod((x,0,h),(-length,0,4),.035,'#c3af84')
        for side in (-1,1):
            width=(6 if large else 4)*side
            points=[(x,0,h-1),(x+width,0,h-4),(x+width*.75,1,h-10),(x,1,h-9)]
            f=m.poly(points,'#decda7' if side<0 else '#a6524c')
            for u in (.2,.4,.6,.8): f.line([(u,0),(u,1)],'#b69e74',.09)
        m.poly([(x,0,h),(x+3,0,h-.6),(x,0,h-1.5)],'#d5b368')
    return m.finish()


def boat(seed): return ship(seed)
def galleon(seed): return ship(seed,True)


def bridge_art(seed):
    m=model(seed); wood='#846a4c'; m.shadow=(0,0)
    # A bowed timber bridge with stone abutments and lantern posts.
    for x in (-10,8): m.block(x,-3,-1,3,6,3,'#a9a58e','stone')
    for i in range(17):
        x=-10+i*1.25; z=1.5+2.3*math.sin((i+.5)/17*math.pi)
        m.block(x,-3,z,1.1,6,.4,shade(wood,.1*(i%3)))
        if i%4==0:
            for y in (-3,3): m.rod((x,y,z),(x,y,z+2.4),.14,wood)
    for y in (-3,3):
        for i in range(8):
            a,b=i/8,(i+1)/8
            m.rod((-10+20*a,y,4+2.3*math.sin(a*math.pi)),(-10+20*b,y,4+2.3*math.sin(b*math.pi)),.13,wood)
    for x,y in ((-9,3),(9,-3)):
        m.rod((x,y,1),(x,y,7),.18,wood); m.block(x-.4,y-.4,5.5,.8,.8,1.2,'#edc780')
    return m.finish()


def landmark(kind,seed):
    if kind=='tree': return great_tree(seed)
    m=model((kind,seed)); m.shadow=(13,6)
    if kind=='portal':
        for j in range(12):
            a=j*TAU/12; b=(j+1)*TAU/12
            outer=lambda t:(math.cos(t)*7,0,10+math.sin(t)*9)
            inner=lambda t:(math.cos(t)*5.2,0,10+math.sin(t)*7)
            m.poly([outer(a),outer(b),inner(b),inner(a)],shade('#a69db2',.12*math.sin(a)))
        m.poly([(-4.5,0,6),(0,0,3),(4.5,0,6),(4.5,0,14),(0,0,17),(-4.5,0,14)],'#628f9f')
        crystal(m,0,0,7,1.6,6,'#b7dfcb')
        m.block(-8,-2,0,16,4,1,'#969b8b','stone')
    elif kind=='stones':
        for j in range(7):
            a=j*TAU/7; x,y=math.cos(a)*9,math.sin(a)*9
            m.drum(x,y,0,1.6,5+j%3,'#989e8d',n=5,r2=1.1)
            m.rod((x+1,y,2),(x+1,y,4),.08,'#a3dbc4')
        m.drum(0,0,0,3,.3,'#9ac5b5',n=10)
    elif kind=='crystal':
        for x,y,r,h in ((0,0,3,22),(-5,2,1.5,11),(5,1,2,15)):
            crystal(m,x,y,1,r,h,'#8fc6cb')
        m.drum(0,0,0,8,1,'#8a8d88',n=8)
    else:
        # Winged dragon monument with curled neck and a jagged tail.
        m.block(-5,-4,0,10,8,2,'#989f8e','stone')
        m.foliage(0,0,5,4,2,3,'#7b9d8f',seed)
        m.rod((2,0,6),(3,0,11),.7,'#7b9d8f')
        m.foliage(4,0,11,1.7,1,1.2,'#88ab99',seed)
        for sign in (-1,1):
            m.poly([(0,sign,6),(-3,sign*8,13),(1,sign*6,8),(3,sign*3,5)],'#8baa98')
        m.rod((-3,0,4),(-7,2,3),.5,'#7b9d8f'); m.rod((-7,2,3),(-8,4,6),.3,'#7b9d8f')
    return m.finish()


class Wide(Sheet):
    k=sp.FINAL


def terrace(rx,ry,height,seed,marks,kind='stone'):
    """Polygonal retaining terraces with buttresses and engraved ring paths."""
    rx,ry,height=float(rx),float(ry),float(height)
    s=Wide(math.ceil(rx*2+32),math.ceil(ry+height+14),math.ceil(ry+16))
    rnd=random.Random(asset_seed('terrace',seed))
    stone={'sand':'#bfa582','dark':'#707c7c','moss':'#8a967c'}.get(kind,'#a5aa95')
    grass={'sand':'#c0b286','dark':'#838d80','water':'#849c7e'}.get(kind,'#8b9c76')
    n=32
    rim=[(math.cos(i*TAU/n)*rx,math.sin(i*TAU/n)*ry) for i in range(n)]
    if kind=='water':
        s.oval(0,0,rx+9,ry+5,'#6d8f8b'); s.oval(0,0,rx+7,ry+4,'#426d79')
    s.shadow(2,3,rx+2,ry+2,75)
    for i in range(n):
        a,b=rim[i],rim[(i+1)%n]
        s.poly([a,b,(b[0],b[1]-height),(a[0],a[1]-height)],shade(stone,-.12+.1*math.cos(i*TAU/n)))
        if a[1]>=0:
            for row in range(max(1,int(height/2))):
                yy=(row+1)*height/max(1,int(height/2))
                s.line([(a[0],a[1]-yy),(b[0],b[1]-yy)],shade(stone,-.2),.16)
            s.line([(a[0],a[1]),(a[0],a[1]-height)],shade(stone,-.22),.22)
    s.poly([(x,y-height) for x,y in rim],grass)
    for _ in range(int(rx*ry/18)):
        a=rnd.random()*TAU; r=math.sqrt(rnd.random())*.96
        x,y=math.cos(a)*rx*r,math.sin(a)*ry*r-height
        s.line([(x,y),(x+.5,y-.2)],shade(grass,rnd.uniform(-.14,.17)),.25)
    for band in marks or ():
        points=[(math.cos(i*TAU/160)*rx*band,math.sin(i*TAU/160)*ry*band-height) for i in range(161)]
        s.line(points,'#b7b295',5)
        s.line(points,'#c4bea3',3.5)
        for i in range(0,160,2):
            x,y=points[i]; s.line([(x-.6,y-.4),(x+.6,y+.4)],'#9c9e85',.13)
    for i,(x,y) in enumerate(rim):
        s.line([(x,y-height),(rim[(i+1)%n][0],rim[(i+1)%n][1]-height)],shade(stone,.22),.8)
        if y>0 and height>2 and i%2==0:
            s.poly([(x-1.1,y),(x+1.1,y),(x+.7,y-height),(x-.7,y-height)],shade(stone,.12))
            for j in range(4):
                yy=y-height+j*.9
                s.poly([(x,yy),(x+1.1,yy+.4),(x+.3,yy+1.3),(x-.7,yy+.6)],'#638364')
    return s.finish()


def ground_square(half,seed):
    s=Wide(math.ceil(half*4+12),math.ceil(half+8),math.ceil(half+8)); rnd=random.Random(seed)
    s.poly([(0,-half),(half*2,0),(0,half),(-half*2,0)],'#8c9a77')
    for axis in (-1,1):
        for t in range(-int(half),int(half)+1,24):
            s.line([(t-half,axis*(t+half)*.5),(t+half,axis*(t-half)*.5)],'#c0b89d',4)
    for _ in range(int(half*2)):
        x,y=rnd.uniform(-half,half),rnd.uniform(-half,half)
        s.line([(x-y,(x+y)*.5),(x-y+.5,(x+y)*.5-.3)],'#a5b087',.4)
    return s.finish()


def plaza(radius):
    m=model(('plaza',radius)); m.shadow=(0,0)
    m.drum(0,0,0,radius*.72,.35,'#b6b49a',n=12)
    for ring in range(1,max(2,int(radius/2))):
        r=ring*1.3
        for i in range(16):
            a,b=i*TAU/16,(i+1)*TAU/16
            m.poly([(math.cos(a)*r,math.sin(a)*r,.4),(math.cos(b)*r,math.sin(b)*r,.4),(math.cos(b)*(r-.2),math.sin(b)*(r-.2),.4),(math.cos(a)*(r-.2),math.sin(a)*(r-.2),.4)],'#89988d')
    # Compass rose inlaid in the paving.
    for i in range(8):
        a=i*TAU/8
        m.poly([(0,0,.5),(math.cos(a)*radius*.5,math.sin(a)*radius*.5,.5),(math.cos(a+.4)*2,math.sin(a+.4)*2,.5)],'#718d87' if i%2 else '#e3d4aa')
    return m.finish()


def wall(dx,dy):
    s=Sheet(math.ceil(abs(dx)*2+14),math.ceil(abs(dy)+18),math.ceil(abs(dy)+7))
    length=max(1,math.hypot(dx,dy)); n=max(2,round(length/2))
    s.poly([(0,0),(dx,dy),(dx,dy-8),(0,-8)],'#8d998b')
    for row in range(4):
        for i in range(n):
            t=(i+.5*(row%2))/n; t2=min(1,t+.93/n)
            if t>=1:continue
            s.poly([(dx*t,dy*t-row*2),(dx*t2,dy*t2-row*2),(dx*t2,dy*t2-row*2-1.8),(dx*t,dy*t-row*2-1.8)],shade('#b0b29b',-.06*(i%3)))
    s.line([(0,-8),(dx,dy-8)],'#dfd3b3',.8)
    for i in range(max(2,int(length/6))+1):
        t=i/max(2,int(length/6)); x,y=dx*t,dy*t
        s.poly([(x-1,y),(x+1,y),(x+.7,y-10),(x-.7,y-10)],'#c0bda1')
        s.poly([(x-1.4,y-10),(x+1.4,y-10),(x,y-12)],'#536f69')
    return s.finish()


def wall_tower(culture):
    m=model('watchtower'); wall,roof,_,_=CULTURES[culture]
    spire(m,0,0,0,3.8,13,wall,roof)
    m.drum(0,0,9,5,.8,'#9eaa90',n=8)
    return m.finish()


def gatehouse(culture):
    m=model('gate'); wall,roof,accent,wood=CULTURES[culture]; m.shadow=(17,6)
    for x,y in ((-6,6),(6,-6)): spire(m,x,y,0,3.2,16,wall,roof)
    m.rod((-6,6,11),(6,-6,11),1.4,wall)
    for i in range(7):
        x=-3+i
        m.rod((x,-x,7),(x,-x,11),.1,wood)
    for x,y in ((-4,6),(6,-4)):
        m.poly([(x,y,10),(x+1.3,y,10),(x+1.3,y,5),(x+.65,y,4.3),(x,y,5)],accent)
    return m.finish()


def steps(dx,dy,width):
    s=Sheet(math.ceil(abs(dx)*2+width*2+14),math.ceil(abs(dy)+10),math.ceil(abs(dy)+10))
    length=max(1,math.hypot(dx,dy)); nx,ny=-dy/length,dx/length*.52
    def edge(t,sign):return dx*t+nx*width*.5*sign,dy*t+ny*width*.5*sign
    n=max(3,int(length/1.4))
    for i in range(n):
        a,b=i/n,(i+1)/n
        s.poly([edge(a,-1),edge(a,1),edge(b,1),edge(b,-1)],'#c5bda0' if i%2 else '#9b9f8b')
    for sign in (-1,1):
        a,b=edge(0,sign),edge(1,sign)
        s.line([(a[0],a[1]-2),(b[0],b[1]-2)],'#7f694c',.35)
        for t in (0,.5,1):
            x,y=edge(t,sign);s.line([(x,y),(x,y-3)],'#7f694c',.4)
    return s.finish()


def floating_isle(rx,seed):
    s=Wide(math.ceil(rx*2+12),math.ceil(rx*.55+8),math.ceil(rx*1.1+10)); rnd=random.Random(seed)
    rim=[(math.cos(i*TAU/18)*rx,math.sin(i*TAU/18)*rx*.5) for i in range(18)]
    for i,a in enumerate(rim):
        b=rim[(i+1)%len(rim)]
        s.poly([a,b,(rnd.uniform(-rx*.3,rx*.3),rx*rnd.uniform(.55,.9))],shade('#8b8c80',rnd.uniform(-.24,.12)))
        if a[1]>0:
            for j in range(5):
                t=(j+.5)/5;xx=a[0]+(b[0]-a[0])*t;yy=a[1]+(b[1]-a[1])*t
                depth=rnd.uniform(rx*.12,rx*.35)
                s.line([(xx,yy),(xx*.8,yy+depth*.5),(xx*.65,yy+depth)],'#626e64',.22)
                s.line([(xx+.25,yy),(xx*.8+.25,yy+depth*.5)],'#aaa990',.16)
                if j%2==0:
                    for k in range(6):
                        vx=xx+math.sin(k)*.8;vy=yy+k*.7
                        s.poly([(vx,vy),(vx+1,vy+.3),(vx+.4,vy+1.1),(vx-.5,vy+.5)],'#687d53')
    s.poly(rim,'#82916e')
    for i in range(int(rx*5)):
        angle=rnd.random()*TAU;radius=math.sqrt(rnd.random())*rx*.95
        x,y=math.cos(angle)*radius,math.sin(angle)*radius*.5
        s.line([(x,y),(x-.3,y-.55),(x+.2,y-.2)],rnd.choice(('#9aa67d','#6b7d5b','#a6aa84')),.18)
    for i in range(5):
        x=(i-2)*rx*.3
        s.line([(x,rx*.35),(x+2,rx*.65),(x-1,rx*.8)],'#6e765e',.5)
    s.line([(rx*.3,rx*.35),(rx*.32,rx*.75)],'#a6d7c8',1.4)
    return s.finish()


def isle_shadow(rx):
    s=Wide(math.ceil(rx*2+16),math.ceil(rx*.5+8),math.ceil(rx*.5+8));s.shadow(0,0,rx,rx*.5,55);return s.finish()


def rope(dx,dy):
    s=Wide(math.ceil(abs(dx)*2+12),math.ceil(abs(dy)+10),math.ceil(abs(dy)+14))
    pts=[(dx*i/24,dy*i/24+math.sin(i/24*math.pi)*5) for i in range(25)]
    for off in (-1.5,1.5):s.line([(x,y+off) for x,y in pts],'#9d8259',.3)
    for i in range(0,25,2):
        x,y=pts[i];s.line([(x,y-1.5),(x,y+1.5)],'#c3a77b',.45)
    return s.finish()


def mist(seed):
    s=Sheet(48,12,10)
    for i in range(9):
        pts=[(-19+j*2,math.sin(j*.45+i)*1.5+i*.6-4) for j in range(20)]
        s.line(pts,(203,222,208,30),1.2)
    return s.finish()


def person(seed,frame=0):
    # Fixed 36x48 frame contract for the live QML walkers.
    s=Sheet(6,7,1);r=random.Random(seed);stride=.5 if frame else -.5
    cloak=r.choice(('#517a72','#8a5263','#b77d45','#667393','#64825d'))
    s.shadow(.4,.2,1.5,.5,65)
    for x,step in ((-.5,stride),(.5,-stride)):
        s.line([(x,-1.8),(x+step*.5,0)],'#514938',.55)
    s.poly([(-.9,-4.5),(.8,-4.5),(1.3,-.8),(0,-1.1),(-1.4,-.7)],cloak)
    s.poly([(-.9,-4.5),(0,-4.2),(-.3,-1),(-1.4,-.7)],shade(cloak,.2))
    s.oval(.1,-4.8,.62,.7,r.choice(('#d8b08b','#a97e59','#ebc69b')))
    # Pointed hood, satchel, and traveller's staff.
    s.poly([(-.8,-4.9),(-.55,-5.9),(.15,-6.7),(.9,-4.9)],shade(cloak,-.08))
    s.line([(-.7,-4),(.8,-2.2)],'#dac599',.15)
    s.rect(.6,-2.5,.7,.9,'#9d7950')
    s.line([(-.8,-3.1),(.7,-3)],'#554b3c',.18)
    s.rect(-.1,-3.25,.27,.3,'#d8b870')
    for xx in (-.7,.25,.7):s.line([(xx,-3.6),(xx-.2,-1.2)],shade(cloak,-.22),.09)
    s.line([(-.55,-5.3),(-.25,-5.6),(.25,-5.55)],shade(cloak,.3),.09)
    s.line([(.65,-2.15),(1.15,-2.15)],'#d4b783',.1)
    if seed%2: s.line([(1.8,-4.7),(1.5,.1)],'#91764f',.16)
    return s.finish()


def golem(frame):
    s=Sheet(12,15,1);step=.7 if frame else -.7
    s.shadow(.5,.1,3.4,1.2,75)
    for x,y in ((-1.8,step),(1.8,-step)):
        s.poly([(x-1,-4),(x+1,-4),(x+.7,y),(x-1.2,y)],'#646e65')
    s.poly([(-3,-4),(-3.5,-9),(0,-11),(3.5,-9),(3,-4),(0,-3)],'#94a18c')
    s.poly([(0,-11),(3.5,-9),(3,-4),(0,-3)],'#6a8178')
    s.poly([(-2,-10),(-1.6,-13),(0,-14.5),(1.8,-13),(2,-10)],'#b1b79a')
    for sign in (-1,1):
        s.line([(sign*3,-8),(sign*4.5,-5+step*sign)],'#7e8b73',1.7)
        s.oval(sign*.65,-11.6,.3,.2,'#eacf8a')
    s.poly([(0,-8.8),(1,-7),(0,-5.8),(-1,-7)],'#eed394')
    for x,y in ((-2,-10),(2,-9),(-3,-5)):s.poly([(x,y),(x+1,y-1),(x+.7,y+.4)],'#668e5e')
    return s.finish()


def sails():
    s=Sheet(40,20,20)
    for i in range(4):
        a=i*TAU/4+.12;dx,dy=math.cos(a),math.sin(a);nx,ny=-dy,dx
        def p(t,w):return dx*t+nx*w,dy*t+ny*w
        s.line([p(0,0),p(18,0)],'#745e45',.45)
        s.poly([p(4,0),p(18,0),p(17,3),p(7,2)],'#d5c59f')
        for j in range(5,18,2):s.line([p(j,0),p(j,2.4)],'#9a8561',.14)
    s.oval(0,0,1.2,1.2,'#bda06b');return s.finish()


def scaffold(seed):
    m=model(seed)
    for x in (-8,8):
        for y in (-5,5):m.rod((x,y,0),(x,y,17),.18,'#9a805a')
    for z in (4,9,14):
        m.block(-8,4.5,z,16,2,.3,'#ba9b6d')
        m.rod((-8,5,z),(8,5,z+4),.1,'#8f7655')
    for i in range(9):m.rod((8,0,i*1.6),(8,2,i*1.6),.1,'#b3986c')
    return m.finish()


def foundation(seed):
    m=model(seed)
    m.block(-8,-6,-.3,16,12,.4,'#827359')
    for x,y,w,d in ((-8,-6,16,1),(-8,5,16,1),(-8,-6,1,12),(7,-6,1,12)):m.block(x,y,0,w,d,.9,'#a7a48c','stone')
    for x in (-8,8):
        for y in (-6,6):m.rod((x,y,0),(x,y,2.4),.13,'#ba9c6b')
    return m.finish()


def smoke(seed):
    s=Sheet(10,5,5);r=random.Random(seed)
    for i in range(12):
        a=i*.6;x=math.sin(a)*1.8;y=2-i*.3
        s.oval(x,y,1.2+i*.04,.7+i*.04,(212,216,195,35))
    return s.finish()


def flag(seed):
    s=Sheet(8,3,3)
    s.poly([(-3,-2),(1,-1.7),(3,0),(1,.5),(2,2),(-3,1.5)],'#8a4c63')
    s.line([(-3,-2),(1,-1.7),(3,0)],'#d9b46b',.17)
    s.poly([(-1,-1),(.1,-.2),(-1,.6),(-2,-.2)],'#e6cb89')
    return s.finish()


def glow(color,size=64):
    yy,xx=np.mgrid[:size,:size];d=np.hypot(xx-size/2+.5,yy-size/2+.5)/(size/2)
    alpha=np.clip(1-d,0,1)**2
    return Image.fromarray(np.uint8(np.dstack([np.full(d.shape,c) for c in rgb(color)]+[alpha*255])),'RGBA')


def draw_base(art):
    """Complete manifest. Unknown assets fail visibly instead of using old art."""
    name,*a=art
    culture=lambda c:c['name'] if isinstance(c,dict) else c
    if name in ('oak','birch','pine'):
        return tree(name,sp.LEAVES['pine' if name=='pine' else a[0]],int(a[1])%7)
    if name=='house':return house(culture(a[0]),a[1],a[2])
    if name=='fhouse':return fhouse(a[0],culture(a[1]),a[2],a[3])
    if name=='seat':return keep(culture(a[0]),a[1],a[2])
    if name=='seatx':return seatx(a[0],culture(a[1]),a[2],a[3])
    if name in ('temple','windmill'):return civic(name,culture(a[0]),2,a[1])
    if name=='tavern':return tavern('alpine',a[0] if a else 0)
    if name in ('arena','theatre','forge'):return civic(name,seed=a[0] if a else 0)
    if name=='elf_tower':return elf_tower(a[0] if a else 0)
    if name=='palm':return palm(a[0])
    if name=='great_tree':return great_tree(a[0] if a else 0)
    if name=='world_tree':return world_tree(a[0] if a else 1)
    if name=='landmark':return landmark(*a)
    if name=='boat':return boat(a[0] if a else 0)
    if name=='harbour_ship':return galleon(a[0] if a else 0)
    if name=='bridge':return bridge_art(a[0] if a else 0)
    if name in ('wall_tower','gatehouse'):return globals()[name](culture(a[0]))
    if name in ('terrace','ground_square','plaza','steps','wall','floating_isle','isle_shadow','rope','mist'):return globals()[name](*a)
    if name=='gold_pile':return prop(name,a[1] if len(a)>1 else 0,a[0])
    return prop(name,a[0] if a else 0)


def base_attachments(art):
    """Screen-space sockets for live effects, relative to the sprite foot."""
    name,*args=art
    if name=='house':
        culture=args[0]['name'] if isinstance(args[0],dict) else args[0]
        if culture not in ('arcane','eastern'):
            h=6+min(4,max(0,args[1]))*1.3
            return {'smoke':[(-.1,-h-13.7)]}
    if name=='windmill': return {'mills':[(-1.6,-20)]}
    if name=='seat' or (name=='seatx' and args[0] in ('citadel','gate','palace')):
        level=args[1] if name=='seat' else args[2]
        h=11+min(5,level)*1.8
        factor=.85+min(5,max(0,level))*.18
        return {'flags':[(x*factor,y*factor) for x,y in ((-5,-h-33),(11,-h-17.2))]}
    return {}


def draw(art):
    from detailed import draw as detailed_draw
    return detailed_draw(art)


def attachments(art):
    from detailed import attachments as detailed_attachments
    return detailed_attachments(art)
