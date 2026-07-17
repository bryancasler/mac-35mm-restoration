import os, vapoursynth as vs
core = vs.core
clip = core.bs.VideoSource(os.path.join(os.path.dirname(os.path.abspath(__file__)), "clip60.mkv"))
clip.set_output()
