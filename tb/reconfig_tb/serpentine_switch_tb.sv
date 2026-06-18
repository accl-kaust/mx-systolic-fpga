// serpentine_switch_tb.sv -- runtime reconfiguration demo.
// ONE elaborated serpentine_array runs a GEMM in shape A, then (without any
// re-elaboration) switches shape_sel and runs a GEMM in shape B. Because the
// switchbox muxes are combinational in shape_sel, the new shape takes effect on
// the cycle the controller latches it (1-cycle switch). Both result sets are
// dumped and checked against their own goldens.
`ifndef RA_PARAM `define RA_PARAM 32 `endif
`ifndef CA_PARAM `define CA_PARAM 32 `endif
`ifndef RB_PARAM `define RB_PARAM 4 `endif
`ifndef CB_PARAM `define CB_PARAM 256 `endif
`ifndef K_PARAM  `define K_PARAM 32 `endif

module serpentine_switch_tb;
    parameter RA = `RA_PARAM, CA = `CA_PARAM;
    parameter RB = `RB_PARAM, CB = `CB_PARAM;
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
    initial begin #400000 $display("TIMEOUT"); $finish; end

    initial begin
        rst = 1; start = 0; shape_sel = 0;
        repeat (4) @(posedge clk);
        #0.1 rst = 0;
        @(posedge clk);

        // ---- shape A ----
        init_mem(); load_shape("a_", RA, CA);
        shape_sel = $clog2(CA/32);
        run_gemm();
        dump("a_out_hex.txt", RA, CA);
        $display("SWITCH ran shape A: R=%0d C=%0d sel=%0d", RA, CA, shape_sel);

        // ---- runtime switch to shape B (no re-elaboration) ----
        init_mem(); load_shape("b_", RB, CB);
        shape_sel = $clog2(CB/32);          // new shape; latched at next start
        run_gemm();
        dump("b_out_hex.txt", RB, CB);
        $display("SWITCH ran shape B: R=%0d C=%0d sel=%0d", RB, CB, shape_sel);

        $finish;
    end

    task run_gemm();
        @(posedge clk);
        start = 1; @(posedge clk); start = 0;
        wait (done);
        @(posedge clk);
        // return to idle for the next GEMM
        wait (!busy);
    endtask

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

    task load_shape(input string pfx, input int R, input int C);
        int file, sc; string fn; logic [7:0] tmp;
        for (int c = 0; c < C; c++) begin
            fn = $sformatf("%sblock%0d_mx.txt", pfx, c);
            file = $fopen(fn, "r");
            if (!file) $fatal(1, "missing %s", fn);
            for (int t = 0; t < k; t++) sc = $fscanf(file, "%b\n", north_mem[c][t]);
            sc = $fscanf(file, "%b\n", tmp); north_scale[c] = tmp;
            $fclose(file);
        end
        for (int r = 0; r < R; r++) begin
            fn = $sformatf("%sblock%0d_mx.txt", pfx, C + r);
            file = $fopen(fn, "r");
            if (!file) $fatal(1, "missing %s", fn);
            for (int t = 0; t < k; t++) sc = $fscanf(file, "%b\n", west_mem[r][t]);
            sc = $fscanf(file, "%b\n", tmp); west_scale[r] = tmp;
            $fclose(file);
        end
    endtask

    task dump(input string fn, input int R, input int C);
        int hf = $fopen(fn, "w");
        for (int i = 0; i < R*C; i++) $fwrite(hf, "%04h\n", bf16_result[i]);
        $fclose(hf);
    endtask
endmodule
