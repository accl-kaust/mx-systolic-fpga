# Exact Accumulation Systolic Array Design

This folder contains the SystemVerilog source files for the Exact accumulation-based systolic array design. The design is parameterized, allowing you to configure MX data type, systolic array size, and block size.

Module Descriptions

**top_exact_systolic_mx.sv** - Top-level module of the design. This must be defined as the top module in the project.
It contains all key parameters that can be modified by the user:
* exp_width – exponent width of the MX data type
* man_width – mantissa width of the MX data type
* N – systolic array size
* block_size – MX block size

Example:
To implement the MXFP8_E5M2 data type:

* parameter exp_width = 5;
* parameter man_width = 2;

**pe_exact_[1s|2s|3s|4s].sv** - Processing Element (PE) Variants

Each file implements a PE with a different pipeline depth. Include only one depending on your desired design:
* **pe_exact_1s.sv** – 1-stage pipelined PE
* **pe_exact_2s.sv** – 2-stage pipelined PE
* **pe_exact_3s.sv** – 3-stage pipelined PE
* **pe_exact_4s.sv** – 4-stage pipelined PE

Note: The PE module name is the same in all files, so only one of them should be included in the project.

**convert_fixed2bf16.sv** - Conversion module that converts the exact accumulated fixed-point result into BF16 format.
It also accounts for the shared scale when performing the conversion.

**clz.sv** - Leading zero counter module required for normalization during conversion.

Required Modules for a Complete Design

To use the exact accumulation systolic array design, include the following files in your project:

* 1 × Top module (top_exact_systolic_mx.sv)

* 1 × PE module (choose one of the pe_exact_[1s|2s|3s|4s].sv files)

* 1 × Conversion module (convert_fixed2bf16.sv)

* 1 × CLZ module (clz.sv)
