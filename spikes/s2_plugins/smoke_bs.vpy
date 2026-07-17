import vapoursynth as vs
core = vs.core
clip = core.bs.VideoSource(r"/Users/4Site/Desktop/The Brave Little Toaster Raw 35mm Scan [Encode].mkv")
clip = clip[14000:14240]
clip.set_output()
