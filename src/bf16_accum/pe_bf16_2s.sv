module mxfp8_mac_pe #(
    parameter int exp_width = 4,
    parameter int man_width = 3,
    parameter int bit_width = 1 + exp_width + man_width,
    parameter int k = 32
) (
    input  logic                    clk,
    input  logic                    rst,
    // Data inputs
    input  logic [bit_width-1:0]    data_in_left,
    input  logic [bit_width-1:0]    data_in_top,
    // Valid signals
    input  logic                    valid_in_left,
    input  logic                    valid_in_top,
    // Data outputs
    output logic [bit_width-1:0]    data_out_right,
    output logic [bit_width-1:0]    data_out_bottom,
    // Valid outputs
    output logic                    valid_out_right,
    output logic                    valid_out_bottom,
    // Accumulator output
    output logic signed [15:0]      acc_reg
);
    // Stage 1 registers
    logic [bit_width-1:0] data_right_stage1, data_bottom_stage1;
    logic valid_right_stage1, valid_bottom_stage1;
    logic signed [15:0] product_stage1;
    logic signed [15:0] product;
//    logic valid_compute_stage1;

    // Stage 2 signals
    logic signed [15:0] adder_result;
    
    // Instantiate multiplier for Stage 1
    fp8_multiplier #(
        .exp_width(exp_width),
        .man_width(man_width)
    ) u_mul (
        .enable(valid_in_left && valid_in_top),
        .data_in_left(data_in_left),
        .data_in_top(data_in_top),
        .product(product)
    );

    // Stage 1: Multiplication and data forwarding
    always_ff @(posedge clk) begin
        if (rst) begin
            // Reset stage 1 registers
            product_stage1 <= '0;
            data_right_stage1 <= '0;
            data_bottom_stage1 <= '0;
            valid_right_stage1 <= '0;
            valid_bottom_stage1 <= '0;
//            valid_compute_stage1 <= '0;
        end else begin
            // Forward data and valid signals to stage 1
            data_right_stage1 <= data_in_left;
            data_bottom_stage1 <= data_in_top;
            valid_right_stage1 <= valid_in_left;
            valid_bottom_stage1 <= valid_in_top;
            product_stage1 <= product;
//            valid_compute_stage1 <= valid_in_left && valid_in_top;
        end
    end

    // Instantiate adder for Stage 2
    bfloat16_adder u_adder (
        .a(acc_reg),
        .b(product_stage1),
        .enable(valid_right_stage1 && valid_bottom_stage1),
        .sum(adder_result)
    );

    // Stage 2: Accumulation and final output
    always_ff @(posedge clk) begin
        if (rst) begin
            // Reset stage 2 registers
            acc_reg <= '0;
            data_out_right <= '0;
            data_out_bottom <= '0;
            valid_out_right <= '0;
            valid_out_bottom <= '0;
        end else begin
            // Forward data from stage 1 to outputs
            data_out_right <= data_right_stage1;
            data_out_bottom <= data_bottom_stage1;
            valid_out_right <= valid_right_stage1;
            valid_out_bottom <= valid_bottom_stage1;
            
            // Update accumulator when valid computation occurs
            if (valid_bottom_stage1 && valid_right_stage1) begin
                acc_reg <= adder_result;
            end else begin
                acc_reg <= '0;
            end
        end
    end

endmodule