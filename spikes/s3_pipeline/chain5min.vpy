import sys, vapoursynth as vs
sys.path.insert(0, "/Users/4Site/Documents/GitHub/mac-35mm-restoration/spikes/s1_deflicker")
from deflicker import deflicker
core = vs.core
clip = core.bs.VideoSource(r"/Users/4Site/Desktop/The Brave Little Toaster Raw 35mm Scan [Encode].mkv")
clip = clip[14000:21200]
clip = deflicker(clip, size=10, mode="pm")
clip = core.descratch.DeScratch(clip, mindif=5, asym=10, maxgap=3, maxwidth=3, minlen=100, maxangle=3)
cleansed = core.zsmooth.Clense(clip)
sbegin = core.zsmooth.ForwardClense(clip)
send = core.zsmooth.BackwardClense(clip)
scsel = core.removedirt.SCSelect(clip, sbegin, send, cleansed)
alt = core.zsmooth.Repair(scsel, clip, mode=[16, 16, 1])
restore = core.zsmooth.Repair(cleansed, clip, mode=[16, 16, 1])
clip = core.removedirt.RestoreMotionBlocks(clip, restore, neighbour=scsel, alternative=alt,
                                           gmthreshold=80, dist=1, noise=10, noisy=12)
clip.set_output()
