import sys, importlib.util
sys.argv = ["haus.py", "--nur-haus"]
spec = importlib.util.spec_from_file_location("haus", "/tmp/claude-0/-home-user-GoUpBrainrot/9096847a-4aab-564d-aca4-6311e8b4f1c2/scratchpad/haus.py")
H = importlib.util.module_from_spec(spec); spec.loader.exec_module(H)
OUT = "/home/user/GoUpBrainrot/designs/tuerschild-haus"
INSET = 0.6
for tag, fn in (("A_schornstein", H.house_A), ("B_dachueberstand", H.house_B), ("C_tuer", H.house_C),
                ("D_herz", H.house_D), ("E_doppelhaus", H.house_E), ("F_rauchherz", H.house_F)):
    h, _ = fn()
    g = h.buffer(-INSET, quad_segs=16)
    W, Hh = H.PW + 2 * H.m, H.RING + 2 * H.m
    s = ['<?xml version="1.0" encoding="UTF-8"?>',
         f'<svg xmlns="http://www.w3.org/2000/svg" width="{W:.1f}mm" height="{Hh:.1f}mm" viewBox="0 0 {W:.3f} {Hh:.3f}">',
         f'  <!-- BLAU = Klebehilfe als Liniengravur, {INSET} mm nach innen versetzt (verschwindet unter dem Haus). GRAU = Plattenkontur nur zum Ausrichten, nicht lasern. -->',
         f'  <path fill="none" stroke="#999999" stroke-width="0.1" d="{H.plate}"/>',
         '  <g fill="none" stroke="#0000FF" stroke-width="0.1">' + "".join(f'<path d="{d}"/>' for d in H.paths(g)) + "</g>", "</svg>"]
    open(f"{OUT}/klebehilfe_{tag}_liniengravur.svg", "w").write("\n".join(s))
print("ok")
