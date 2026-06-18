// serpentine_array.sv -- M4 top: boundary buffers + sequencer + controller
// wrapped around the runtime serpentine fabric (serpentine_map).
//
// Holds the operand memories (logical west rows / north cols), a SEQUENCER that
// streams them into the fabric injection ports with the logical systolic skew
// (west row r delayed by r, north col c delayed by c), and a small CONTROLLER
// (shape_sel + start) that clears the accumulators and runs a GEMM. The logical
// shape is selected at runtime; because the switchbox muxes are combinational in
// shape_sel, a new shape takes effect in one cycle (demonstrated by the TB).
module serpentine_array #(
    parameter exp_width = 4,
    parameter man_width = 3,
    parameter bit_width = 1 + exp_width + man_width,
    parameter k = 32,
    parameter PR = 32,
    parameter PC = 32,
    parameter FMAX = 8,
    parameter NCOL = 256                 // max logical columns
)(
    input  logic clk,
    input  logic rst,
    input  logic [1:0] shape_sel,
    input  logic start,
    // operand memories (logical): west rows 0..R-1, north cols 0..C-1
    input  logic [bit_width-1:0] west_mem  [PR][k],
    input  logic [7:0]           west_scale[PR],
    input  logic [bit_width-1:0] north_mem [NCOL][k],
    input  logic [7:0]           north_scale[NCOL],
    // outputs
    output logic [15:0] bf16_result [PR*PC],
    output logic result_valid_out,
    output logic busy,
    output logic done
);
    localparam BW = bit_width;

    // ---- controller state ----
    typedef enum logic [1:0] {S_IDLE, S_CLEAR, S_RUN, S_DONE} state_t;
    state_t state;
    logic [1:0]  sel_reg;                 // latched shape at start
    logic [4:0]  f_reg;
    logic [15:0] seq_cnt;                 // streaming cycle counter
    // Clear accumulators ONLY during the S_CLEAR cycle (and global reset). Must
    // be 0 in S_RUN (so accumulation happens) and in S_DONE (so the results
    // persist to be read). Combinational so the fabric is released exactly as
    // S_RUN starts streaming seq_cnt=0 (a registered reset would drop element 0).
    logic        fabric_rst;
    assign fabric_rst = rst | (state == S_CLEAR);

    wire  [15:0] R_log = 16'd32 >> sel_reg;
    wire  [15:0] C_log = 16'd32 << sel_reg;
    // Run until the deepest PE (logical corner) has drained its full K
    // accumulation: corner result is ready ~R+C+K cycles after streaming starts.
    wire  [15:0] end_cnt = R_log + C_log + k[15:0] + 16'd6;

    assign f_reg = 5'd1 << sel_reg;

    // ---- fabric injection buses ----
    logic [BW-1:0] west_inj  [PR];
    logic          west_inj_v[PR];
    logic [BW-1:0] north_inj [FMAX][PC];
    logic          north_inj_v[FMAX][PC];

    // scales straight through (static during a GEMM)
    logic [7:0] scale_west_log [PR];
    logic [7:0] scale_north_log[PR*PC];
    always_comb begin
        for (int r = 0; r < PR; r++) scale_west_log[r] = west_scale[r];
        for (int c = 0; c < PR*PC; c++)
            scale_north_log[c] = (c < NCOL) ? north_scale[c] : 8'd0;
    end

    // ---- sequencer: drive injection with logical skew ----
    // west row r -> physical (r*f, 0); north col c -> physical (a=c/32, snake(b)).
    always_comb begin
        for (int r = 0; r < PR; r++)   begin west_inj[r] = '0; west_inj_v[r] = 1'b0; end
        for (int a = 0; a < FMAX; a++)
            for (int p = 0; p < PC; p++) begin north_inj[a][p] = '0; north_inj_v[a][p] = 1'b0; end

        if (state == S_RUN) begin
            // west operands
            for (int r = 0; r < PR; r++) begin
                if (r < R_log && seq_cnt >= r[15:0] && seq_cnt < r[15:0] + k[15:0]) begin
                    automatic int t = seq_cnt - r;
                    west_inj  [r*f_reg] = west_mem[r][t];
                    west_inj_v[r*f_reg] = 1'b1;
                end
            end
            // north operands
            for (int c = 0; c < NCOL; c++) begin
                if (c < C_log && seq_cnt >= c[15:0] && seq_cnt < c[15:0] + k[15:0]) begin
                    automatic int a  = c / 32;
                    automatic int b  = c % 32;
                    automatic int pc = (a % 2 == 0) ? b : (31 - b);
                    automatic int t  = seq_cnt - c;
                    north_inj  [a][pc] = north_mem[c][t];
                    north_inj_v[a][pc] = 1'b1;
                end
            end
        end
    end

    // ---- controller FSM ----
    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; busy <= 1'b0; done <= 1'b0;
            seq_cnt <= '0; sel_reg <= 2'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0; busy <= 1'b0;
                    if (start) begin
                        sel_reg <= shape_sel;     // latch (1-cycle reconfigure)
                        state <= S_CLEAR; busy <= 1'b1;
                    end
                end
                S_CLEAR: begin                     // 1 cycle: clear accumulators
                    seq_cnt <= '0; state <= S_RUN;
                end
                S_RUN: begin
                    seq_cnt <= seq_cnt + 16'd1;
                    if (seq_cnt >= end_cnt) state <= S_DONE;
                end
                S_DONE: begin
                    busy <= 1'b0; done <= 1'b1;
                    if (start) begin
                        sel_reg <= shape_sel; done <= 1'b0;
                        state <= S_CLEAR; busy <= 1'b1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // ---- the reconfigurable fabric ----
    serpentine_map #(
        .exp_width(exp_width), .man_width(man_width), .k(k),
        .PR(PR), .PC(PC), .FMAX(FMAX)
    ) fabric (
        .clk(clk), .rst(fabric_rst), .shape_sel(sel_reg),
        .west_inj(west_inj), .west_inj_v(west_inj_v),
        .north_inj(north_inj), .north_inj_v(north_inj_v),
        .scale_west_log(scale_west_log), .scale_north_log(scale_north_log),
        .bf16_result(bf16_result), .result_valid_out(result_valid_out)
    );

endmodule
