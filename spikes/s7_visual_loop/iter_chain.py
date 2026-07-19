# Chain under iteration — ITER 1:
#  - fill-agreement gate added inside maskclean (motion-regression fix)
#  - DeScratch bright-only goes aggressive: minlen 60->20, maxgap 8->12
#    (bright mode can't touch dark ink, so caution costs nothing)
#  - ML scratch masks fused (spatial inpaint = the fix for static-scene
#    gouges, which are temporally invisible), dark line art protected
import vapoursynth as vs
from deflicker import deflicker
from maskclean import maskclean

core = vs.core


def chain(clip, ml_path=None):
    clip = deflicker(clip, size=10, mode="pm")
    clip = core.descratch.DeScratch(clip, mindif=5, asym=10, maxgap=12, maxwidth=5,
                                    minlen=20, maxangle=5.0, modey=2)
    ml = None
    if ml_path:
        ml = core.std.ShufflePlanes(core.bs.VideoSource(ml_path), planes=0,
                                    colorfamily=vs.GRAY)
    clip = maskclean(clip, t1=24, polarity="both", max_size=600,
                     ml_mask=ml, ml_protect_dark=True)
    return clip
