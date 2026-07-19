# Scratch-detection UNet — vendored from Microsoft "Bringing Old Photos Back
# to Life" (CVPR 2020), https://github.com/microsoft/Bringing-Old-Photos-Back-to-Life
#
#   Copyright (c) Microsoft Corporation.
#   Licensed under the MIT License.
#
# Adapted for FilmRestore (GPL-3.0 app; this file remains MIT):
#   - Global/detection_models/networks.py  -> UNet, UNetConvBlock, UNetUpBlock
#   - Global/detection_models/antialiasing.py -> Downsample (adobe/antialiased-cnns)
#   - sync_bn / DataParallelWithCallback stripped. In the reference code
#     `sync_bn=True` merely reassigned the local `self` inside __init__ — a
#     no-op on the constructed module — so the shipped checkpoint was trained
#     and saved against plain nn.BatchNorm2d keys. Plain BatchNorm is used here.
#   - Only what inference needs; no torchvision/PIL/repo dependency.
#
# The pretrained checkpoint (FT_Epoch_latest.pt) is a dict whose "model_state"
# entry load_state_dict()s into this UNet with strict=True:
#   UNet(in_channels=1, out_channels=1, depth=4, conv_num=2, wf=6, padding=True,
#        batch_norm=True, up_mode="upsample", with_tanh=False, antialiasing=True)

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F


class Downsample(nn.Module):
    """Anti-aliased downsampling (blur + stride), from adobe/antialiased-cnns."""

    def __init__(self, pad_type="reflect", filt_size=3, stride=2, channels=None, pad_off=0):
        super().__init__()
        self.filt_size = filt_size
        self.pad_off = pad_off
        self.pad_sizes = [
            int(1.0 * (filt_size - 1) / 2),
            int(np.ceil(1.0 * (filt_size - 1) / 2)),
            int(1.0 * (filt_size - 1) / 2),
            int(np.ceil(1.0 * (filt_size - 1) / 2)),
        ]
        self.pad_sizes = [pad_size + pad_off for pad_size in self.pad_sizes]
        self.stride = stride
        self.off = int((self.stride - 1) / 2.0)
        self.channels = channels

        a = {
            1: [1.0],
            2: [1.0, 1.0],
            3: [1.0, 2.0, 1.0],
            4: [1.0, 3.0, 3.0, 1.0],
            5: [1.0, 4.0, 6.0, 4.0, 1.0],
            6: [1.0, 5.0, 10.0, 10.0, 5.0, 1.0],
            7: [1.0, 6.0, 15.0, 20.0, 15.0, 6.0, 1.0],
        }[filt_size]
        a = np.array(a)

        filt = torch.Tensor(a[:, None] * a[None, :])
        filt = filt / torch.sum(filt)
        self.register_buffer("filt", filt[None, None, :, :].repeat((self.channels, 1, 1, 1)))

        self.pad = get_pad_layer(pad_type)(self.pad_sizes)

    def forward(self, inp):
        if self.filt_size == 1:
            if self.pad_off == 0:
                return inp[:, :, :: self.stride, :: self.stride]
            return self.pad(inp)[:, :, :: self.stride, :: self.stride]
        return F.conv2d(self.pad(inp), self.filt, stride=self.stride, groups=inp.shape[1])


def get_pad_layer(pad_type):
    if pad_type in ["refl", "reflect"]:
        return nn.ReflectionPad2d
    if pad_type in ["repl", "replicate"]:
        return nn.ReplicationPad2d
    if pad_type == "zero":
        return nn.ZeroPad2d
    raise ValueError("Pad type [%s] not recognized" % pad_type)


