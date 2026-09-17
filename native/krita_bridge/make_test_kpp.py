#!/usr/bin/env python3
"""Create synthetic Krita .kpp preset files for bridge loader testing.

Real Krita .kpp = ZIP containing an XML named after the preset with
<Paintop><param id="..." value="..."/></Paintop> entries.
We generate: one DEFLATED (like Krita's KoStore) and one STORED.
"""
import zipfile
import sys

XML_PARAMS = """<?xml version="1.0" encoding="UTF-8"?>
<Paintop id="paintbrush" name="paintbrush" maskFunct="{751e74c4-4ba8-4518-b926-fd84ac9e0e4c}">
  <option name="paintaction" type="string">w = f(x) + s</option>
  <param id="brush_size" min="1" max="1000" value="77"/>
  <param id="brush_opacity" min="0" max="1" value="0.42"/>
  <param id="brush_spacing" min="0" max="1" value="0.07"/>
  <param id="hardness" min="0" max="1" value="0.64"/>
  <param id="eraser" value="0"/>
</Paintop>
"""

DAB_XML = """<?xml version="1.0" encoding="UTF-8"?>
<Brush type="mask">
  <param id="diameter" value="33"/>
</Brush>
"""


def build(path: str, method: int) -> None:
    with zipfile.ZipFile(path, "w", method) as z:
        # A decoy nested XML that must be ignored (subdirectory entry).
        z.writestr("sub/decoy.xml", XML_PARAMS.replace("77", "1"))
        # The real preset XML — named after the preset, like real .kpp files.
        z.writestr("Synthetic Test.xml", XML_PARAMS)
        # A brush tip XML that comes alphabetically later but also has params.
        z.writestr("brush.tip.xml", DAB_XML)
    print(f"wrote {path} (method={method})")


if __name__ == "__main__":
    outdir = sys.argv[1] if len(sys.argv) > 1 else "/tmp"
    build(f"{outdir}/synthetic-deflated.kpp", zipfile.ZIP_DEFLATED)
    build(f"{outdir}/synthetic-stored.kpp", zipfile.ZIP_STORED)
