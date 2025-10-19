module bfloat16_adder_pipelined(
    input  logic        clk,
    input  logic        rst,
    input  logic        valid_in,
    input  logic [15:0] a,
    input  logic [15:0] b,
    output logic [15:0] sum
);

  //==========================================================================
  // Stage 1: Compare, Align, and Mantissa Add/Subtract
  //==========================================================================
  // (Extract fields and compute intermediate values.)
  
  // --- Combinational extraction ---
  // bfloat16 format: [15] sign, [14:7] exponent, [6:0] mantissa
  wire sign_a = a[15];
  wire sign_b = b[15];
  wire [7:0] exp_a = a[14:7];
  wire [7:0] exp_b = b[14:7];
  wire [6:0] man_a = a[6:0];
  wire [6:0] man_b = b[6:0];
// Determine which input is larger (by exponent then mantissa)
  wire a_bigger = (exp_a > exp_b) || (exp_a == exp_b && man_a >= man_b);
  
  wire [15:0] big_num   = a_bigger ? a : b;
  wire [15:0] small_num = a_bigger ? b : a;
  
  wire sign_big   = big_num[15];
  wire [7:0] exp_big    = big_num[14:7];
  wire [6:0] man_big    = big_num[6:0];
  
  wire sign_small = small_num[15];
  wire [7:0] exp_small  = small_num[14:7];
  wire [6:0] man_small  = small_num[6:0];
  
  // Extended mantissas (add the hidden bit)
  wire [7:0] man_big_ext   = {1'b1, man_big};
  wire [7:0] man_small_ext = {1'b1, man_small};
  
  // Exponent difference
  wire [7:0] exp_diff = exp_big - exp_small;
  
  // Precompute shifted versions of the small mantissa.
  // (We precompute shifts for differences 0 to 7; if exp_diff >= 8, result is zero.)
  wire [8:0] shift_options[0:7];
  assign shift_options[0] = {man_small_ext, 1'b0};              // shift 0
  assign shift_options[1] = {1'b0,         man_small_ext};       // shift 1
  assign shift_options[2] = {2'b0,         man_small_ext[7:1]};    // shift 2
  assign shift_options[3] = {3'b0,         man_small_ext[7:2]};    // shift 3
  assign shift_options[4] = {4'b0,         man_small_ext[7:3]};    // shift 4
  assign shift_options[5] = {5'b0,         man_small_ext[7:4]};    // shift 5
  assign shift_options[6] = {6'b0,         man_small_ext[7:5]};    // shift 6
  assign shift_options[7] = {7'b0,         man_small_ext[7:6]};    // shift 7
  
  wire [8:0] shifted_small_man = small_is_zero ? 0: ((exp_diff >= 8) ? 9'h0 :
                                 shift_options[exp_diff[2:0]]);
  
  // Aligned big mantissa (append a 0 LSB for potential carry)
  wire [8:0] aligned_big_man = big_is_zero ? 0: {man_big_ext, 1'b0};
  
  // Operation: if the signs are the same, add; if different, subtract.
  wire same_sign = (sign_big == sign_small);
  wire [9:0] mantissa_result = same_sign ? (aligned_big_man + shifted_small_man)
                                         : (aligned_big_man - shifted_small_man);
  
  // Special case detection (zero and NaN)
  wire small_is_zero = (exp_small == 8'h0) && (man_small == 7'h0);
  wire big_is_zero   = (exp_big   == 8'h0) && (man_big   == 7'h0);
  wire zero_flag     = big_is_zero && small_is_zero;
  wire NaN_flag      = ((&exp_big) && (|man_big)) || ((&exp_small) && (|man_small));
  
  //--- Stage 1 Pipeline Registers ---
  typedef struct packed {
    logic        valid;
    logic        sign_big;
    logic [7:0]  exp_big;
    logic [9:0]  mantissa_result;
    logic        zero_flag;
    logic        NaN_flag;
  } stage1_t;
  
  stage1_t stage1_reg;
  
  always_ff @(posedge clk or posedge rst) begin
    if (rst)
      stage1_reg <= '0;
    else if (valid_in) begin
      stage1_reg.valid           <= valid_in;
      stage1_reg.sign_big        <= sign_big;
      stage1_reg.exp_big         <= exp_big;
      stage1_reg.mantissa_result <= mantissa_result;
      stage1_reg.zero_flag       <= zero_flag;
      stage1_reg.NaN_flag        <= NaN_flag;
    end else begin
      stage1_reg.valid <= 1'b0;
    end
  end
  
  //==========================================================================
  // Stage 2: Normalization and Final Result Assembly
  //==========================================================================
  // Use the stage1 pipeline register signals to compute the final exponent
  // and mantissa. We perform leading-zero detection and adjust the result.
  
  // Combinational leading-zero detection.
  // (Examine bits [8:0] of the 10-bit mantissa_result from stage 1.)
  logic [3:0] lead_zeros;
  always_comb begin
    casez (stage1_reg.mantissa_result[8:0])
      9'b1????????: lead_zeros = 4'd0;
      9'b01???????: lead_zeros = 4'd1;
      9'b001??????: lead_zeros = 4'd2;
      9'b0001?????: lead_zeros = 4'd3;
      9'b00001????: lead_zeros = 4'd4;
      9'b000001???: lead_zeros = 4'd5;
      9'b0000001??: lead_zeros = 4'd6;
      9'b00000001?: lead_zeros = 4'd7;
      9'b000000001: lead_zeros = 4'd8;
      default:       lead_zeros = 4'd9;
    endcase
  end
// Compute final exponent and mantissa based on the result.
  logic [7:0] final_exp;
  logic [8:0] final_man_ext;
  logic [6:0] final_man;
  logic       final_sign;
  
  // In this example:
  // - If there is an overflow (bit 9 is 1) we shift right and increment the exponent.
  // - Otherwise, if the result is nonzero, we subtract the leading-zero count.
  // - final_sign is simply the sign of the bigger operand.
  always_comb begin
    if (stage1_reg.NaN_flag) begin
      final_sign = 1'b0;
      final_exp  = 8'hFF;
      final_man  = 7'h1;
    end else if (stage1_reg.zero_flag) begin
      final_sign = 1'b0;
      final_exp  = 8'd0;
      final_man  = 7'd0;
    end else if (stage1_reg.mantissa_result[9]) begin
      // Overflow: shift right by one, increment exponent.
      final_exp  = stage1_reg.exp_big + 8'd1;
      final_man  = stage1_reg.mantissa_result[8:2];
      final_sign = stage1_reg.sign_big;
    end else begin
      // Normal case: adjust exponent by subtracting leading zeros.
      final_exp  = (|stage1_reg.mantissa_result) ? (stage1_reg.exp_big - lead_zeros) : 8'd0;
      // Normalize the mantissa: shift left by the number of leading zeros.
      final_man_ext  = (stage1_reg.mantissa_result << lead_zeros);
      final_man  = final_man_ext[7:1];
      final_sign = stage1_reg.sign_big;
    end
  end
  
  assign sum = stage1_reg.valid ? {final_sign, final_exp, final_man} : '0;

endmodule
