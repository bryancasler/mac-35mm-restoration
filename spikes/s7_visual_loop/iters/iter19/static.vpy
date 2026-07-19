import sys
sys.path.insert(0, r"/Users/4Site/Documents/GitHub/mac-35mm-restoration/FilmRestore/Sources/FilmRestore/Resources/scripts")
sys.path.insert(0, r"/Users/4Site/Library/Application Support/FilmRestore/pysite")
import vapoursynth as vs
core = vs.core
from iter_chain import chain
clip = core.bs.VideoSource(r"/Users/4Site/Desktop/The Brave Little Toaster Raw 35mm Scan [Encode].mkv")
before = clip[50000:50000+36]
after = chain(before, ml_path=r"/Users/4Site/Documents/GitHub/mac-35mm-restoration/spikes/s7_visual_loop/mlmasks/static.mkv")
pair = core.std.StackHorizontal([before, after])
pair = pair[18]  # mid frame only
pair.set_output()
