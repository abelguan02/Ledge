"""Build the renamed, static Black display subset. Requires fonttools 4.60.1.

Usage: python subset-display-font.py /path/to/NotoSerifSC.ttf
The upstream font is never installed or modified in place.
"""
from pathlib import Path
import hashlib
import sys
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools import subset

root = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1])
characters = (root / "Resources/Fonts/DisplayCharacters.txt").read_text()
font = instantiateVariableFont(TTFont(source), {"wght": 900}, inplace=True)
options = subset.Options()
options.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14, 16, 17]
options.name_languages = [0x409]
subsetter = subset.Subsetter(options=options)
subsetter.populate(text=characters)
subsetter.subset(font)
# Subsetting is a modification. Use a new family and PostScript name, retaining
# upstream copyright and license metadata and shipping the complete OFL text.
names = {1: "Ledge Display", 2: "Black", 3: "LedgeDisplay-Black-1.0",
         4: "Ledge Display Black", 6: "LedgeDisplay-Black",
         16: "Ledge Display", 17: "Black"}
for name_id, value in names.items():
    font["name"].removeNames(nameID=name_id)
    font["name"].setName(value, name_id, 3, 1, 0x409)
font.recalcTimestamp = False
destination = root / "Resources/Fonts/LedgeDisplay-Black.ttf"
font.save(destination)
missing = set(characters) - set(map(chr, font.getBestCmap())) - {"\n"}
assert not missing, f"Missing fixed characters: {sorted(missing)}"
print(f"Source SHA256: {hashlib.sha256(source.read_bytes()).hexdigest()}")
print(f"Subset: {destination.stat().st_size} bytes; {len(font.getBestCmap())} characters")
