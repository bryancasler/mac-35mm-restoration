import vapoursynth as vs
core = vs.core
for ns in ["mv", "removedirt", "tmedian", "zsmooth", "descratch", "bs"]:
    print(ns, "->", "OK" if getattr(core, ns, None) is not None else "MISSING", flush=True)
clip = core.std.BlankClip(width=64, height=64, format=vs.YUV420P8, length=10)
clip.set_output()
