//the data takes 2 cycles to pass through the PE but the even or odd accumulation happens in 3 cycles but allows to feed it in every cycle, 
//the final result will be ready after 3 cycle after the entire block is done

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
    output logic [15:0]             product_stage1,
    output logic [15:0]             odd_acc_debug,
    output logic [15:0]             even_acc_debug,
    output logic signed [15:0]      acc_reg
);
    // Stage 1 registers
    logic [bit_width-1:0] data_right_stage1, data_bottom_stage1;
    logic valid_right_stage1, valid_bottom_stage1;
//    logic signed [15:0] product_stage1;
    logic signed [15:0] product;
    
    logic toggle;
    always_ff @(posedge clk) begin
        if (rst) begin
            toggle <= 1;
        end else begin
            toggle <= ~toggle;
        end
    end
    
    // Use delayed versions of toggle for result storage
    logic toggle_d1;  // delayed versions for pipeline stages
    always_ff @(posedge clk) begin
        toggle_d1 <= toggle;
    end

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
        end else begin
            // Forward data and valid signals to stage 1
            data_right_stage1 <= data_in_left;
            data_bottom_stage1 <= data_in_top;
            valid_right_stage1 <= valid_in_left;
            valid_bottom_stage1 <= valid_in_top;
            product_stage1 <= product;
        end
    end

    // Accumulation registers
    logic [15:0] odd_acc, even_acc;
    logic [15:0] add_result;

    // Pipelined adder for accumulation
    bfloat16_adder_pipelined accumulator (
        .clk(clk),
        .rst(rst),
        .valid_in(valid_right_stage1 && valid_bottom_stage1),
        .a(~toggle ? odd_acc : even_acc),
        .b(product_stage1),
        .sum(add_result)
//        .valid_out(add_valid_out)
    );


    
    // Stage 2: Accumulation  
    always_ff @(posedge clk) begin
        if (rst) begin
            // Reset stage 2 registers
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
        end
    end 
    
    logic finish_valid; // to know if block ended
    logic [15:0] final_result;
    // Stage 3: Accumulation output and final addition start
    always_ff @(posedge clk) begin
        if (rst) begin
            // Reset stage 2 registers
            odd_acc <= '0;
            even_acc <= '0;

        end else begin
            // Forward data from stage 1 to outputs
            finish_valid <= !(valid_right_stage1 || valid_bottom_stage1);
            if (toggle && !finish_valid)  // use appropriately delayed toggle
                odd_acc <= add_result;
            else if (!finish_valid)
                even_acc <= add_result;
        end
    end 


    bfloat16_adder_pipelined final_adder (
        .clk(clk),
        .rst(rst),
        .valid_in(finish_valid),
        .a(odd_acc),
        .b(even_acc),
        .sum(final_result)
    );

    // Output assignments
    assign acc_reg = final_result;
    assign odd_acc_debug = odd_acc;
    assign even_acc_debug = even_acc;

endmodule
