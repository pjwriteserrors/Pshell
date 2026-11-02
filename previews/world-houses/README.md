# Interactive isometric house study

Open `index.html` in a browser alongside `houses.js`. No server or external
libraries are required. The preview renders procedural geometry with depth testing,
individual shingles, masonry, beams, windows and props.

Select variants I–III, scroll to zoom, click to focus, and press Escape to return.
Use the lighting slider and pause button to inspect animated smoke, flags and windows.
Reduced-motion preferences are respected.

Regenerate with `python scripts/world/house_study.py`. The exporter uses NumPy and
Pillow. `houses.js` contains compressed geometry and animation attachment points.
