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
    // Internal signals
    logic signed [15:0] product;
    logic signed [15:0] adder_result;
    

    // Multiplier instance
    fp8_multiplier #(
        .exp_width(exp_width),
        .man_width(man_width)
    ) u_mul (
        .enable(valid_in_left),
        .data_in_left(data_in_left),
        .data_in_top(data_in_top),
        .product(product)
    );

    // Adder instance
    bfloat16_adder #() u_adder (
        .a(acc_reg),
        .b(product),
        .enable(valid_in_left),
        .sum(adder_result)
    );

    // Main processing logic with valid signal propagation
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            // Reset all outputs
            acc_reg <= '0;
            data_out_bottom <= '0;
            data_out_right <= '0;
            valid_out_bottom <= '0;
            valid_out_right <= '0;
        end else begin
            // Pass through data with valid signals
            data_out_bottom <= data_in_top;
            data_out_right <= data_in_left;
            valid_out_bottom <= valid_in_top;
            valid_out_right <= valid_in_left;
            
            // Update accumulator only when valid computation occurs
            if (valid_in_left) begin
                acc_reg <= adder_result;
            end else begin 
                acc_reg <= '0; end            
        end
    end

endmodule