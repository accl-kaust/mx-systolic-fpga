`timescale 1ns / 1ps

module conv_fixed2bf16_adjusted #(
    parameter exp_width = 5,
    parameter man_width = 2,
//    parameter bit_width = 1 + exp_width + man_width ,
    parameter k = 32,
    parameter prd_width = 2 * ((1<<exp_width) + man_width),
    parameter bit_width = prd_width + $clog2(k)
)(
    input  logic signed [bit_width-1:0] i_fi_num,
    input logic unsigned[7:0] shared_scale_1,
    input logic unsigned[7:0] shared_scale_2,
    output logic          [15:0] o_bf16
);
    logic          [7:0] in_bias;
    localparam exp_bias = 8'd127;
//    logic in_bias;
    assign in_bias = prd_width - 4 + (2 * (127 - (2**exp_width -1)) - shared_scale_1  - shared_scale_2);
    // Extract sign.
    logic bf16_sgn;
    logic [bit_width-1:0] u_fi_num;

    assign bf16_sgn = i_fi_num[bit_width-1];

    assign u_fi_num = bf16_sgn ? -i_fi_num : i_fi_num;

    // Count leading zeros, align input.
    logic [$clog2(bit_width+1)-1:0] lz_num;
    logic [bit_width-1:0] aligned_num;

    clz #(
        .width_i(bit_width)
    ) u_clz (
        .i_num(u_fi_num),
        .o_lz(lz_num)
    );

    assign aligned_num = u_fi_num << lz_num;

    // Round mantissa.
    logic R;
    logic S;
    logic rnd_bit;

    assign R =  aligned_num[bit_width-1 -8];
    assign S = |aligned_num[bit_width-1 -9:0];
    assign rnd_bit = R && (aligned_num[bit_width-1 -7] || S);

    logic [7:0] bf16_man_ofl;  // Extra bit to check for overflow after rounding.
    logic [6:0] bf16_man;      // Output mantissa if output is not denormal.
    logic            rnd_ofl;  // 1 if mantissa overflowed, 0 otherwise.

    assign bf16_man_ofl = aligned_num[bit_width-1 -1:bit_width-1 -7] + {6'h0, rnd_bit};

    assign rnd_ofl  = bf16_man_ofl[7];
    assign bf16_man = bf16_man_ofl[6:0];


    // Calculate exponent.
    logic [7:0] bf16_exp;

    assign bf16_exp = (i_fi_num == 0) ? 0 : (bit_width-1 - lz_num + rnd_ofl + exp_bias - in_bias);


    // Assign output.
    assign o_bf16 = {bf16_sgn, bf16_exp, bf16_man};

endmodule
