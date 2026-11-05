# Ledge Display Black

Derived from Noto Serif SC, a SIL Open Font License 1.1 font. The complete
license and upstream notice are in `OFL.txt`; the font's original copyright
metadata is also retained. This font remains under OFL, separately from the
application's MIT license.

- Upstream: https://github.com/notofonts/noto-cjk
- Revision: `985fa52c81c1d6692ccdd82bc3656e8fb932fd89`
- Source: `google-fonts/NotoSerifSC[wght].ttf`
- Source SHA256: `050080d9255a86808f2945bffac582b31ef32bc36411ce29563b4961670c66f9`
- Modifications: instantiate weight 900, subset to `DisplayCharacters.txt`,
  rename family/full/PostScript names to Ledge Display / LedgeDisplay-Black.
- Rebuild: `python app/Tools/subset-display-font.py /path/to/source.ttf`, using
  fonttools 4.60.1. The full upstream font is not bundled or installed.

The fixed-character subset includes Latin and the current Simplified and
Traditional Chinese display copy. User-defined names use the system Songti SC
Black cascade for characters outside this subset.

If Songti SC Black also lacks a character, macOS may use its final system
fallback. This preserves rare characters in user-defined names rather than
showing missing-glyph boxes; approved for this skin's first implementation.
