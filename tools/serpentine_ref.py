#!/usr/bin/env python3
"""serpentine_ref.py -- reference for the M4 runtime serpentine fold.

A fixed 32x32 PHYSICAL PE grid is folded into a logical R x C array, where
f = C/32 physical rows make up one logical row (boustrophedon snake), so
R = 32/f. shape_sel picks f in {1,2,4,8} -> (R,C) in {(32,32),(16,64),(8,128),
(4,256)}.

This module derives, for each physical PE (pr,pc) and a given f:
  * its logical coordinate (r,c)
  * its A-operand source (logical west neighbor c-1): one of
      WEST_NB (pr,pc-1) | EAST_NB (pr,pc+1) | TURN (pr-1,pc) | WBND[r]
  * its B-operand source (logical north neighbor r-1): one of
      VUP (pr-f,pc) | NBND[c]
It then PROVES the switchbox is correct: the mapping is a bijection, and the
A/B source links exactly reconstruct the logical R x C systolic connectivity.

The RTL switchbox (src/reconfig/serpentine_map.sv) implements these same
formulas, muxed at runtime by f.
"""

PR = 32          # physical rows
PC = 32          # physical cols
P = PR * PC

# A-source / B-source tags (mirror the RTL localparams)
A_WEST_NB = 0    # data_in_left <- (pr, pc-1).data_out_right
A_EAST_NB = 1    # data_in_left <- (pr, pc+1).data_out_right
A_TURN    = 2    # data_in_left <- (pr-1, pc).data_out_right
A_WBND    = 3    # data_in_left <- west boundary[r]
B_VUP     = 0    # data_in_top  <- (pr-f, pc).data_out_bottom
B_NBND    = 1    # data_in_top  <- north boundary[c]


def f_of_shape_sel(sel):
    return 1 << sel          # sel 0..3 -> f 1,2,4,8


def shape_of_f(f):
    C = 32 * f
    R = 32 // f
    return R, C


def phys_to_logical(pr, pc, f):
    """physical (pr,pc) -> logical (r,c) under the serpentine fold."""
    r = pr // f
    a = pr % f
    b = pc if (a % 2 == 0) else (31 - pc)
    c = a * 32 + b
    return r, c


def logical_to_phys(r, c, f):
    a = c // 32
    b = c % 32
    pr = r * f + a
    pc = b if (a % 2 == 0) else (31 - b)
    return pr, pc


def a_source(pr, pc, f):
    """Switchbox A-input selection for physical PE (pr,pc)."""
    a = pr % f
    even = (a % 2 == 0)
    if even:
        if pc > 0:
            return (A_WEST_NB, (pr, pc - 1))
        else:                      # pc == 0
            if a == 0:
                r = pr // f
                return (A_WBND, r)
            else:
                return (A_TURN, (pr - 1, pc))
    else:                          # a odd
        if pc < 31:
            return (A_EAST_NB, (pr, pc + 1))
        else:                      # pc == 31
            return (A_TURN, (pr - 1, pc))


def b_source(pr, pc, f):
    """Switchbox B-input selection for physical PE (pr,pc)."""
    if pr >= f:
        return (B_VUP, (pr - f, pc))
    else:
        r, c = phys_to_logical(pr, pc, f)
        return (B_NBND, c)


def verify(f):
    R, C = shape_of_f(f)
    # 1) bijection physical <-> logical
    seen = {}
    for pr in range(PR):
        for pc in range(PC):
            r, c = phys_to_logical(pr, pc, f)
            assert 0 <= r < R and 0 <= c < C, (pr, pc, r, c, f)
            assert (r, c) not in seen, f"collision {(r,c)} f={f}"
            seen[(r, c)] = (pr, pc)
            assert logical_to_phys(r, c, f) == (pr, pc)
    assert len(seen) == R * C == P

    # 2) A-links reconstruct logical west adjacency (c-1 in same row r)
    for pr in range(PR):
        for pc in range(PC):
            r, c = phys_to_logical(pr, pc, f)
            tag, ref = a_source(pr, pc, f)
            if c == 0:
                assert tag == A_WBND and ref == r, (pr, pc, r, c, tag, ref)
            else:
                # ref must be the physical PE holding logical (r, c-1)
                assert tag in (A_WEST_NB, A_EAST_NB, A_TURN)
                rr, cc = phys_to_logical(ref[0], ref[1], f)
                assert (rr, cc) == (r, c - 1), \
                    f"A-link f={f} ({pr},{pc})->({r},{c}) src->({rr},{cc})"

    # 3) B-links reconstruct logical north adjacency (r-1 in same col c)
    for pr in range(PR):
        for pc in range(PC):
            r, c = phys_to_logical(pr, pc, f)
            tag, ref = b_source(pr, pc, f)
            if r == 0:
                assert tag == B_NBND and ref == c, (pr, pc, r, c, tag, ref)
            else:
                assert tag == B_VUP
                rr, cc = phys_to_logical(ref[0], ref[1], f)
                assert (rr, cc) == (r - 1, c), \
                    f"B-link f={f} ({pr},{pc})->({r},{c}) src->({rr},{cc})"

    # 4) injection-point inventory (for the boundary buffers)
    west_pts = sorted({logical_to_phys(r, 0, f) for r in range(R)})
    north_pts = sorted({logical_to_phys(0, c, f) for c in range(C)})
    assert len(west_pts) == R and len(north_pts) == C
    return R, C, west_pts, north_pts


if __name__ == "__main__":
    for sel in range(4):
        f = f_of_shape_sel(sel)
        R, C, wpts, npts = verify(f)
        print(f"shape_sel={sel} f={f}: logical {R}x{C}  bijection OK  "
              f"A/B connectivity OK  west_inj={R} north_inj={C}")
        # show the first few injection points as a sanity spot-check
        print(f"    west_inj rows (pc=0): {[p[0] for p in wpts][:8]}"
              f"{'...' if R > 8 else ''}")
    print("ALL serpentine mappings verified for f in {1,2,4,8}")
