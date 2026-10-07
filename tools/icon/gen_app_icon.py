import math, os, json, sys
W = 1024
def envelope(t): return 0.25 + 0.75 * (math.sin(math.pi * t) ** 1.2) * (0.75 + 0.25 * math.sin(t * 13.0))
X0, X1, CY, AMP, WAVES, RUNGS, STROKE = 232, 792, 512, 190, 2.5, 10, 36
GOLD, TEAL = "#F5C451", "#4FD8CA"
N = 600
def pt(i, sign):
    t = i / N; x = X0 + (X1 - X0) * t; a = AMP * envelope(t)
    ph = 2 * math.pi * WAVES * t
    return x, CY + sign * a * math.sin(ph), (math.cos(ph) * sign) >= 0
def segments(sign, want_front):
    segs, cur = [], []
    for i in range(N + 1):
        x, y, front = pt(i, sign)
        if front == want_front: cur.append((x, y))
        elif cur:
            cur.append((x, y)); segs.append(cur); cur = []
    if cur: segs.append(cur)
    return segs
def paths(segs, color, width):
    return "".join(f'<path d="M{" L".join(f"{x:.1f},{y:.1f}" for x, y in s)}" fill="none" stroke="{color}" stroke-width="{width}" stroke-linecap="round" stroke-linejoin="round"/>' for s in segs if len(s) > 1)
def svg(body): return f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">{body}</svg>'
os.makedirs(sys.argv[1] + "/Assets", exist_ok=True)
A = sys.argv[1] + "/Assets/"
back = paths(segments(1, False), GOLD, STROKE) + paths(segments(-1, False), TEAL, STROKE)
front = paths(segments(1, True), GOLD, STROKE) + paths(segments(-1, True), TEAL, STROKE)
rungs = ""
for k in range(RUNGS + 1):
    i = round(k * N / RUNGS); x, ya, _ = pt(i, 1); _, yb, _ = pt(i, -1)
    if abs(ya - yb) > 30:
        rungs += f'<line x1="{x:.1f}" y1="{ya:.1f}" x2="{x:.1f}" y2="{yb:.1f}" stroke="#FFFFFF" stroke-width="16" stroke-linecap="round"/>'
open(A + "back.svg", "w").write(svg(back)); open(A + "rungs.svg", "w").write(svg(rungs)); open(A + "front.svg", "w").write(svg(front))
