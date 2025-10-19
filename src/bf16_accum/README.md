# BF16 Accumulation Systolic Array Design

This folder contains the SystemVerilog source files for the BF16 accumulation-based systolic array design. The design is parameterized, allowing you to configure MX data type, systolic array size, and block size.

Module Descriptions

**top_bf16_systolic_mx_[1s|2s|3s].sv** - Top Module Variants:
* **top_bf16_systolic_mx_1s.sv**
* **top_bf16_systolic_mx_2s.sv**
* **top_bf16_systolic_mx_3s.sv**
  
Top-level module of the designs with 1 stage, 2stage and 3 stage pipelines. One of these must be defined as the top module in the project.

It contains all key parameters that can be modified by the user:

* exp_width – exponent width of the MX data type
* man_width – mantissa width of the MX data type
* N – systolic array size
* block_size – MX block size

Example:
To implement the MXFP8_E5M2 data type, with systolic array size of 4:

* parameter exp_width = 5;
* parameter man_width = 2;
* N = 4;

**pe_bf16_[1s|2s|3s].sv** - Processing Element (PE) Variants

Each file implements a PE with a different pipeline depth. Include only one depending on your desired design:

* **pe_bf16_1s.sv** – 1-stage pipelined PE
* **pe_bf16_2s.sv** – 2-stage pipelined PE
* **pe_bf16_3s.sv** – 3-stage pipelined PE (using double pumping so it needs a pipelined adder as well)

Note: The PE module name is the same in all files, so only one of them should be included in the project.

**mx_multiplier.sv** - The multiplier will take two MX format inputs and results the multiplication result in BF16 format directly.

**bf16_adder** - The adder that accumulates BF16 values

**bf16_adder_pipelined** - Two stage pipelined accumulator to accumulate BF16 values (can be only used with 3 stage top and pe modules )

Required Modules for a Complete Design

To use the exact accumulation systolic array design, include the following files in your project:

* 1 × Top module (top_bf16_systolic_mx_[1s|2s|3s].sv)

* 1 × PE module (choose one of the pe_bf16_[1s|2s|3s].sv files)

* 1 × Multiplier module (mx_multiplier.sv)

* 1 × Adder module (bf16_adder for top_bf16_systolic_mx_[1s|2s].sv and bf16_adder_pipelined for top_bf16_systolic_mx_3s.sv)
