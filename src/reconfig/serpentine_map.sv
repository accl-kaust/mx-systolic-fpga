// serpentine_map.sv -- M4 runtime-reconfigurable serpentine OS fabric.
//
// A FIXED 32x32 physical PE grid that folds into a logical R x C array at
// runtime via `shape_sel`.  f = 1<<shape_sel in {1,2,4,8} is the number of
// physical rows per logical row (boustrophedon snake), so R = 32/f and C = 32*f
// give the four P=1024 shapes (32x32, 16x64, 8x128, 4x256).
//
// Per physical PE (pr,pc) a small SWITCHBOX selects, at runtime (muxed by f):
//   * A-operand source (logical west c-1): physical west/east neighbour, a snake
//     "turn" from the PE above, or the west boundary.
//   * B-operand source (logical north r-1): the PE f physical rows up (stride-f
//     vertical wire), or the north boundary.
// The mapping/switchbox formulas are proven in tools/serpentine_ref.py.
//
// The unmodified mxfp8_mac_pe and conv_fixed2bf16_adjusted are instantiated as-is.
// Output distribution converts each physical accumulator with the correct LOGICAL
// row/col scales and writes it to bf16_result in logical row-major order.
module serpentine_map #(
    parameter exp_width = 4,
    parameter man_width = 3,
    parameter bit_width = 1 + exp_width + man_width,
    parameter k = 32,
    parameter PR = 32,                 // physical rows
    parameter PC = 32,                 // physical cols
    parameter FMAX = 8,                // max f (rows used by north boundary)
    parameter prd_width = 2 * ((1 << exp_width) + man_width),
    parameter out_width = prd_width + $clog2(k)
)(
    input  logic clk,
    input  logic rst,
    input  logic [1:0] shape_sel,
    // boundary injection (driven by the boundary buffers / sequencer)
    input  logic [bit_width-1:0] west_inj  [PR],        // west operand per phys row (pc=0)
    input  logic                 west_inj_v[PR],
    input  logic [bit_width-1:0] north_inj [FMAX][PC],  // north operand, phys rows 0..f-1
    input  logic                 north_inj_v[FMAX][PC],
    // per-logical scales (static during a GEMM)
    input  logic [7:0] scale_west_log  [PR],            // up to 32 logical rows
    input  logic [7:0] scale_north_log [PR*PC],         // up to 256 logical cols
    // logical-ordered results
    output logic [15:0] bf16_result [PR*PC],
    output logic result_valid_out
);
    localparam BW = bit_width;

    logic [4:0] f;
    assign f = 5'd1 << shape_sel;      // 1,2,4,8

    // PE output wires
    logic [BW-1:0] right_out  [PR][PC];   // data_out_right (A eastbound, registered)
    logic [BW-1:0] bottom_out [PR][PC];   // data_out_bottom (B southbound, registered)
    logic          vright_out [PR][PC];
    logic          vbottom_out[PR][PC];
    logic [out_width-1:0] acc [PR][PC];
    logic [15:0]   phys_word  [PR][PC];   // per-PE converted output

    genvar pr, pc, s;
    generate
        for (pr = 0; pr < PR; pr++) begin : grow
            for (pc = 0; pc < PC; pc++) begin : gcol
                // ---- per-PE logical coordinate (runtime in f) ----
                logic [4:0] a_idx, b_idx, r_idx;
                logic       even;
                logic [8:0] c_idx;
                assign a_idx = pr[4:0] & (f - 1);          // pr % f
                assign even  = ~a_idx[0];
                assign b_idx = even ? pc[4:0] : (5'd31 - pc[4:0]);
                assign r_idx = pr >> shape_sel;            // pr / f
                assign c_idx = ({4'b0, a_idx} << 5) | {4'b0, b_idx};

                // ---- A-operand neighbour candidates (generate-guarded) ----
                logic [BW-1:0] west_nb_d, east_nb_d, turn_d;
                logic          west_nb_v, east_nb_v, turn_v;
                if (pc > 0)    begin assign west_nb_d = right_out[pr][pc-1]; assign west_nb_v = vright_out[pr][pc-1]; end
                else           begin assign west_nb_d = '0;                  assign west_nb_v = 1'b0;                end
                if (pc < PC-1) begin assign east_nb_d = right_out[pr][pc+1]; assign east_nb_v = vright_out[pr][pc+1]; end
                else           begin assign east_nb_d = '0;                  assign east_nb_v = 1'b0;                end
                if (pr > 0)    begin assign turn_d = right_out[pr-1][pc]; assign turn_v = vright_out[pr-1][pc]; end
                else           begin assign turn_d = '0;                  assign turn_v = 1'b0;                end

                // ---- A-input switchbox (logical west = c-1) ----
                logic [BW-1:0] a_in_d;  logic a_in_v;
                always_comb begin
                    if (even) begin
                        if (pc != 0)         begin a_in_d = west_nb_d;    a_in_v = west_nb_v;    end
                        else if (a_idx == 0) begin a_in_d = west_inj[pr]; a_in_v = west_inj_v[pr]; end
                        else                 begin a_in_d = turn_d;       a_in_v = turn_v;       end
                    end else begin
                        if (pc != PC-1)      begin a_in_d = east_nb_d;    a_in_v = east_nb_v;    end
                        else                 begin a_in_d = turn_d;       a_in_v = turn_v;       end
                    end
                end

                // ---- B-operand vertical candidates: bottom_out[pr - (1<<s)] ----
                logic [BW-1:0] vup_d [4];  logic vup_v [4];
                for (s = 0; s < 4; s++) begin : gvup
                    if (pr >= (1 << s)) begin
                        assign vup_d[s] = bottom_out[pr-(1<<s)][pc];
                        assign vup_v[s] = vbottom_out[pr-(1<<s)][pc];
                    end else begin
                        assign vup_d[s] = '0; assign vup_v[s] = 1'b0;
                    end
                end

                // ---- B-input switchbox (logical north = r-1) ----
                logic [BW-1:0] b_in_d;  logic b_in_v;
                if (pr < FMAX) begin : gb_top
                    always_comb begin
                        if (pr >= f) begin b_in_d = vup_d[shape_sel];   b_in_v = vup_v[shape_sel];   end
                        else         begin b_in_d = north_inj[pr][pc];  b_in_v = north_inj_v[pr][pc]; end
                    end
                end else begin : gb_int
                    // pr >= FMAX >= f always -> always interior (vertical) source
                    always_comb begin b_in_d = vup_d[shape_sel]; b_in_v = vup_v[shape_sel]; end
                end

                // ---- the (unmodified) PE ----
                mxfp8_mac_pe #(.exp_width(exp_width), .man_width(man_width), .k(k)) pe (
                    .clk(clk), .rst(rst),
                    .data_in_left(a_in_d), .data_in_top(b_in_d),
                    .valid_in_left(a_in_v), .valid_in_top(b_in_v),
                    .data_out_right(right_out[pr][pc]),
                    .data_out_bottom(bottom_out[pr][pc]),
                    .valid_out_right(vright_out[pr][pc]),
                    .valid_out_bottom(vbottom_out[pr][pc]),
                    .acc_out(acc[pr][pc])
                );

                // ---- output distribution: conv with LOGICAL scales ----
                conv_fixed2bf16_adjusted #(.exp_width(exp_width), .man_width(man_width)) cv (
                    .i_fi_num(acc[pr][pc]),
                    .shared_scale_1(scale_north_log[c_idx]),
                    .shared_scale_2(scale_west_log[r_idx]),
                    .o_bf16(phys_word[pr][pc])
                );
            end
        end
    endgenerate

    // physical -> logical result placement: bf16_result[r*C + c]
    always_comb begin
        for (int i = 0; i < PR*PC; i++) bf16_result[i] = '0;
        for (int ppr = 0; ppr < PR; ppr++) begin
            for (int ppc = 0; ppc < PC; ppc++) begin
                automatic int ff = f;
                automatic int aa = ppr % ff;
                automatic int rr = ppr / ff;
                automatic int bb = (aa % 2 == 0) ? ppc : (31 - ppc);
                automatic int cc = aa * 32 + bb;
                automatic int Cw = 32 * ff;
                bf16_result[rr*Cw + cc] = phys_word[ppr][ppc];
            end
        end
    end

    // logical corner (R-1, C-1) -> physical, report its valid
    logic [4:0] corner_pr, corner_pc;
    always_comb begin
        automatic int ff = f;
        automatic int R = 32 / ff;
        automatic int C = 32 * ff;
        automatic int a = (C-1) / 32;
        automatic int b = (C-1) % 32;
        corner_pr = (R-1)*ff + a;
        corner_pc = (a % 2 == 0) ? b : (31 - b);
    end
    assign result_valid_out = vright_out[corner_pr][corner_pc] &
                              vbottom_out[corner_pr][corner_pc];

endmodule
