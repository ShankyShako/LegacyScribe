# Icons

The app icon (concept "helix as waveform": a double helix whose strands follow a speech envelope and whose rungs are level bars) is drawn by script so it can be regenerated.

- `python3 gen_app_icon.py ../../Hex/AppIcon.icon` rewrites the three layer SVGs (`back`, `rungs`, `front`) in the Icon Composer document. Glass, shadow and translucency per layer live in `Hex/AppIcon.icon/icon.json`; open the `.icon` in Icon Composer (inside Xcode.app/Contents/Applications) to tune them.
- `python3 gen_menubar_glyph.py` (run from this folder) writes `helix-template.svg`, the one-color menu bar template image: 1.5 turns instead of 2.5 so it reads at 18 pt. Copy it to `Hex/Assets.xcassets/HexIcon.imageset/helix.svg`.
- Preview without Xcode: `ictool Hex/AppIcon.icon --export-image --output-file out.png --platform macOS --rendition Default --width 512 --height 512 --scale 1` (renditions also `Dark`, `ClearLight`, `ClearDark`, `TintedLight`, `TintedDark`). `ictool` is in `Icon Composer.app/Contents/Executables/`.
