import vapoursynth as vs
core = vs.core
clip = core.bs.VideoSource(r"/Users/4Site/Desktop/The Brave Little Toaster Raw 35mm Scan [Encode].mkv")
win = clip[14650:14659]
win = core.std.CropAbs(win, width=300, height=300, left=222, top=358)
win = core.resize.Point(win, width=600, height=600)
win.set_output()
