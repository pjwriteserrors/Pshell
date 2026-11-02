# Procedural fantasy world assets

`assets.png` shows actual assets from the world renderer. `world.png` and
`city.png` show a synthetic settlement rendered through the real world pipeline.

Houses have eight structural profiles per regional craft. The settlement planner
penalizes repeated silhouettes among the five nearest houses. Kingdom boundaries
use stone, limestone, timber, dark mountain stone, sandstone or rune-carved walls,
with an entrance opening connected to the walking network.

The shell caches procedural geometry as sprites and high-resolution city plates.
Water, smoke, flags, windmills and residents remain animated in QML. The live
WebGL house study is available in `../world-houses/index.html`.

Regenerate the asset sheet with `python scripts/world/asset_sheet.py`.
Run checks with `python -m unittest discover -s scripts/world -p 'test_*.py'`.
