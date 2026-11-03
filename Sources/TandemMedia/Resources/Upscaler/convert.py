# Makes Upscaler2x.mlpackage, the model behind UpscaleJob: Real-ESRGAN's
# realesr-animevideov3 (SRVGGNetCompact, x4, BSD-3-Clause, see
# LICENSE-Real-ESRGAN.txt) as Core ML, with a 2x2 average after it so it
# outputs 2x. Real-ESRGAN's own "x2" ncnn model is the same network with a
# half-size resize after it. Takes 512 px tiles and returns 1024 px ones,
# as images.
#
#   curl -LO https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesr-animevideov3.pth
#   uv run --with torch --with coremltools python convert.py realesr-animevideov3.pth 512 Upscaler2x.mlpackage
import sys, torch, numpy as np, coremltools as ct
from torch import nn
from torch.nn import functional as F

class Net(nn.Module):
    def __init__(s, num_feat=64, num_conv=16, upscale=4):
        super().__init__()
        s.body = nn.ModuleList([nn.Conv2d(3, num_feat, 3, 1, 1), nn.PReLU(num_feat)])
        for _ in range(num_conv):
            s.body += [nn.Conv2d(num_feat, num_feat, 3, 1, 1), nn.PReLU(num_feat)]
        s.body.append(nn.Conv2d(num_feat, 3 * upscale * upscale, 3, 1, 1))
        s.up = nn.PixelShuffle(upscale)
    def forward(s, x):
        out = x
        for m in s.body: out = m(out)
        out = s.up(out) + F.interpolate(x, scale_factor=4, mode='nearest')
        return F.avg_pool2d(out, 2).clamp(0, 1) * 255

weights, size, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
net = Net()
sd = torch.load(weights, map_location='cpu')
sd = sd.get('params', sd.get('params_ema', sd))
net.load_state_dict({k.replace('upsampler', 'up'): v for k, v in sd.items()})
net.eval()
ex = torch.rand(1, 3, size, size)
traced = torch.jit.trace(net, ex)
m = ct.convert(traced, inputs=[ct.ImageType(name='input', shape=ex.shape, scale=1/255, color_layout=ct.colorlayout.RGB)], outputs=[ct.ImageType(name='output', color_layout=ct.colorlayout.RGB)],
               convert_to='mlprogram', compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS15)
m.short_description = 'Real-ESRGAN realesr-animevideov3 (BSD-3-Clause, Xintao Wang et al.), x4 then a 2x2 average: 2x super-resolution.'
m.save(out)
print('saved', out)
