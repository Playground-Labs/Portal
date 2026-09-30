"""Let our extension preserve the full monitor layout instead of only the last screen.

Pinned upstream already exposes the extension mechanism; its built-in -308 handler
runs first and discards the other screens. This narrowly scoped hook is the only patch.
"""
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text()
anchor = '      if (rect.encoding == rfbEncodingExtDesktopSize) {\n'
assert source.count(anchor) == 1, 'Upstream layout handling changed; review the patch.'
source = source.replace(anchor, '''      if (rect.encoding == rfbEncodingExtDesktopSize) {
        rfbBool handled = FALSE;
        rfbClientProtocolExtension* extension;
        for (extension = rfbClientExtensions; extension && !handled; extension = extension->next)
          if (extension->handleEncoding) handled = extension->handleEncoding(client, &rect);
        if (handled) continue;
      }
''' + anchor)
path.write_text(source)