class UNet(nn.Module):
    def __init__(
        self,
        in_channels=3,
        out_channels=3,
        depth=5,
        conv_num=2,
        wf=6,
        padding=True,
        batch_norm=True,
        up_mode="upsample",
        with_tanh=False,
        antialiasing=True,
    ):
        super().__init__()
        assert up_mode in ("upconv", "upsample")
        self.padding = padding
        self.depth = depth - 1
        prev_channels = in_channels

        self.first = nn.Sequential(
            *[nn.ReflectionPad2d(3), nn.Conv2d(in_channels, 2 ** wf, kernel_size=7), nn.LeakyReLU(0.2, True)]
        )
        prev_channels = 2 ** wf

        self.down_path = nn.ModuleList()
        self.down_sample = nn.ModuleList()
        for i in range(depth):
            if antialiasing and depth > 0:
                self.down_sample.append(
                    nn.Sequential(
                        *[
                            nn.ReflectionPad2d(1),
                            nn.Conv2d(prev_channels, prev_channels, kernel_size=3, stride=1, padding=0),
                            nn.BatchNorm2d(prev_channels),
                            nn.LeakyReLU(0.2, True),
                            Downsample(channels=prev_channels, stride=2),
                        ]
                    )
                )
            else:
                self.down_sample.append(
                    nn.Sequential(
                        *[
                            nn.ReflectionPad2d(1),
                            nn.Conv2d(prev_channels, prev_channels, kernel_size=4, stride=2, padding=0),
                            nn.BatchNorm2d(prev_channels),
                            nn.LeakyReLU(0.2, True),
                        ]
                    )
                )
            self.down_path.append(
                UNetConvBlock(conv_num, prev_channels, 2 ** (wf + i + 1), padding, batch_norm)
            )
            prev_channels = 2 ** (wf + i + 1)

        self.up_path = nn.ModuleList()
        for i in reversed(range(depth)):
            self.up_path.append(
                UNetUpBlock(conv_num, prev_channels, 2 ** (wf + i), up_mode, padding, batch_norm)
            )
            prev_channels = 2 ** (wf + i)

        if with_tanh:
            self.last = nn.Sequential(
                *[nn.ReflectionPad2d(1), nn.Conv2d(prev_channels, out_channels, kernel_size=3), nn.Tanh()]
            )
        else:
            self.last = nn.Sequential(
                *[nn.ReflectionPad2d(1), nn.Conv2d(prev_channels, out_channels, kernel_size=3)]
            )

    def forward(self, x):
        x = self.first(x)

        blocks = []
        for i, down_block in enumerate(self.down_path):
            blocks.append(x)
            x = self.down_sample[i](x)
            x = down_block(x)

        for i, up in enumerate(self.up_path):
            x = up(x, blocks[-i - 1])

        return self.last(x)


class UNetConvBlock(nn.Module):
    def __init__(self, conv_num, in_size, out_size, padding, batch_norm):
        super().__init__()
        block = []

        for _ in range(conv_num):
            block.append(nn.ReflectionPad2d(padding=int(padding)))
            block.append(nn.Conv2d(in_size, out_size, kernel_size=3, padding=0))
            if batch_norm:
                block.append(nn.BatchNorm2d(out_size))
            block.append(nn.LeakyReLU(0.2, True))
            in_size = out_size

        self.block = nn.Sequential(*block)

    def forward(self, x):
        return self.block(x)


class UNetUpBlock(nn.Module):
    def __init__(self, conv_num, in_size, out_size, up_mode, padding, batch_norm):
        super().__init__()
        if up_mode == "upconv":
            self.up = nn.ConvTranspose2d(in_size, out_size, kernel_size=2, stride=2)
        elif up_mode == "upsample":
            self.up = nn.Sequential(
                nn.Upsample(mode="bilinear", scale_factor=2, align_corners=False),
                nn.ReflectionPad2d(1),
                nn.Conv2d(in_size, out_size, kernel_size=3, padding=0),
            )

        self.conv_block = UNetConvBlock(conv_num, in_size, out_size, padding, batch_norm)

    @staticmethod
    def center_crop(layer, target_size):
        _, _, layer_height, layer_width = layer.size()
        diff_y = (layer_height - target_size[0]) // 2
        diff_x = (layer_width - target_size[1]) // 2
        return layer[:, :, diff_y : (diff_y + target_size[0]), diff_x : (diff_x + target_size[1])]

    def forward(self, x, bridge):
        up = self.up(x)
        crop1 = self.center_crop(bridge, up.shape[2:])
        out = torch.cat([up, crop1], 1)
        return self.conv_block(out)


def load_scratch_detector(weights_path, device="cpu"):
    """Build the BOPBTL scratch-detection UNet and load FT_Epoch_latest.pt.

    Handles the checkpoint's actual layout ({"model_state": state_dict, ...}),
    a bare state_dict, a DataParallel-saved dict ("module." prefixes), or a
    full pickled module. state_dict loading is strict=True.
    """
    model = UNet(
        in_channels=1,
        out_channels=1,
        depth=4,
        conv_num=2,
        wf=6,
        padding=True,
        batch_norm=True,
        up_mode="upsample",
        with_tanh=False,
        antialiasing=True,
    )

    try:
        ckpt = torch.load(weights_path, map_location="cpu", weights_only=True)
    except Exception:
        # Checkpoint contains non-tensor pickled objects (e.g. a full module).
        # The file is sha256-pinned in models/manifest.sha256, so this is safe.
        ckpt = torch.load(weights_path, map_location="cpu", weights_only=False)

    if isinstance(ckpt, nn.Module):
        state = ckpt.state_dict()
    elif isinstance(ckpt, dict) and "model_state" in ckpt:
        state = ckpt["model_state"]
    elif isinstance(ckpt, dict) and "state_dict" in ckpt:
        state = ckpt["state_dict"]
    else:
        state = ckpt

    state = {(k[7:] if k.startswith("module.") else k): v for k, v in state.items()}
    model.load_state_dict(state, strict=True)
    model.eval()
    return model.to(device)
