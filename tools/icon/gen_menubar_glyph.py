import math
exec(open("gen_app_icon.py").read().split("os.makedirs")[0].replace("X0, X1, CY, AMP, WAVES, RUNGS, STROKE = 232, 792, 512, 190, 2.5, 10, 36", "X0, X1, CY, AMP, WAVES, RUNGS, STROKE = 40, 600, 250, 200, 1.5, 4, 44"))
def segs_svg(want_front, opacity):
    out = ""
    for sign in (1, -1):
        for s in segments(sign, want_front):
            if len(s) > 1:
                out += f'<path d="M{" L".join(f"{x:.1f},{y:.1f}" for x, y in s)}" fill="none" stroke="#000" stroke-opacity="{opacity}" stroke-width="{STROKE}" stroke-linecap="round" stroke-linejoin="round"/>'
    return out
rungs = ""
for k in range(1, RUNGS):
    i = round(k * N / RUNGS); x, ya, _ = pt(i, 1); _, yb, _ = pt(i, -1)
    if abs(ya - yb) > 50:
        rungs += f'<line x1="{x:.1f}" y1="{ya:.1f}" x2="{x:.1f}" y2="{yb:.1f}" stroke="#000" stroke-opacity="0.7" stroke-width="20" stroke-linecap="round"/>'
body = segs_svg(False, 0.45) + rungs + segs_svg(True, 1)
open("helix-template.svg", "w").write(f'<svg xmlns="http://www.w3.org/2000/svg" width="640" height="460" viewBox="0 20 640 460">{body}</svg>')
