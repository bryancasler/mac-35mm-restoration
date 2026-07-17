# S2 benchmark: vspipe -p --arg stage=<bs|descratch|removedirt|spotless> bench.vpy .
# 60 s window (1439 frames @ 23.976) of the real 35mm scan.
import vapoursynth as vs
core = vs.core

SRC = r"/Users/4Site/Desktop/The Brave Little Toaster Raw 35mm Scan [Encode].mkv"
START, LEN = 14000, 1440

stage = globals().get("stage", "bs")

clip = core.bs.VideoSource(SRC)
clip = clip[START:START + LEN]


def descratch(c):
    # defaults from the DeScratch doc; vertical scratches on Y only
    return core.descratch.DeScratch(c, mindif=5, asym=10, maxgap=3, maxwidth=3,
                                    minlen=100, maxangle=3)


def removedirt(c, repmode=16):
    # classic RemoveDirt composition (Clense/Repair via zsmooth, no rgvs needed)
    cleansed = core.zsmooth.Clense(c)
    sbegin = core.zsmooth.ForwardClense(c)
    send = core.zsmooth.BackwardClense(c)
    scsel = core.removedirt.SCSelect(c, sbegin, send, cleansed)
    alt = core.zsmooth.Repair(scsel, c, mode=[repmode, repmode, 1])
    restore = core.zsmooth.Repair(cleansed, c, mode=[repmode, repmode, 1])
    return core.removedirt.RestoreMotionBlocks(c, restore, neighbour=scsel,
                                               alternative=alt, gmthreshold=80,
                                               dist=1, noise=10, noisy=12)


def spotless(c, radT=1, thsad=10000, pel=2, blksize=8):
    # Didée's SpotLess via MVTools compensate + temporal median (zsmooth)
    sup = core.mv.Super(c, pel=pel)
    bv = core.mv.Analyse(sup, isb=True, delta=1, blksize=blksize, overlap=blksize // 2)
    fv = core.mv.Analyse(sup, isb=False, delta=1, blksize=blksize, overlap=blksize // 2)
    bc = core.mv.Compensate(c, sup, bv, thsad=thsad)
    fc = core.mv.Compensate(c, sup, fv, thsad=thsad)
    ilv = core.std.Interleave([fc, c, bc])
    med = core.zsmooth.TemporalMedian(ilv, radius=1)
    return med.std.SelectEvery(cycle=3, offsets=1)


if stage == "descratch":
    clip = descratch(clip)
elif stage == "removedirt":
    clip = removedirt(clip)
elif stage == "spotless":
    clip = spotless(clip)
elif stage == "full":
    clip = removedirt(descratch(clip))

clip.set_output()
