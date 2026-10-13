# UI

Widgets and HUD art: buttons, panels, icons, cursors, bars.

Conventions (so art works with the future GUI system without rework):

- One file per widget state: `button_normal.png`, `button_hover.png`,
  `button_pressed.png`, `button_disabled.png`. Same pixel size per set.
- Stretchable panels/bars as 9-slice: keep a uniform, unscaled border in
  pixels and note its width in the file name or a sidecar
  (e.g. `panel_b12.png` = 12 px border) until the GUI docs define better.
- Icons on a consistent grid (e.g. 32×32); cursor hotspot top-left unless
  the file name says otherwise.
- Text labels render from `../Fonts/` once a font renderer exists — don't
  bake text into widget art except for logos.
