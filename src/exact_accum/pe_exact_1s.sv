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
    input logic valid_in_left,
    input logic valid_in_top,
    input  logic clk,
    input  logic rst,
    output logic [bit_width-1:0] data_out_right,
    output logic [bit_width-1:0] data_out_bottom,
    output logic valid_out_right,
    output logic valid_out_bottom,
    output logic signed [out_width-1:0] acc_out
);
    // Internal registers
    logic signed [out_width-1:0] acc_reg;
    logic [bit_width-1:0] data_out_right_reg, data_out_bottom_reg;

    // FP multiplication signals
    logic op0_sgn, op1_sgn;
    logic [exp_width-1:0] op0_exp, op1_exp;
    logic [man_width:0] op0_man_ext, op1_man_ext;
    logic signed [fi_width-1:0] op0_signed_man, op1_signed_man;
    logic signed [fi_prd_width-1:0] prd_fi;
    logic op0_nrm, op1_nrm;
    logic signed [prd_width-1:0] prd_shifted;

    // Unsigned multiplication signals
    logic unsigned [fi_width-1:0] u_op0, u_op1;
    logic unsigned [fi_prd_width-1:0] u_prd;
    logic prd_sign;

    // FP field separation
    assign op0_sgn = data_in_left[bit_width-1];
    assign op1_sgn = data_in_top[bit_width-1];
    assign op0_exp = data_in_left[bit_width-2:man_width];
    assign op1_exp = data_in_top[bit_width-2:man_width];
    assign op0_man_ext = {|op0_exp, data_in_left[man_width-1:0]};
    assign op1_man_ext = {|op1_exp, data_in_top[man_width-1:0]};

    // Sign handling for mantissas
    assign op0_signed_man = op0_sgn ? -op0_man_ext : op0_man_ext;
    assign op1_signed_man = op1_sgn ? -op1_man_ext : op1_man_ext;

    // Integrated mul_i8 logic
    always_comb begin
        prd_sign = (op0_signed_man < 0) ^ (op1_signed_man < 0);
        u_op0 = (op0_signed_man < 0) ? -op0_signed_man : op0_signed_man;
        u_op1 = (op1_signed_man < 0) ? -op1_signed_man : op1_signed_man;
        u_prd = u_op0 * u_op1;
        prd_fi = prd_sign ? -u_prd : u_prd;
    end

    // Shift and normalize product
    assign op0_nrm = |op0_exp;
    assign op1_nrm = |op1_exp;
    assign prd_shifted = prd_fi << ($unsigned({1'b0, op0_exp}) + 
                                  $unsigned({1'b0, op1_exp}) - 
                                  $unsigned(op0_nrm) - 
                                  $unsigned(op1_nrm));

    // Register updates
    always_ff @(posedge clk) begin
        if (rst) begin
            acc_reg <= 0;
            data_out_right_reg <= 0;
            data_out_bottom_reg <= 0;
            valid_out_bottom <= 0;
            valid_out_right <= 0;
        end else begin
            acc_reg <= acc_reg + prd_shifted;
            data_out_right_reg <= data_in_left;
            data_out_bottom_reg <= data_in_top;
            valid_out_bottom <= valid_in_top;
            valid_out_right <= valid_in_left;
        end
    end

    // Output assignments
    assign data_out_right = data_out_right_reg;
    assign data_out_bottom = data_out_bottom_reg;
    assign acc_out = acc_reg;

endmodule