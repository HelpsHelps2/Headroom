# dmgbuild settings for the Headroom installer window. Used by scripts/release.sh.
# Icon centers must match the rings drawn in background.html.
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)

files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
background = defines["background"]  # noqa: F821 (dmgbuild also picks up background@2x.png)

format = "UDZO"
filesystem = "HFS+"
window_rect = ((200, 160), (640, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
label_pos = "bottom"
arrange_by = None
icon_locations = {
    os.path.basename(app): (170, 176),
    "Applications": (470, 176),
}
