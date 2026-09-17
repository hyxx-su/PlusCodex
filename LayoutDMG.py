"""Write Finder presentation metadata without controlling Finder or changing user settings."""
import os
import sys
from ds_store import DSStore
from mac_alias import Alias

root = sys.argv[1]
with DSStore.open(os.path.join(root, '.DS_Store'), 'w+') as store:
    store['.']['bwsp'] = {
        'ShowStatusBar': False, 'ShowToolbar': False, 'ShowPathbar': False,
        'ShowSidebar': False, 'ShowTabView': False,
        # Allow for Finder's title/path bars around the 720 x 460 artwork.
        'WindowBounds': '{{180, 140}, {720, 520}}', 'ContainerShowSidebar': False,
    }
    store['.']['icvp'] = {
        'viewOptionsVersion': 1, 'backgroundType': 2,
        # Finder requires the color fields even when the background is an image.
        'backgroundColorRed': 1.0, 'backgroundColorGreen': 1.0, 'backgroundColorBlue': 1.0,
        'backgroundImageAlias': Alias.for_file(os.path.join(root, '.background', 'install.png')).to_bytes(),
        'iconSize': 88.0, 'textSize': 13.0, 'labelOnBottom': True,
        'arrangeBy': 'none', 'showItemInfo': False, 'showIconPreview': True,
        'gridSpacing': 100.0, 'gridOffsetX': 0.0, 'gridOffsetY': 0.0,
        'scrollPositionX': 0.0, 'scrollPositionY': 0.0,
    }
    store['.']['vSrn'] = ('long', 1)
    store['.']['vstl'] = ('type', b'icnv')
    store['.']['icvl'] = ('type', b'icnv')
    # Center the icon + filename group inside each 190-point card.
    store['PlusCodex.app']['Iloc'] = (187, 250)
    store['Applications']['Iloc'] = (533, 250)
