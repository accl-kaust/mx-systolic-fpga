// gemm_driver_tb.sv -- parameterized driver for os_array_shaped.
//
// Parameterized by (M, N, K, R, C) via `define overrides (set with `xvlog -d`):
//   R,C  = logical array shape (R rows west-fed, C cols north-fed), R*C = P
//   M,N  = GEMM output rows/cols actually present in the vectors (M<=R, N<=C)
//   K    = contraction length (= MX block length, 32 for now)
//
// Loads generated vectors (block 0..N-1 = north, block N..N+M-1 = west),
// ZERO-PADS the unused west rows (M..R-1) and north cols (N..C-1), applies the
// existing systolic skew, runs, and dumps the R*C bf16 results as hex.
//
// The checker compares only the M x N real sub-block against golden.txt.
`ifndef R_PARAM `define R_PARAM 32 `endif
`ifndef C_PARAM `define C_PARAM 32 `endif
`ifndef M_PARAM `define M_PARAM 32 `endif
`ifndef N_PARAM `define N_PARAM 32 `endif
`ifndef K_PARAM `define K_PARAM 32 `endif
`ifndef P_PARAM `define P_PARAM 1024 `endif

module gemm_driver_tb;
    parameter R = `R_PARAM;
    parameter C = `C_PARAM;
    parameter M = `M_PARAM;
    parameter N = `N_PARAM;
    parameter k = `K_PARAM;
    parameter P = `P_PARAM;
    parameter exp_width = 4;
    parameter man_width = 3;
    parameter bit_width = 1 + exp_width + man_width;

    logic clk;
    logic rst;
    logic [bit_width-1:0] data_in_west  [R];
    logic [bit_width-1:0] data_in_north [C];
    logic data_valid_west  [R];
    logic data_valid_north [C];
    logic [7:0] shared_scale_west  [R];
    logic [7:0] shared_scale_north [C];
    logic [15:0] bf16_result [R*C];
    logic result_valid_out;

    // Operand storage (only M west rows / N north cols are real; rest are zero).
    logic [bit_width-1:0] test_data_west  [R][k];
    logic [bit_width-1:0] test_data_north [C][k];

    os_array_shaped #(
        .exp_width(exp_width), .man_width(man_width),
        .k(k), .R(R), .C(C), .P(P)
    ) dut (.*);

    initial begin
        clk = 0;
        forever #0.5 clk = ~clk;
    end

    // Skew window must cover the larger of the two dimensions.
    localparam SKEW = (R > C) ? R : C;

    int cycle_count;
    int valid_cycle = -1;   // cycle the bottom-right corner first goes valid
    initial begin
        rst = 1;
        for (int i = 0; i < R; i++) begin
            data_valid_west[i] = 0; data_in_west[i] = '0; shared_scale_west[i] = '0;
        end
        for (int j = 0; j < C; j++) begin
            data_valid_north[j] = 0; data_in_north[j] = '0; shared_scale_north[j] = '0;
        end

        load_test_data();
        #4 rst = 0;
        start_data_transmission();

        // Wait for completion, but never hang: a generous failsafe bounds the sim.
        wait((result_valid_out === 1'b1) || (cycle_count > k + 4*SKEW + 200));
        #100;
        dump_hex_results();
        if (valid_cycle < 0)
            $display("WARN: result_valid_out never asserted (failsafe at cycle %0d)",
                     cycle_count);
        $display("DONE shape R=%0d C=%0d  gemm M=%0d N=%0d K=%0d valid_cycle=%0d total_cycles=%0d",
                 R, C, M, N, k, valid_cycle, cycle_count);
        $finish;
    end

    // Record the cycle at which the bottom-right corner first goes valid.
    always_ff @(posedge clk) begin
        if (rst) cycle_count <= 0;
        else     cycle_count <= cycle_count + 1;
        if (!rst && valid_cycle < 0 && result_valid_out === 1'b1)
            valid_cycle <= cycle_count;
    end

    // Per-input valid: west row i opens at cycle i, north col j opens at cycle j.
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < R; i++) data_valid_west[i]  <= 0;
            for (int j = 0; j < C; j++) data_valid_north[j] <= 0;
        end else begin
            for (int i = 0; i < R; i++)
                data_valid_west[i]  <= (cycle_count >= i) && (cycle_count < k + i);
            for (int j = 0; j < C; j++)
                data_valid_north[j] <= (cycle_count >= j) && (cycle_count < k + j);
        end
    end

    task start_data_transmission();
        for (int cycle = 0; cycle < k + 2*SKEW - 1; cycle++) begin
            @(posedge clk);
            feed_new_data(cycle);
        end
    endtask

    task feed_new_data(input int cycle);
        for (int i = 0; i < R; i++) begin
            if (cycle >= i && cycle < k + i)
                data_in_west[i] = test_data_west[i][cycle - i];
            else
                data_in_west[i] = '0;
        end
        for (int j = 0; j < C; j++) begin
            if (cycle >= j && cycle < k + j)
                data_in_north[j] = test_data_north[j][cycle - j];
            else
                data_in_north[j] = '0;
        end
    endtask

    // Load real operands for M west rows / N north cols; pad the rest with zero.
    task load_test_data();
        int file, scan_file;
        string filename;
        logic [7:0] temp_scale;

        // NORTH cols 0..N-1 (block 0..N-1)
        for (int j = 0; j < C; j++) begin
            if (j < N) begin
                filename = $sformatf("block%0d_mx.txt", j);
                file = $fopen(filename, "r");
                if (file) begin
                    for (int t = 0; t < k; t++)
                        scan_file = $fscanf(file, "%b\n", test_data_north[j][t]);
                    scan_file = $fscanf(file, "%b\n", temp_scale);
                    shared_scale_north[j] = temp_scale;
                    $fclose(file);
                end else $fatal(1, "missing %s", filename);
            end else begin
                for (int t = 0; t < k; t++) test_data_north[j][t] = '0;
                shared_scale_north[j] = '0;
            end
        end

        // WEST rows 0..M-1 (block N..N+M-1)
        for (int i = 0; i < R; i++) begin
            if (i < M) begin
                filename = $sformatf("block%0d_mx.txt", N + i);
                file = $fopen(filename, "r");
                if (file) begin
                    for (int t = 0; t < k; t++)
                        scan_file = $fscanf(file, "%b\n", test_data_west[i][t]);
                    scan_file = $fscanf(file, "%b\n", temp_scale);
                    shared_scale_west[i] = temp_scale;
                    $fclose(file);
                end else $fatal(1, "missing %s", filename);
            end else begin
                for (int t = 0; t < k; t++) test_data_west[i][t] = '0;
                shared_scale_west[i] = '0;
            end
        end
    endtask

    // Dump the M x N real sub-block (row-major) as hex, one bf16 per line, so the
    // checker can compare directly against the M x N golden without padding rows.
    task dump_hex_results();
        static int hf = $fopen("out_hex.txt", "w");
        for (int i = 0; i < M; i++)
            for (int j = 0; j < N; j++)
                $fwrite(hf, "%04h\n", bf16_result[i*C + j]);
        $fclose(hf);
    endtask

endmodule
