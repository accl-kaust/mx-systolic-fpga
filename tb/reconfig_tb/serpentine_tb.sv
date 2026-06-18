// serpentine_tb.sv -- per-shape correctness for the runtime serpentine fabric.
// Loads one shape's operands into the array memories, selects the shape at
// runtime via shape_sel, runs one GEMM, and dumps the logical R*C results.
`ifndef R_PARAM `define R_PARAM 32 `endif
`ifndef C_PARAM `define C_PARAM 32 `endif
`ifndef K_PARAM `define K_PARAM 32 `endif

module serpentine_tb;
    parameter R = `R_PARAM;
    parameter C = `C_PARAM;
    parameter k = `K_PARAM;
    parameter exp_width = 4, man_width = 3, bit_width = 1 + exp_width + man_width;
    parameter PR = 32, PC = 32, NCOL = 256;

    logic clk, rst, start, busy, done, result_valid_out;
    logic [1:0] shape_sel;
    logic [bit_width-1:0] west_mem  [PR][k];
    logic [7:0]           west_scale[PR];
    logic [bit_width-1:0] north_mem [NCOL][k];
    logic [7:0]           north_scale[NCOL];
    logic [15:0] bf16_result [PR*PC];

    serpentine_array #(
        .exp_width(exp_width), .man_width(man_width), .k(k),
        .PR(PR), .PC(PC), .NCOL(NCOL)
    ) dut (.*);

    initial begin clk = 0; forever #0.5 clk = ~clk; end

    initial begin
        shape_sel = $clog2(C/32);          // f = C/32 -> sel = log2(f)
        rst = 1; start = 0;
        init_mem();
        load_shape();
        repeat (4) @(posedge clk);
        #0.1 rst = 0;
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;
        wait (done);
        @(posedge clk);
        dump_hex();
        $display("DONE serpentine R=%0d C=%0d shape_sel=%0d", R, C, shape_sel);
        $finish;
    end

    // safety timeout
    initial begin #200000 $display("TIMEOUT"); $finish; end

    task init_mem();
        for (int r = 0; r < PR; r++) begin
            west_scale[r] = 0;
            for (int t = 0; t < k; t++) west_mem[r][t] = '0;
        end
        for (int c = 0; c < NCOL; c++) begin
            north_scale[c] = 0;
            for (int t = 0; t < k; t++) north_mem[c][t] = '0;
        end
    endtask

    // gen_vectors convention: north blocks 0..C-1, west blocks C..C+R-1
    task load_shape();
        int file, sc; string fn; logic [7:0] tmp;
        for (int c = 0; c < C; c++) begin
            fn = $sformatf("block%0d_mx.txt", c);
            file = $fopen(fn, "r");
            if (!file) $fatal(1, "missing %s", fn);
            for (int t = 0; t < k; t++) sc = $fscanf(file, "%b\n", north_mem[c][t]);
            sc = $fscanf(file, "%b\n", tmp); north_scale[c] = tmp;
            $fclose(file);
        end
        for (int r = 0; r < R; r++) begin
            fn = $sformatf("block%0d_mx.txt", C + r);
            file = $fopen(fn, "r");
            if (!file) $fatal(1, "missing %s", fn);
            for (int t = 0; t < k; t++) sc = $fscanf(file, "%b\n", west_mem[r][t]);
            sc = $fscanf(file, "%b\n", tmp); west_scale[r] = tmp;
            $fclose(file);
        end
    endtask

    task dump_hex();
        int hf = $fopen("out_hex.txt", "w");
        for (int i = 0; i < R*C; i++) $fwrite(hf, "%04h\n", bf16_result[i]);
        $fclose(hf);
    endtask
endmodule
