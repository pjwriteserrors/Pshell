"""Deterministic, organically grown settlements around crooked roads.

All distances are measured on the ground plane (screen y / FLAT). Houses,
paths, plazas and walking nodes share the same layout, including live plots.
"""
import math
import random


def plan(world,realm,houses,kind):
    import world as w
    rng=random.Random(w.stable('grown-settlement',realm['key'],kind))
    count=len(houses);level=w.seat_level(realm);shape=w.ARCHETYPES[kind]
    radius=92+math.sqrt(count+4)*22+max(0,count-20)*3
    best=realm['centre']
    for reach in range(70):
        candidates=[(realm['centre'][0]+a,realm['centre'][1]+b) for a,b in ((reach,0),(0,reach),(-reach,0),(0,-reach),(reach,-reach),(-reach,reach))]
        found=next((p for p in candidates if all(math.hypot(w.to_xz(p)[0]-o['x'],(w.to_xz(p)[1]-o['z'])/w.FLAT)>radius+o['wall']+40 for o in world.plans)),None)
        if found is not None:best=found;break
    else:raise ValueError('No separated settlement site found')
    hx,hz=w.to_xz(best);realm['centre']=best;realm['styles']=shape['houses']
    flat=w.FLAT
    def screen(p):return hx+p[0],hz+p[1]*flat
    def distance(a,b):return math.hypot(a[0]-b[0],a[1]-b[1])
    # Off-centre stronghold and market. Neither is a concentric terrain tier.
    keep=(-radius*.22,-radius*.24)
    market=(radius*.12,radius*.12)
    gate_local=(radius*.3,radius*.88)
    keep_screen=screen(keep);gate=screen(gate_local)
    record={'x':hx,'z':hz,'wall':radius+20,'realm':realm,'top':0,'tiers':1,'rings':[], 'kind':kind,'organic':True,'keep':keep_screen}
    world.plans.append(record);realm['plan']=record
    # Move existing objects out of the reserved district before repopulating it.
    reach=math.ceil((radius+35)/(w.PITCH*w.ISO*.7))+5
    for a in range(-reach,reach+1):
        for b in range(-reach,reach+1):
            lot=(best[0]+a,best[1]+b)
            if w.in_ellipse(*w.to_xz(lot),hx,hz,radius+28):
                world.lots[lot]='district';world.road_lots.discard(lot)
    for item in world.things:
        if item in houses or (item['kind']=='seat' and item['realm']==realm['index']):continue
        if w.in_ellipse(item['x'],item['z'],hx,hz,radius+25):
            lot=world.nearest_free(item['lot'],limit=20000)
            item['lot']=lot;item['x'],item['z']=w.wobble(lot,.4)
            world.lots[lot]='tree' if item['kind']=='tree' else 'prop'

    def put(art,p,what='deco',day=None):
        x,z=screen(p)
        item={'make':lambda art=art:art,'x':x,'z':z,'day':realm['first'] if day is None else day,'plot':None,'realm':realm['index'],'kind':what,'lot':best,'yaw':0,'scale':1.,'city':True,'lift':0}
        world.things.append(item);return item

    for item in world.things:
        if item['kind']=='seat' and item['realm']==realm['index']:
            item.update(x=keep_screen[0],z=keep_screen[1],city=True,lift=0)
            item.pop('block',None);item.pop('order',None)
            style=shape['keep']
            item['make']=(lambda:('seat',realm['culture'],level,w.stable(realm['key'])%8)) if style=='hall' else (lambda style=style:('seatx',style,realm['culture'],level,w.stable(realm['key'])%8))
    # Connected crooked roads. Offsets vanish at endpoints, retaining junctions.
    roads=[];nodes=[];first=len(world.path_nodes)
    node_lookup={}
    def node(p):
        key=(round(p[0],4),round(p[1],4))
        if key not in node_lookup:
            x,z=screen(p);node_lookup[key]=world.add_node(x,z)
            nodes.append(p)
        return node_lookup[key]
    def road(a,b,bend):
        length=distance(a,b);n=max(3,math.ceil(length/7));normal=(-(b[1]-a[1])/max(1,length),(b[0]-a[0])/max(1,length))
        pts=[]
        for i in range(n+1):
            t=i/n;wave=math.sin(math.pi*t)*bend+math.sin(math.pi*2*t)*bend*.25
            pts.append((a[0]+(b[0]-a[0])*t+normal[0]*wave,a[1]+(b[1]-a[1])*t+normal[1]*wave))
        ids=[node(p) for p in pts]
        for a_id,b_id in zip(ids,ids[1:]):world.add_link(a_id,b_id)
        roads.append(pts)
    road(gate_local,market,rng.uniform(-12,12))
    # District arms turn around the stronghold rather than radiating evenly.
    arms=[(-radius*.78,radius*.20),(radius*.73,-radius*.21),(-radius*.15,-radius*.72)]
    for i,end in enumerate(arms):
        junction=(market[0]+rng.uniform(-15,15),market[1]+rng.uniform(-12,12))
        road(market,junction,0)
        if i==2:
            via=(radius*.25,-radius*.36);road(junction,via,-6);road(via,end,8)
        else:road(junction,end,rng.uniform(-18,18))
    door=(keep[0]-8,keep[1]+14)
    # A lane to the stronghold, terminating at its threshold.
    keep_approach=min(nodes,key=lambda p:distance(p,door));road(keep_approach,door,3)
    all_road_points=[p for line in roads for p in line]
    # Rejection sampling yields small street-side groups, not rings or grids.
    slots=[];reserved=[(keep,42),(market,24)]
    def free(p,margin=31):
        return all(distance(p,q)>margin for q in slots) and all(distance(p,q)>r for q,r in reserved)
    budget=max(3000,(count+4)*300)
    for attempt in range(budget):
        line=roads[rng.randrange(len(roads))]
        k=rng.randrange(max(1,len(line)-1));a,b=line[k],line[k+1]
        length=max(1,distance(a,b));t=rng.random();side=rng.choice((-1,1));offset=rng.uniform(20,34)
        p=(a[0]+(b[0]-a[0])*t-(b[1]-a[1])/length*side*offset,a[1]+(b[1]-a[1])*t+(b[0]-a[0])/length*side*offset)
        if distance(p,(0,0))>radius-16 or not free(p):continue
        if min(distance(p,q) for q in all_road_points)<17:continue
        slots.append(p)
        if len(slots)>=count+3:break
    # For unusually dense histories, expand the village with branch roads.
    while len(slots)<count+3:
        i=len(slots);a=i*2.399963;rr=radius*.5+math.sqrt(i+1)*20
        p=(math.cos(a)*rr,math.sin(a)*rr)
        if free(p):
            nearest=min(nodes,key=lambda q:distance(p,q));endpoint=(p[0]-8,p[1]+12)
            road(nearest,endpoint,rng.uniform(-5,5));slots.append(p)
            radius=max(radius,distance(p,(0,0))+25)
        else:
            # Deterministic spare-site search with a strictly advancing angle.
            for j in range(1,1000):
                a=(i+j*.17)*2.399963;rr=radius*.75+j*.8;p=(math.cos(a)*rr,math.sin(a)*rr)
                if free(p):
                    nearest=min(nodes,key=lambda q:distance(p,q));road(nearest,(p[0]-8,p[1]+12),0);slots.append(p);radius=max(radius,distance(p,(0,0))+25);break
            else:raise ValueError('Settlement capacity exhausted')
    # Houses are assigned in historical order. No work/ticket data is discarded.
    used=[]
    for i,(item,p) in enumerate(zip(sorted(houses,key=lambda it:(it['day'],it['lot'])),slots)):
        x,z=screen(p);tier=max(0,min(4,1+int((1-distance(p,market)/radius)*3)+(i%4==0)))
        item.update(x=x,z=z,lift=0,city=True,tier=tier,ring=0)
        item.pop('block',None);item.pop('order',None)
        key=item['lot'];item['make']=lambda tier=tier,key=key:w.house_art(realm,tier,key)
        entrance=(p[0]-5,p[1]+5)
        nearest=min(nodes,key=lambda q:distance(q,entrance))
        lane=[screen(entrance),screen(nearest)]
        world.city_lanes.append(lane)
        world.add_link(node(entrance),node(nearest));used.append(p)
    record['wall']=radius+20
    # Clearings retain undergrowth; stone outcrops and ruins occupy the outskirts.
    greens=shape['green']
    for i in range(max(48,count*4)):
        a=rng.random()*math.tau;rr=radius*rng.uniform(.45,.95);p=(math.cos(a)*rr,math.sin(a)*rr)
        if not free(p,21) or min(distance(p,q) for q in nodes)<8:continue
        name=greens[i%len(greens)]
        art=(name,i%12) if name=='palm' else (name,'pine' if name=='pine' else 'leaf',i%12)
        put(art,p,'tree')
        if i%3==0:put(('rock',i%8),(p[0]+7,p[1]+4),'ground')
    for i in range(3):
        p=(-radius*.55+i*radius*.24,-radius*.67-rng.uniform(0,12))
        if free(p,30):put(('ruin' if i==1 else 'mountain' if kind=='crag' else 'shrine' if i==2 else 'rock',i+2),p)
    # The market grows along one street edge, with uneven gaps and small courtyards.
    mx,mz=screen(market);realm['square']=(mx,mz,17);realm['stalls']=[]
    put(('plaza',14),market,'ground');put(('well' if kind=='grove' else 'fountain',0),market)
    for i in range(min(5,2+count//7)):
        p=(market[0]-15+i*7+rng.uniform(-1,1),market[1]-13+rng.uniform(-2,2))
        put(('stall',i),p);realm['stalls'].append(screen((p[0],p[1]+5)))
    for p in (gate_local,(market[0]+9,market[1]+8)):
        put(('lantern_post',rng.randrange(8)),(p[0]+5,p[1]))
    for points in roads:world.city_roads.append([screen(p) for p in points])
    record.update(gate=gate,gate_node=node(gate_local),door=screen(door),route=[screen(door),screen(keep_approach)],spots=[screen(p) for p in nodes[::max(1,len(nodes)//30)]],glows=[screen(market)] if kind in ('grove','arcane') else [],slots=[(0,*screen(p)) for p in slots],used=len(houses),lift=lambda slot:0)
    realm['nodes']=[first,len(world.path_nodes)]
    # Invert the isometric hex projection to reserve the actual building sites.
    for p in slots+[keep]:
        x,z=screen(p)
        xx=(x/.7071+z/.3535)/2;zz=(z/.3535-x/.7071)/2
        r=zz/(w.PITCH*.866*w.ISO);q=xx/(w.PITCH*w.ISO)-r/2
        world.lots[(round(q),round(r))]='house' if p!=keep else 'seat'


def diversify(world,realm):
    """Prefer different silhouettes among the five nearest occupied plots."""
    import world as w
    from collections import Counter
    homes=sorted((i for i in world.things if i['kind']=='house' and i['realm']==realm['index']),key=lambda i:(i['day'],i['lot']))
    styles=list(dict.fromkeys(realm.get('styles') or w.VILLAGE_STYLES.get(realm['culture']['name'],('house',))))
    if 'house' not in styles:styles.append('house')
    candidates=[(s,v) for s in styles for v in range(8)]
    choices={};placed=[];used=Counter()
    for item in homes:
        nearest=sorted(placed,key=lambda p:math.hypot(item['x']-p[0],(item['z']-p[1])/w.FLAT))[:5]
        def score(c):
            # Ordinary homes have eight structural designs; specialist homes
            # share a silhouette, regardless of their material seed.
            sig=lambda a:(a[0],a[1] if a[0]=='house' else 0)
            penalty=sum((6-j)*100 for j,p in enumerate(nearest) if sig(c)==sig(p[2]))
            return penalty+used[c]*7+w.chance('variety',realm['key'],item['lot'],c)*4
        choice=min(candidates,key=score);choices[item['lot']]=choice;used[choice]+=1
        placed.append((item['x'],item['z'],choice))
        item['make']=lambda key=item['lot'],tier=item.get('tier',2):w.house_art(realm,tier,key)
    realm['house_choices']=choices


def enclose(world,realm):
    """A continuous themed boundary, with a real opening on the entrance road."""
    import world as w
    p=realm.get('plan')
    if not p:
        cx,cz=w.to_xz(realm['centre'])
        homes=[i for i in world.things if i['realm']==realm['index'] and i['kind'] in ('seat','house')]
        if not homes:return
        radius=max(65,max(math.hypot(i['x']-cx,(i['z']-cz)/w.FLAT) for i in homes)+22)
        kind={'nordic':'hill','alpine':'hill','hanse':'canals','southern':'bastide','eastern':'oasis','arcane':'arcane'}.get(realm['culture']['name'],'hill')
        gate=w.to_xz(realm['gate'])
        p={'x':cx,'z':cz,'wall':radius+8,'kind':kind,'gate':gate,'gate_node':None,'small':True}
        realm['boundary_plan']=p
    themes={'hill':'stone','bastide':'stone','canals':'limestone','grove':'wood','crag':'dark','oasis':'sand','arcane':'runic','isles':'runic'}
    theme=themes[p['kind']];radius=p['wall']-8;cx,cz=p['x'],p['z']
    gx,gz=p['gate'];angle=math.atan2((gz-cz)/w.FLAT,gx-cx);gap=14/radius
    def at(a):
        r=radius+3*math.sin((a-angle)*5)
        return round(cx+math.cos(a)*r,2),round(cz+math.sin(a)*r*w.FLAT,2)
    gate=at(angle);old=p['gate'];p['gate']=gate
    if p['gate_node'] is not None:
        new=world.add_node(*gate);world.add_link(new,p['gate_node']);p['gate_node']=new
        world.city_roads.append([old,gate])
    points=[at(angle+gap+(math.tau-2*gap)*i/48) for i in range(49)]
    def put(art,pt):
        world.things.append(dict(make=lambda:art,x=pt[0],z=pt[1],day=realm['first'],plot=None,realm=realm['index'],kind='wall',lot=realm['centre'],yaw=0,scale=1.,city=True,lift=0))
    for i,(a,b) in enumerate(zip(points,points[1:])):
        put(('kingdom_wall',round(b[0]-a[0],2),round(b[1]-a[1],2),theme,i%3),a)
    for i in (0,8,16,24,32,40,48):put(('kingdom_post',theme,i%3),points[i])
    p['boundary']=points;p['wall_theme']=theme;p['gate_width']=28
