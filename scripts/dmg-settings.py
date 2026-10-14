# dmgbuild settings for Sigil's DMG window. Layout must match scripts/make-dmg-background.swift.
import os.path

app = defines.get("app", "build/Sigil.app")  # noqa: F821 (provided by dmgbuild)
appname = os.path.basename(app)

format = "ULFO"          # lzfse-compressed, as Sparkle recommends
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}

icon = defines.get("volicon")            # noqa: F821  volume icon in Finder sidebar / desktop
background = defines.get("background")   # noqa: F821  1x+2x TIFF

window_rect = ((240, 160), (660, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 112
text_size = 13
arrange_by = None
icon_locations = {
    appname: (180, 215),
    "Applications": (480, 215),
}
