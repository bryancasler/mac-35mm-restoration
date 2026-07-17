# vspipe -c y4m --arg mode=pm --arg size=10 [--arg compat=1] run_deflicker.vpy -
import os
import sys

import vapoursynth as vs

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from deflicker import deflicker

core = vs.core

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), "clip60.mkv")

clip = core.bs.VideoSource(SRC)
clip = deflicker(clip,
                 size=int(globals().get("size", "10")),
                 mode=globals().get("mode", "pm"),
                 median_compat=bool(int(globals().get("compat", "0"))))
clip.set_output()
