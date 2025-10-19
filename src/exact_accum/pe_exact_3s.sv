module mxfp8_mac_pe #(
    parameter exp_width = 4,
    parameter man_width = 3,
    parameter bit_width = 1 + exp_width + man_width,
    parameter k = 32,
    parameter fi_width = man_width + 2,
    parameter fi_prd_width = 2 * fi_width,
    parameter prd_width = 2 * ((1<<exp_width) + man_width),
    parameter out_width = prd_width + $clog2(k)
)(
    input  logic [bit_width-1:0] data_in_left,
    input  logic [bit_width-1:0] data_in_top,
    input  logic valid_in_left,
    input  logic valid_in_top,
    input  logic clk,
    input  logic rst,
    output logic [bit_width-1:0] data_out_right,
    output logic [bit_width-1:0] data_out_bottom,
    output logic valid_out_right,
    output logic valid_out_bottom,
    output logic signed [out_width-1:0] acc_out
);
    // Stage 1: Input Registration and Mantissa Preparation
    logic [bit_width-1:0] data_right_stage1, data_bottom_stage1;
    logic [man_width:0] op0_man_ext, op1_man_ext;
    logic [exp_width-1:0] op0_exp_stage1, op1_exp_stage1;
    logic op0_sgn, op1_sgn;
    logic signed [fi_width-1:0] op0_signed_man, op1_signed_man;
    logic unsigned [fi_width-1:0] u_op0, u_op1;
    logic unsigned [fi_prd_width-1:0] u_prd;
    logic prd_sign;
    logic signed [fi_prd_width-1:0] prd_fi_stage2;
    logic valid_right_stage1, valid_bottom_stage1;
    logic op0_nrm_stage1, op1_nrm_stage1;

    // Stage 2: Product Computation and Shifting
    logic [bit_width-1:0] data_right_stage2, data_bottom_stage2;
    logic valid_right_stage2, valid_bottom_stage2;
    logic signed [prd_width-1:0] prd_shifted_stage2;
    
    // Stage 3: Kulisch Accumulation
    logic [bit_width-1:0] data_right_stage3, data_bottom_stage3;
    logic valid_right_stage3, valid_bottom_stage3;
    logic signed [out_width-1:0] acc_reg;

    // Stage 1: Input Registration and Mantissa Preparation
    always_ff @(posedge clk) begin
        if (rst) begin
            data_right_stage1 <= '0;
            data_bottom_stage1 <= '0;
//            prd_fi_stage1 <= '0;
            op0_exp_stage1 <= '0;
            op1_exp_stage1 <= '0;
            op0_nrm_stage1 <= '0;
            op1_nrm_stage1 <= '0;
            valid_right_stage1 <= '0;
            valid_bottom_stage1 <= '0;
        end else begin
            // Extract mantissa and process signs
            op0_man_ext = {|data_in_left[bit_width-2:man_width], 
                           data_in_left[man_width-1:0]};
            op1_man_ext = {|data_in_top[bit_width-2:man_width], 
                           data_in_top[man_width-1:0]};
            
            op0_sgn = data_in_left[bit_width-1];
            op1_sgn = data_in_top[bit_width-1];
            op0_signed_man = op0_sgn ? -op0_man_ext : op0_man_ext;
            op1_signed_man = op1_sgn ? -op1_man_ext : op1_man_ext;
            
            // Perform multiplication
            prd_sign <= (op0_signed_man < 0) ^ (op1_signed_man < 0);
            u_op0 = (op0_signed_man < 0) ? -op0_signed_man : op0_signed_man;
            u_op1 = (op1_signed_man < 0) ? -op1_signed_man : op1_signed_man;
            u_prd <= u_op0 * u_op1;
            
            // Store exponents and normalization flags
            op0_exp_stage1 <= data_in_left[bit_width-2:man_width];
            op1_exp_stage1 <= data_in_top[bit_width-2:man_width];
            op0_nrm_stage1 <= |data_in_left[bit_width-2:man_width];
            op1_nrm_stage1 <= |data_in_top[bit_width-2:man_width];
            
            // Forward path
            data_right_stage1 <= data_in_left;
            data_bottom_stage1 <= data_in_top;
            valid_right_stage1 <= valid_in_left;
            valid_bottom_stage1 <= valid_in_top;
        end
    end

    // Stage 2: Product Shifting
    always_ff @(posedge clk) begin
        if (rst) begin
            data_right_stage2 <= '0;
            data_bottom_stage2 <= '0;
            prd_shifted_stage2 <= '0;
            valid_right_stage2 <= '0;
            valid_bottom_stage2 <= '0;
            prd_fi_stage2 <= '0;
        end else begin
            // Compute shifted product
            prd_fi_stage2 = prd_sign ? -u_prd : u_prd;

            prd_shifted_stage2 <= prd_fi_stage2 << ($unsigned({1'b0, op0_exp_stage1}) + 
                                                   $unsigned({1'b0, op1_exp_stage1}) - 
                                                   $unsigned(op0_nrm_stage1) - 
                                                   $unsigned(op1_nrm_stage1));

            // Forward path
            data_right_stage2 <= data_right_stage1;
            data_bottom_stage2 <= data_bottom_stage1;
            valid_right_stage2 <= valid_right_stage1;
            valid_bottom_stage2 <= valid_bottom_stage1;
        end
    end

    // Stage 3: Kulisch Accumulation
    always_ff @(posedge clk) begin
        if (rst) begin
            acc_reg <= '0;
            data_right_stage3 <= '0;
            data_bottom_stage3 <= '0;
            valid_right_stage3 <= '0;
            valid_bottom_stage3 <= '0;
        end else begin
            // Full-width accumulation with sign extension
            if (valid_right_stage2 && valid_bottom_stage2) begin
                acc_reg <= acc_reg + {{(out_width-prd_width){prd_shifted_stage2[prd_width-1]}}, 
                                    prd_shifted_stage2};
            end

            // Forward path
            data_right_stage3 <= data_right_stage2;
            data_bottom_stage3 <= data_bottom_stage2;
            valid_right_stage3 <= valid_right_stage2;
            valid_bottom_stage3 <= valid_bottom_stage2;
        end
    end

    // Output assignments
    assign data_out_right = data_right_stage3;
    assign data_out_bottom = data_bottom_stage3;
    assign valid_out_right = valid_right_stage3;
    assign valid_out_bottom = valid_bottom_stage3;
    assign acc_out = acc_reg;

endmodule 
