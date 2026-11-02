"""Render a review sheet of the actual procedural world assets."""
from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
import sprites

ASSETS=[
('Hearth Cottage',('house',{'name':'alpine'},2,0)),('Longhouse',('house',{'name':'nordic'},2,1)),('Balcony House',('house',{'name':'hanse'},2,2)),
('Storehouse Wing',('house',{'name':'alpine'},2,3)),('Side Hall',('house',{'name':'southern'},2,4)),('Covered Porch',('house',{'name':'hanse'},2,5)),
('Twin Dormers',('house',{'name':'nordic'},2,6)),('Tower Annex',('house',{'name':'arcane'},2,7)),('Alchemy House',('house',{'name':'arcane'},2,0)),
('Wizard Tower',('fhouse','wizard',{'name':'arcane'},2,2)),('Mushroom House',('fhouse','mushroom',{'name':'alpine'},2,3)),('Dwarven Hall',('fhouse','dwarf',{'name':'nordic'},2,2)),
('Keep',('seat',{'name':'nordic'},3,2)),('Temple',('temple',{'name':'alpine'},2)),('Elven Tower',('elf_tower',2)),
('Oak',('oak','leaf',2)),('Birch',('birch','leaf',3)),('Fir',('pine','pine',2)),
('Ruins',('ruin',2)),('Rock & Lichen',('rock',3)),('Wayside Shrine',('shrine',2)),
('Market',('market',2)),('Forge',('forge',2)),('Merchant Ship',('harbour_ship',2)),
('Windmill',('windmill',{'name':'alpine'},2)),('Well',('well',2)),('Cart',('cart',2)),
('Ferns',('ferns',2)),('Fallen Timber',('fallen_log',2)),('Road Lantern',('lantern_post',2)),
('Stone Wall',('kingdom_wall',26,4,'stone',1)),('Timber Wall',('kingdom_wall',26,4,'wood',1)),('Runic Wall',('kingdom_wall',26,4,'runic',1))]

if __name__=='__main__':
    root=Path(__file__).resolve().parents[2]/'previews/world-assets'
    root.mkdir(parents=True,exist_ok=True)
    cache=sprites.Cache('/tmp/world-review-sprites-v34-final')
    sheet=Image.new('RGB',(1500,((len(ASSETS)+2)//3)*310+95),'#d8d5c7');d=ImageDraw.Draw(sheet)
    font=ImageFont.truetype('/usr/share/fonts/TTF/DejaVuSans.ttf',20)
    title=ImageFont.truetype('/usr/share/fonts/TTF/DejaVuSans.ttf',30)
    d.text((30,25),'WORLD / Procedural Fantasy Assets',font=title,fill='#35483e')
    for i,(label,art) in enumerate(ASSETS):
        im,_,_=cache(art);im=im.copy();im.thumbnail((440,255),Image.Resampling.LANCZOS)
        x=i%3*500;y=95+i//3*310
        sheet.paste(im,(x+(500-im.width)//2,y+255-im.height),im)
        d.text((x+30,y+275),label,font=font,fill='#35483e')
    sheet.save(root/'assets.png')
    print(root/'assets.png')
