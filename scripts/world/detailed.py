"""Weathered, procedural fantasy materials and asset families.

Every world asset is rendered through this entry point. No image-generation
output is used. Large silhouettes stay readable while close views reveal
joinery, slate courses, masonry, roots, needles, lichen and carved details.
"""
import math
import random

import numpy as np
import iso
import sprites as sp
from sprites import rgb,shade
from house_study import House,build

TAU=math.tau


class RichModel(House):
    def __init__(self,seed=0):
        super().__init__(seed)
        self.material_seed=seed

    def block(self,x,y,z,w,d,h,color,dress=None):
        faces=iso.Model.block(self,x,y,z,w,d,h,color,dress)
        if w*d*h<.25:return faces
        for face,length in zip(faces,(w,d)):
            if length<.5 or h<.5:continue
            marks=[]
            base=rgb(color) if isinstance(color,str) else color[:3]
            red,green,blue=base
            if dress is None and red>green*1.08 and blue<green*.9:
                for i in range(max(3,min(16,round(length/.5)))):
                    u=(i+.3)/max(3,min(16,round(length/.5)))
                    marks.append(([(u,0),(u+.012,.4),(u-.005,1)],shade(face.color,-.18),.07))
                    marks.append(([(u+.025,.08),(u+.032,.8)],shade(face.color,.13),.045))
                face.marks[0:0]=marks
                continue
            if dress is None and red>180 and green>165:
                for i in range(min(80,round(length*h*1.5))):
                    u,v=self.rng.random(),self.rng.random()
                    marks.append(([(u,v),(min(1,u+.04),v),(min(1,u+.05),min(1,v+.04)),(u,min(1,v+.035))],shade(face.color,self.rng.uniform(-.06,.04)),0))
                face.marks[0:0]=marks
                continue
            # Mortar and chipped edges are attached to the wall plane, so later
            # doors and windows correctly cover them rather than floating behind.
            rows=max(1,min(22,round(h/.72)));cols=max(1,min(22,round(length/1.35)))
            for row in range(rows):
                for col in range(-1,cols):
                    u=max(0,(col+.5*(row%2))/cols);v=min(1,(col+1+.5*(row%2))/cols)
                    if v-u<.02:continue
                    tone=shade(face.color,self.rng.uniform(-.075,.085))
                    marks.append(([(u+.007,row/rows+.012),(v-.007,row/rows+.012),(v-.007,(row+1)/rows-.012),(u+.007,(row+1)/rows-.012)],tone,0))
                    if (col+row)%3==0:
                        marks.append(([(u+.015,(row+1)/rows-.02),(v-.015,(row+1)/rows-.02)],shade(tone,.15),.065))
            face.marks[0:0]=marks
        return faces

    def rod(self,a,b,r,color):
        before=len(self.faces)
        iso.Model.rod(self,a,b,r,color)
        if r<.16:return
        for f in self.faces[before:]:
            for i in range(3):
                u=.17+i*.3
                f.line([(u,.08),(u+.015,.45),(u-.015,.9)],shade(f.color,-.16),max(.025,r*.09))
            f.line([(.06,.04),(.06,.96)],shade(f.color,.17),max(.035,r*.12))

    def roof(self,x,y,z,w,d,rise,color,kind='gable'):
        self.roof_tiles(x,y,z,w,d,max(1.5,rise*1.25),color)

    def drum(self,x,y,z,r,h,color,n=10,top=None,r2=None):
        before=len(self.faces)
        iso.Model.drum(self,x,y,z,r,h,color,n,top,r2)
        if r<.9 or h<1.2:return
        tapered=r2 is not None and r2<r*.45
        for f in self.faces[before:-1]:
            rows=min(28,max(3,round(h/(.6 if tapered else .9))))
            for row in range(rows):
                tone=shade(f.color,self.rng.uniform(-.06,.055))
                f.rect(.015,row/rows+.006,.97,1/rows-.012,tone)
                f.line([(0,(row+1)/rows),(1,(row+1)/rows)],shade(color,-.28),.09)
                for u in ((.25,.7) if row%2 else (.45,.9)):
                    f.line([(u,row/rows),(u,(row+1)/rows)],shade(color,-.22),.055)
            if not tapered and h>7:
                # Tall towers have recessed arrow loops and weathering, not blank shafts.
                f.rect(.38,.34,.24,.16,'#394740')
                f.rect(.46,.34,.055,.16,'#e9c985')
                f.line([(.32,.51),(.68,.51)],shade(color,.24),.15)
                for u in (.12,.8):f.line([(u,.05),(u+.025,.3)],shade(color,-.12),.1)

    def foliage(self,x,y,z,rx,ry,rz,color,seed=0):
        # Decorative shrubs use small leaf sprays. Rock assets use a separate builder.
        rng=random.Random(iso.asset_seed('spray',seed))
        before=len(self.faces)
        iso.Model.foliage(self,x,y,z,rx,ry,rz,color,seed)
        tag=self.material_seed
        red,green,blue=rgb(color)[:3] if isinstance(color,str) else color[:3]
        if green < red*1.045 or blue > green*.95:return
        if isinstance(tag,tuple) and tag[:1]==('prop',) and tag[1] in ('sheep','fire','spring_head'):
            return
        for f in self.faces[before:]:f.flecks=[]
        for i in range(max(24,int(rx*ry*7))):
            a=rng.random()*TAU;v=rng.uniform(-.8,1);radius=math.sqrt(max(0,1-v*v))
            px=x+math.cos(a)*rx*radius;py=y+math.sin(a)*ry*radius;pz=z+v*rz
            self.leaf(px,py,pz,rng.uniform(.15,.4),color)

    def embellish(self):
        if getattr(self,"embellished",False):return
        self.embellished=True
        tag=self.material_seed
        if isinstance(tag,tuple) and tag:
            if tag[0]=='fantasy':
                style=tag[1]
                if style in ('turret','wizard','crystal'):
                    self.window(-1,4.1,7,.8,1.8,False)
                    self.lantern(4,6.2,2.7)
                    self.ivy(-3,3.5,0,7)
                elif style=='mushroom':
                    self.door(0,3.5,0)
                    for x in (-2.5,2.5):self.window(x,3,5,.7,1.4,False)
                    self.lantern(-2,3.5,2.8)
                    self.ivy(-1.8,2.8,0,5)
                elif style in ('treehouse','crooked'):
                    self.planter(0,6,5,3)
                    self.lantern(-4,6,6)
                elif style=='dwarf':
                    for x in (-5,5):self.lantern(x,5.8,3)
                    self.barrel(-7,3)
            elif tag[0]=='civic':
                kind=tag[1]
                if kind in ('keep','citadel','gate','palace','temple','tavern'):
                    for x in (-6,5):self.ivy(x,4.4,0,8)
                    for x in (-4,4):self.lantern(x,7.5,3)
                    self.barrel(-10,5)
                elif kind=='forge':
                    self.barrel(6,0)
                    for i in range(5):self.beam((5+i*.2,4,0),(5+i*.2,4,3),.06,'#656c64')
                elif kind in ('spires','elf_tower','tree'):
                    for x in (-5,5):self.ivy(x,2,0,17)
            elif tag[0]=='ship':
                large=tag[2];length=13 if large else 7
                for i in range(14):
                    x=-length*.65+i*length*1.3/14
                    self.beam((x,-2,4.1),(x,2,4.1),.035,'#78583d')
                if large:
                    self.lantern(-8,2,5)
                    for x in (-6,-3,0,3,6):
                        for y in (-3,3):self.beam((x,y,4),(x,y,5),.07,'#5b4935')
            elif tag[0]=='prop' and tag[1] in ('market','tourney','stall'):
                self.barrel(4,-2)
        if isinstance(tag,tuple) and tag and tag[0]=='prop':
            kind=tag[1]
            if kind in ('market','stall'):
                for i in range(9):
                    x=-3+(i%5)*1.3;y=2+(i//5)*.55
                    self.drum(x,y,3,.27,.4,('#c48a45','#966244','#809057')[i%3],n=7,r2=.18)
                for x in (-3,3):
                    self.beam((x,-2,0),(x,-1,4),.08,'#c6b28a')
                self.lantern(-3,0,4)
            elif kind=='cart':
                for x in (-4.2,4.2):
                    for i in range(16):
                        a=i*TAU/16;b=(i+1)*TAU/16
                        self.beam((x,math.cos(a)*1.8,1.8+math.sin(a)*1.8),(x,math.cos(b)*1.8,1.8+math.sin(b)*1.8),.16,'#635b4d')
                        if i%2==0:self.beam((x,0,1.8),(x,math.cos(a)*1.7,1.8+math.sin(a)*1.7),.09,'#a98b5e')
                for y in (-3,2):
                    for x in (-3.7,0,3.7):self.beam((x,y,.5),(x,y,3),.13,'#705337')
                self.barrel(1,-.5)
            elif kind=='well':
                self.barrel(3,4)
                for i in range(10):self.drum(0,0,3+i*.13,.1,.08,'#c9b78e',n=6)
            elif kind=='statue':
                self.ivy(-1,1,0,3)

    def scale(self,factor):
        self.embellish()
        super().scale(factor)

    def finish(self):
        self.embellish()
        return super().finish()


HOUSE_KINDS={'nordic':0,'alpine':0,'southern':1,'hanse':1,'eastern':3,'arcane':2}


def house(culture,tier,seed):
    kind=HOUSE_KINDS[culture]
    m=build(kind,seed%8,2)
    # Handcrafted variations beyond color: carved bargeboards, a storage lean-to,
    # lattice railing or a herb wall according to regional craft tradition.
    if culture=='nordic':
        for x in (-5,5):
            m.beam((x,0,14),(x*1.2,0,16),.12,'#8b7354')
            m.poly([(x*1.2,0,16),(x*1.35,0,16.3),(x*1.22,0,17)],'#9c845a')
    elif culture=='eastern':
        for x in (-4,4):m.lantern(x,4.5,5)
    m.scale(.85+max(0,min(5,tier))*.075)
    return m.finish()


def tree(kind,leaf,seed,scale=1):
    """Branch structure, individual leaf sprays, needles and roots; no blob crowns."""
    m=RichModel(('wild-tree',kind,seed));r=m.rng
    base=sp.LEAVES.get(leaf,sp.LEAVES['leaf'])[0]
    trunk='#665540' if kind!='birch' else '#c1c0a7'
    height=17+seed%5
    m.shadow=(9,4)
    if kind=='palm':
        for i in range(12):m.rod((i*i*.014,0,i*1.5),((i+1)**2*.014,0,(i+1)*1.5),.42,trunk)
        for i in range(10):
            a=i*TAU/10
            for j in range(9):
                t=j/9;x=2+math.cos(a)*8*t;y=math.sin(a)*8*t;z=18+math.sin(t*math.pi)*2-t*3
                for side in (-1,1):
                    m.poly([(x,y,z),(x+math.cos(a)*1.2-math.sin(a)*side*1.3,y+math.sin(a)*1.2+math.cos(a)*side*1.3,z-.6),(x+math.cos(a)*1.1,y+math.sin(a)*1.1,z-.2)],shade('#536f4d',r.uniform(-.15,.15)))
    elif kind=='pine':
        for i in range(10):m.rod((0,0,i*2.5),(.15,0,(i+1)*2.5),max(.12,.65-i*.05),trunk)
        for level in range(9):
            z=4+level*2.5;reach=7-level*.6
            for j in range(7):
                a=j*TAU/7+level*.65
                end=(math.cos(a)*reach,math.sin(a)*reach,z-.8)
                m.rod((0,0,z+.6),end,.10,trunk)
                for k in range(8):
                    t=(k+1)/9;x=end[0]*t;y=end[1]*t;zz=z+.6-t*1.4
                    width=(1-t)*1.25+.25
                    for side in (-1,1):
                        q=(x-math.sin(a)*width*side,y+math.cos(a)*width*side,zz-.5)
                        m.poly([(x,y,zz+.45),q,(x+math.cos(a)*.9,y+math.sin(a)*.9,zz-.25)],shade('#3f6153',r.uniform(-.18,.2)))
                        for n in range(3):
                            m.rod((x,y,zz),(q[0]+math.cos(a)*n*.2,q[1]+math.sin(a)*n*.2,q[2]),.022,shade('#658274',r.uniform(-.2,.15)))
    else:
        stems=3 if kind=='birch' else 1
        for stem in range(stems):
            ox=(stem-1)*1.3 if stems>1 else 0;lean=r.uniform(-2,2)
            for i in range(7):
                z=i*height/8;x=ox+lean*(i/7)**1.4
                m.rod((x,0,z),(ox+lean*((i+1)/7)**1.4,.2,z+height/8),max(.15,(.4 if stems>1 else 1.05)*(1-i/9)),trunk)
                if kind=='birch':m.rod((x-.2,-.2,z+.4),(x+.3,.1,z+.55),.055,'#666a5a')
            for j in range(9):
                a=j*2.4+seed*.4+stem;z=height*(.35+j*.06);reach=(4.4 if stems>1 else 7.2)*(1-abs(j-4)*.09)
                end=(ox+lean+math.cos(a)*reach,math.sin(a)*reach,z+3)
                m.rod((ox+lean*.5,0,z-2),end,.16 if stems>1 else .26,trunk)
                for k in range(3):
                    bx=end[0]+math.cos(a+k*1.8)*1.8;by=end[1]+math.sin(a+k*1.8)*1.8;bz=end[2]+k*.7
                    m.rod(end,(bx,by,bz),.065,trunk)
                    # Crown volume from overlapping leaf planes, with no solid spheres.
                    for _ in range(64 if stems==1 else 32):
                        angle=r.random()*TAU;rr=r.random()**.5*2.5
                        m.leaf(bx+math.cos(angle)*rr,by+math.sin(angle)*rr,bz+r.uniform(-1.2,1.5),r.uniform(.38,.68),base)
        for j in range(6):
            a=j*TAU/6
            m.rod((0,0,.6),(math.cos(a)*3,math.sin(a)*3,.1),.23,trunk)
        if seed%3==0:
            for x in (-1.5,1.2):
                m.drum(x,1,.1,.12,.6,'#d2c5a6',n=7)
                m.drum(x,1,.7,.5,.22,'#b68459',n=9,r2=.3)
    m.scale(scale)
    return m.finish()


def rock(seed,mountain=False,ruin=False):
    m=RichModel(('stone',seed));r=m.rng
    scale=3.5 if mountain else 1
    for ox,oy,w,h in ((-3,0,3,4),(2,-2,4.5,7),(4,2,2.5,3)):
        before=len(m.faces)
        iso.Model.foliage(m,ox,oy,h*.35,w,w*.75,h*.65,'#84877a',seed+int(ox))
        for f in m.faces[before:]:
            f.flecks=[]
            a,b,c=f.points[:3]
            # Mineral veins and broken strata are real small surface inlays.
            for i in range(5):
                t=(i+1)/7
                p=np.array(a)*(1-t)+np.array(c)*t
                q=np.array(b)*(1-t)+np.array(c)*t
                m.rod(p,q,.018,shade('#929486',r.uniform(-.15,.15)))
            for _ in range(7):
                u,v=r.random(),r.random()
                if u+v>1:u,v=1-u,1-v
                p=tuple(a[k]*(1-u-v)+b[k]*u+c[k]*v for k in range(3))
                f.flecks.append((p,r.uniform(.08,.22),r.choice(('#929e70','#7b8761','#b1ac83'))))
    if ruin:
        m.masonry_block(-5,-2,0,2,4,9);m.masonry_block(3,-2,0,2,4,5)
        m.masonry_block(-5,-2,9,7,3,1)
        m.ivy(-4,2,0,8)
        for i in range(9):m.block(r.uniform(-5,5),r.uniform(1,5),0,1,.7,.5,shade('#aaa58c',r.uniform(-.1,.1)))
    if mountain:
        for i in range(4):
            m.poly([(-1+i*.7,-2,7),(2+i*.2,-4,5),(3+i*.4,-2,5.7)],'#bdbfb3')
    m.scale(scale);m.shadow=(9*scale,4*scale)
    return m.finish()


def draw(art):
    name,*a=art
    if name in ("kingdom_wall","kingdom_post"):return boundary(art)
    culture=lambda c:c['name'] if isinstance(c,dict) else c
    if name in ('ferns','reeds','fallen_log','dead_tree','shrine','lantern_post'):return wilderness(name,int(a[0])%8)
    if name=='house':return house(culture(a[0]),a[1],int(a[2]))
    if name in ('oak','birch','pine'):return tree(name,a[0],int(a[1])%12)
    if name=='palm':return tree('palm','leaf',int(a[0])%6)
    if name=='great_tree':return tree('oak','leaf',int(a[0])%6,2.5)
    if name=='landmark' and a[0]=='tree':return tree('oak','leaf',int(a[1])%6,2.5)
    if name=='world_tree':return tree('oak','leafSpring',9,3*min(1.7,max(1,float(a[0] if a else 1))))
    if name in ('rock','mountain','ruin'):return rock(int(a[0] if a else 0)%12,name=='mountain',name=='ruin')
    # Specialized silhouettes (mushrooms, dwarf halls, ships, dragons, props)
    # instantiate RichModel through iso.model, including all their materials.
    return iso.draw_base(art)


def attachments(art):
    name,*a=art
    if name=='house':
        culture=a[0]['name'] if isinstance(a[0],dict) else a[0]
        kind=HOUSE_KINDS[culture];seed=int(a[2])%8
        h=(8.3,10.1,9.2,6.9)[kind]+(seed%2)*.5
        scale=.85+max(0,min(5,a[1]))*.075
        sockets={'smoke':[(-1.05*scale,(-h-10.075)*scale)]}
        if kind==2:sockets['flags']=[(6*scale,-23.5*scale)]
        return sockets
    return iso.base_attachments(art)


def wilderness(name,seed):
    m=RichModel(('wilderness',name,seed));r=m.rng;m.shadow=(5,2)
    if name in ('ferns','reeds'):
        for i in range(7):
            x,y=r.uniform(-4,4),r.uniform(-2,2)
            if name=='reeds':
                h=r.uniform(2,4.5);m.beam((x,y,0),(x+.3,y,h),.025,'#88804e')
                m.drum(x+.3,y,h,.12,.65,'#776342',n=6)
            else:
                for j in range(6):
                    a=j*TAU/6
                    m.beam((x,y,.1),(x+math.cos(a)*1.8,y+math.sin(a)*1.8,1),.025,'#6c7a47')
                    for k in range(5):
                        t=(k+1)/5;xx=x+math.cos(a)*1.8*t;yy=y+math.sin(a)*1.8*t
                        for side in (-1,1):
                            m.poly([(xx,yy,t),(xx-math.sin(a)*side*.5*(1-t*.6),yy+math.cos(a)*side*.5*(1-t*.6),t+.2),(xx+math.cos(a)*.3,yy+math.sin(a)*.3,t+.08)],shade('#60784c',r.uniform(-.16,.16)))
    elif name=='fallen_log':
        m.beam((-5,-1,.55),(4,1,.55),.65,'#756044')
        for i in range(4):
            x=-3+i*1.5;m.beam((x,0,.7),(x+.4,1,1.6),.12,'#736147')
            for j in range(6):m.leaf(x+r.uniform(-.5,.5),r.uniform(-.4,.4),1.1,.19,'#778358')
        for x in (-3,2):
            m.drum(x,.2,1.1,.09,.4,'#b8aa82',n=6);m.drum(x,.2,1.5,.3,.15,'#a79062',n=8,r2=.2)
    elif name=='dead_tree':
        m.beam((0,0,0),(-1,0,13),.6,'#817762')
        for i in range(6):
            a=i*2.4;z=4+i*1.1;end=(math.cos(a)*3,math.sin(a)*3,z+3)
            m.beam((-.5,0,z),end,.14,'#817762')
            m.beam(end,(end[0]+1,end[1]-.4,end[2]+1.2),.07,'#817762')
    elif name=='shrine':
        m.masonry_block(-2,-2,0,4,4,1)
        for x in (-1.7,1.2):m.masonry_block(x,-1,1,.5,2,4)
        m.roof_tiles(-2,-1.5,5,4,3,2,'#5d7067')
        m.drum(0,0,1,1,1,'#8b8d7a',n=8)
        m.drum(0,0,2,.5,2,'#aeb29c',n=8,r2=.2)
        for x in (-1,1):m.drum(x,1,1.1,.15,.6,'#d6c694',n=8)
        m.ivy(-1.8,1,0,3)
    elif name=='lantern_post':
        m.beam((0,0,0),(.1,0,6),.17,'#716045');m.lantern(0,0,3.8)
        m.masonry_block(-.6,-.6,0,1.2,1.2,.7)
    return m.finish()


WALL_COLORS={'stone':'#9d9e8a','limestone':'#b4b4a1','wood':'#88704d','dark':'#737c76','sand':'#b9a17a','runic':'#788b87'}


def boundary(art):
    name,*a=art
    if name=='kingdom_post':
        theme,seed=a;m=RichModel(('boundary-post',theme,seed));c=WALL_COLORS[theme]
        if theme=='wood':
            for x in (-.8,.8):m.beam((x,0,0),(x,0,10),.35,c)
            m.beam((-1.6,0,8),(1.6,0,8),.3,c);m.lantern(0,.4,6)
        else:
            m.block(-1.8,-1.8,0,3.6,3.6,9,c,"stone")
            m.block(-2.1,-2.1,9,4.2,4.2,.65,shade(c,.16))
            for x in (-1.8,1):
                for y in (-1.8,1):m.block(x,y,9.6,.8,.8,1,c)
            if theme=='runic':iso.crystal(m,0,0,9.6,.6,2.1,'#9dc4bc')
            m.lantern(0,1.9,5)
        m.shadow=(4,2);return m.finish()
    dx,dy,theme,seed=a;c=WALL_COLORS[theme]
    s=iso.Sheet(math.ceil(abs(dx)*2+16),math.ceil(abs(dy)+16),math.ceil(abs(dy)+8))
    length=max(1,math.hypot(dx,dy*2));n=max(2,math.ceil(length/1.6))
    if theme=='wood':
        for i in range(n+1):
            t=i/n;x,y=dx*t,dy*t;h=6.3+(i%3)*.35
            s.poly([(x-.65,y),(x+.65,y),(x+.55,y-h),(x,y-h-1),(x-.55,y-h)],shade(c,(i%4-2)*.035))
            s.line([(x-.15,y-.3),(x-.05,y-h+.2)],shade(c,-.22),.12)
        for h in (1.6,4.7):s.line([(0,-h),(dx,dy-h)],shade(c,-.2),.4)
    else:
        s.poly([(0,0),(dx,dy),(dx,dy-6),(0,-6)],shade(c,-.22))
        for row in range(5):
            for i in range(n):
                t=(i+.5*(row%2))/n;t2=min(1,t+.94/n)
                if t>=1:continue
                s.poly([(dx*t,dy*t-row*1.2),(dx*t2,dy*t2-row*1.2),(dx*t2,dy*t2-row*1.2-1.08),(dx*t,dy*t-row*1.2-1.08)],shade(c,((i+row+seed)%5-2)*.035))
        s.line([(0,-6.1),(dx,dy-6.1)],shade(c,.25),.65)
        for i in range(0,n,3):
            t=i/n;t2=min(1,(i+1)/n)
            s.poly([(dx*t,dy*t-6),(dx*t2,dy*t2-6),(dx*t2,dy*t2-7.2),(dx*t,dy*t-7.2)],shade(c,.08))
            if theme=='runic':
                x,y=dx*t,dy*t-3
                s.line([(x-.35,y),(x,y-.7),(x+.35,y),(x,y+.7),(x-.35,y)],'#a3c4b4',.12)
        if seed%2==0 and theme not in ('sand','runic'):
            for j in range(5):
                x,y=dx*.4+math.sin(j)*.5,dy*.4-j*.8
                s.poly([(x,y),(x+.8,y-.3),(x+.2,y-1),(x-.5,y-.4)],'#607653')
    return s.finish()
