module fp8_multiplier #(
    parameter int exp_width = 4,
    parameter int man_width = 3,
    parameter int bit_width = 1 + exp_width + man_width,
    parameter int BIAS = 2**(exp_width-1) - 1,
    localparam int DOUBLE_MAN_WIDTH = 2 * man_width,
    localparam int BF16_EXP_BIAS = 127 - (2**exp_width - 1)
) (
    input  logic                    enable,
    input  logic [bit_width-1:0]    data_in_left,
    input  logic [bit_width-1:0]    data_in_top,
    output logic signed [15:0]      product
);
    typedef struct packed {
        logic                    sign;
        logic [exp_width-1:0]    exp;
        logic [man_width-1:0]    man;
    } fp8_fields_t;

    fp8_fields_t left, top;
    assign left = data_in_left;
    assign top = data_in_top;

    // Denormal detection
    logic left_denormal, top_denormal;
    assign left_denormal = (left.exp == '0) && (|left.man);
    assign top_denormal = (top.exp == '0) && (|top.man);

    // Extended mantissas with hidden bit handling
    logic [man_width:0] left_man_ext, top_man_ext;
    assign left_man_ext = left_denormal ? {1'b0, left.man} : {1'b1, left.man};
    assign top_man_ext = top_denormal ? {1'b0, top.man} : {1'b1, top.man};

    // Modified exponent handling for denormals
    logic signed [exp_width:0] left_unbiased_exp, top_unbiased_exp;
    assign left_unbiased_exp = left_denormal ? -BIAS + 1 : left.exp - BIAS;
    assign top_unbiased_exp = top_denormal ? -BIAS + 1 : top.exp - BIAS;

    // Sign and multiplication
    logic product_sign;
    logic [7:0] product_exp;
    logic [DOUBLE_MAN_WIDTH+1:0] product_man_full;
    logic [6:0] product_man_normalized;

    assign product_man_full = left_man_ext * top_man_ext;
    assign normalization_shift = product_man_full[DOUBLE_MAN_WIDTH+1];

    // Zero detection
    logic result_zero;
    assign result_zero = (left.exp == '0 && left.man == '0) || 
                        (top.exp == '0 && top.man == '0);

    always_comb begin
        if (result_zero) begin
            product_sign = 0;
            product_man_normalized = '0;
            product_exp = '0;
        end else if (normalization_shift) begin
            product_sign = left.sign ^ top.sign;
            product_man_normalized = (man_width == 3) ? {product_man_full[DOUBLE_MAN_WIDTH:0]} : {product_man_full[DOUBLE_MAN_WIDTH:0], 2'b0};
            product_exp = left_unbiased_exp + top_unbiased_exp + BF16_EXP_BIAS + 8'd1;
        end else begin
            product_sign = left.sign ^ top.sign;
            product_man_normalized = (man_width == 3) ? {product_man_full[DOUBLE_MAN_WIDTH - 1:0], 1'b0} : {product_man_full[DOUBLE_MAN_WIDTH - 1:0], 3'b0} ;
            product_exp = left_unbiased_exp + top_unbiased_exp + BF16_EXP_BIAS;
        end
    end

    assign product = enable ? {product_sign, product_exp, product_man_normalized} : '0;
endmodule
