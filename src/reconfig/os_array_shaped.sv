// os_array_shaped.sv -- shape-parameterized output-stationary MX array.
//
// A thin top that instantiates the EXISTING, UNMODIFIED arithmetic (mxfp8_mac_pe
// and conv_fixed2bf16_adjusted) in an R x C genvar grid. It reuses the wiring
// pattern of top_exact_systolic_mx.sv but decouples the row count (R, fed from
// the west) from the column count (C, fed from the north), so one physical PE
// pool P = R*C can be built in any logical shape at COMPILE time.
//
// Runtime reshaping (one fabric, switchbox) is M4; this is the compile-time
// per-shape array used for per-shape correctness (M2) and per-shape PPA later.
module os_array_shaped #(
    parameter exp_width = 4,
    parameter man_width = 3,
    parameter bit_width = 1 + exp_width + man_width,
    parameter k = 32,
    parameter R = 32,                 // logical rows  (west-fed)
    parameter C = 32,                 // logical cols  (north-fed)
    parameter P = 1024,               // physical PE pool (R*C must equal P)
    parameter prd_width = 2 * ((1 << exp_width) + man_width),
    parameter out_width = prd_width + $clog2(k)
)(
    input  logic clk,
    input  logic rst,
    input  logic [bit_width-1:0] data_in_west  [R],
    input  logic [bit_width-1:0] data_in_north [C],
    input  logic data_valid_west  [R],
    input  logic data_valid_north [C],
    input  logic [7:0] shared_scale_west  [R],
    input  logic [7:0] shared_scale_north [C],
    output logic [15:0] bf16_result [R*C],
    output logic result_valid_out
);
    // Elaboration check: the logical shape must fill the physical pool exactly.
    initial begin
        if (R * C != P)
            $fatal(1, "os_array_shaped: R*C (%0d*%0d=%0d) != P (%0d)",
                   R, C, R * C, P);
    end

    // Internal PE array connections
    logic [bit_width-1:0] pe_data_right  [R][C];
    logic [bit_width-1:0] pe_data_bottom [R][C];
    logic [out_width-1:0] pe_acc         [R][C];
    logic pe_valid_right  [R][C];
    logic pe_valid_bottom [R][C];

    genvar i, j;
    generate
        for (i = 0; i < R; i++) begin : row
            for (j = 0; j < C; j++) begin : col
                mxfp8_mac_pe #(
                    .exp_width(exp_width),
                    .man_width(man_width),
                    .k(k)
                ) pe (
                    .clk(clk),
                    .rst(rst),
                    .data_in_left ((j == 0) ? data_in_west[i]  : pe_data_right[i][j-1]),
                    .data_in_top  ((i == 0) ? data_in_north[j] : pe_data_bottom[i-1][j]),
                    .valid_in_left((j == 0) ? data_valid_west[i]  : pe_valid_right[i][j-1]),
                    .valid_in_top ((i == 0) ? data_valid_north[j] : pe_valid_bottom[i-1][j]),
                    .data_out_right (pe_data_right[i][j]),
                    .data_out_bottom(pe_data_bottom[i][j]),
                    .valid_out_right (pe_valid_right[i][j]),
                    .valid_out_bottom(pe_valid_bottom[i][j]),
                    .acc_out(pe_acc[i][j])
                );

                conv_fixed2bf16_adjusted #(
                    .exp_width(exp_width),
                    .man_width(man_width)
                ) bf16_conv (
                    .i_fi_num(pe_acc[i][j]),
                    .shared_scale_1(shared_scale_north[j]),
                    .shared_scale_2(shared_scale_west[i]),
                    .o_bf16(bf16_result[i*C + j])
                );
            end
        end
    endgenerate

    // The bottom-right corner PE is the last to receive valid data.
    assign result_valid_out = &{pe_valid_right[R-1][C-1], pe_valid_bottom[R-1][C-1]};

endmodule
