module bfloat16_adder(
    input [15:0] a, b,
    input enable,
    output [15:0] sum
);
    reg [15:0] big_num, small_num;
    reg zero, NaN;
    // Compare inputs once and store in intermediate signals
    wire a_bigger = (a[14:7] > b[14:7]) || (a[14:7] == b[14:7] && a[6:0] >= b[6:0]);
                   
    always_comb begin
        big_num = a_bigger ? a : b;
        small_num = a_bigger ? b : a;
    end

    // Rest of your original code remains the same, starting from:
    wire sign_big = big_num[15];
    wire sign_small = small_num[15];
    wire [7:0] exp_big = big_num[14:7];
    wire [7:0] exp_small = small_num[14:7];
    wire [6:0] man_big = big_num[6:0];
    wire [6:0] man_small = small_num[6:0];
    
    // Extended mantissas (including hidden 1)
    wire [7:0] man_big_ext = {1'b1, man_big};
    wire [7:0] man_small_ext = {1'b1, man_small};
    
    // Alignment and operation signals
    wire [7:0] exp_diff = exp_big - exp_small;
    wire same_sign = (sign_big == sign_small);
    wire [8:0] shifted_small_man;  // Extra bit for potential carry
    wire [8:0] aligned_big_man = {man_big_ext, 1'b0};
    
    // Mantissa operation results
    wire [9:0] mantissa_result;
    wire [7:0] final_exp;
    wire [6:0] final_man;
    wire final_sign;
    
    // Special case detection
    wire small_is_zero = (exp_small == 8'h0) && (man_small == 7'h0);
    wire big_is_zero = (exp_big == 8'h0) && (man_big == 7'h0);
    assign zero = big_is_zero && small_is_zero;
    assign NaN = (&exp_big && |man_big) || (&exp_small && |man_small);
//    assign overflow = &final_exp && !zero && !NaN;

    // Align mantissas
    assign shifted_small_man = exp_diff >= 8 ? 9'h0 :
                              {man_small_ext, 1'b0} >> exp_diff;

    // Add/subtract mantissas
    assign mantissa_result = same_sign ? 
                            aligned_big_man + shifted_small_man :
                            aligned_big_man - shifted_small_man;

    // Normalization and leading zero detection
    wire [3:0] lead_zeros;
    assign lead_zeros =mantissa_result[8] ? 4'd0 :
                       mantissa_result[7] ? 4'd1 :
                       mantissa_result[6] ? 4'd2 :
                       mantissa_result[5] ? 4'd3 :
                       mantissa_result[4] ? 4'd4 :
                       mantissa_result[3] ? 4'd5 :
                       mantissa_result[2] ? 4'd6 :
                       mantissa_result[1] ? 4'd7 :
                       mantissa_result[0] ? 4'd8 : 4'd9;

    // Final result assembly
    assign final_sign = sign_big;                   
    assign final_exp = mantissa_result[9] ? exp_big + 8'd1 :
                      (|mantissa_result ? exp_big - lead_zeros : 8'h0);
                      
    reg [9:0] shifted_result;
    assign shifted_result = (|mantissa_result[6:0] && !(|mantissa_result[9:7])) ? ({mantissa_result[6:0], 3'b0} >> lead_zeros) : 0;
    assign final_man = mantissa_result[9] ? mantissa_result[8:2] :
                  mantissa_result[8] ? mantissa_result[7:1] :
                  mantissa_result[7] ? mantissa_result[6:0] :
                  shifted_result[6:0];

    // Result assignment
    assign sum = enable ? (NaN ? {1'b0, 8'hFF, 7'h1} :
                   zero ? 16'h0 :
                   {final_sign, final_exp, final_man}): a;

endmodule
