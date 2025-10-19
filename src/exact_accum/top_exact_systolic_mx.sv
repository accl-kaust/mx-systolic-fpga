module systolic_array_MX #(
    parameter exp_width = 4,
    parameter man_width = 3,
    parameter bit_width = 1 + exp_width + man_width,
    parameter k = 32,
    parameter fi_width = man_width + 2,
    parameter prd_width = 2 * ((1 << exp_width) + man_width),
    parameter out_width = prd_width + $clog2(k),
    parameter N = 32
)(
    input  logic clk,
    input  logic rst,
    // Data and valid signals for each PE input
    input  logic [bit_width-1:0] data_in_west [N],
    input  logic [bit_width-1:0] data_in_north [N],
    input  logic data_valid_west [N],  // Per-input valid signals
    input  logic data_valid_north [N],
    input  logic [7:0] shared_scale_west [N],
    input  logic [7:0] shared_scale_north [N],
    // Results and valid signals
    output logic [15:0] bf16_result [N*N],
    output logic result_valid_out
);
    // Internal PE array connections
    logic [bit_width-1:0] pe_data_right [N][N];
    logic [bit_width-1:0] pe_data_bottom [N][N];
    logic [out_width-1:0] pe_acc [N][N];
    logic pe_valid_right [N][N];  // Valid signals for right propagation
    logic pe_valid_bottom [N][N]; // Valid signals for bottom propagation
    logic [out_width-1:0] result [N*N];
    // PE array generation
    genvar i, j;
    generate
        for (i = 0; i < N; i++) begin : row
            for (j = 0; j < N; j++) begin : col
                mxfp8_mac_pe #(
                    .exp_width(exp_width),
                    .man_width(man_width),
                    .k(k)
                ) pe (
                    .clk(clk),
                    .rst(rst),
                    // Data inputs with valid signals
                    .data_in_left((j == 0) ? data_in_west[i] : pe_data_right[i][j-1]),
                    .data_in_top((i == 0) ? data_in_north[j] : pe_data_bottom[i-1][j]),
                    .valid_in_left((j == 0) ? data_valid_west[i] : pe_valid_right[i][j-1]),
                    .valid_in_top((i == 0) ? data_valid_north[j] : pe_valid_bottom[i-1][j]),
                    // Data and valid outputs
                    .data_out_right(pe_data_right[i][j]),
                    .data_out_bottom(pe_data_bottom[i][j]),
                    .valid_out_right(pe_valid_right[i][j]),
                    .valid_out_bottom(pe_valid_bottom[i][j]),
                    .acc_out(pe_acc[i][j])
                );

                // BFloat16 conversion
                conv_fixed2bf16_adjusted #(
                    .exp_width(exp_width),
                    .man_width(man_width)
                ) bf16_conv (
                    .i_fi_num(pe_acc[i][j]),
                    .shared_scale_1(shared_scale_north[j]),
                    .shared_scale_2(shared_scale_west[i]),
                    .o_bf16(bf16_result[i*N + j])
                );

                // Assign output results
                assign result[i*N + j] = pe_acc[i][j];
            end
        end
    endgenerate

    // Overall result valid signal
    // Now checks valid signals from both directions for all corner PEs
    assign result_valid_out = &{pe_valid_right[N-1][N-1], pe_valid_bottom[N-1][N-1]};

endmodule
