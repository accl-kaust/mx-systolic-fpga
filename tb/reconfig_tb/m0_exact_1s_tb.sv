// M0 testbench: copy of tb/exact_tb/1s_systolic_array_MX_tb.sv, with an added
// hex dump of the bf16 results to out_hex.txt (one value per line). The DUT is
// unchanged -- this only adds an output dump for the simulator-agnostic Python
// checker (tools/check_results.py).
module systolic_array_MX_tb;
    parameter N = 32;
    parameter k = 32;
    parameter exp_width = 4;
    parameter man_width = 3;
    parameter bit_width = 1 + exp_width + man_width;
    parameter out_width = 2 * ((1<<exp_width) + man_width) + $clog2(k);

    // Testbench signals
    logic clk;
    logic rst;
    logic [bit_width-1:0] data_in_west [N];
    logic [bit_width-1:0] data_in_north [N];
    logic data_valid_west [N];
    logic data_valid_north [N];
    logic [7:0] shared_scale_west [N];
    logic [7:0] shared_scale_north [N];
    logic [out_width-1:0] result [N*N];
    logic [15:0] bf16_result [N*N];
    logic result_valid_out;

    // Test data storage
    logic [bit_width-1:0] test_data_west [N][k];
    logic [bit_width-1:0] test_data_north [N][k];
    logic [7:0] test_scales [2*N];
    int data_index;

    // DUT instantiation
    systolic_array_MX #(
        .N(N),
        .k(k),
        .exp_width(exp_width),
        .man_width(man_width)
    ) dut (.*);

    // Clock generation
    initial begin
        clk = 0;
        forever #0.5 clk = ~clk;
    end

    logic [4:0] cycle_count;
    initial begin
        rst = 1;  // Active high reset
        for (int i = 0; i < N; i++) begin
            data_valid_west[i] = 0;
            data_valid_north[i] = 0;
            data_in_west[i] = '0;
            data_in_north[i] = '0;
        end

        // Initialize test data arrays
        load_test_data();

        // Reset sequence
        #4 rst = 0;

        // Start data feeding
        start_data_transmission();

        // Wait for completion
        wait(result_valid_out);
        #100;

        // Display and verify results
        display_results();
        dump_hex_results();
        $finish;
    end

    // Cycle counter
    always_ff @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
        end
    end

    // Valid signal generation with systolic timing
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < N; i++) begin
                data_valid_west[i] <= 0;
                data_valid_north[i] <= 0;
            end
        end else begin
            for (int i = 0; i < N; i++) begin
                data_valid_west[i] <= (cycle_count >= i) &&
                                    (cycle_count < k + i);
                data_valid_north[i] <= (cycle_count >= i) &&
                                     (cycle_count < k + i);
            end
        end
    end

    // DMA emulation - Data transmission control
    task start_data_transmission();
        for (int cycle = 0; cycle < k + 2*N - 1; cycle++) begin
            @(posedge clk);
            feed_new_data(cycle);
        end
    endtask

    // Load new data each cycle with proper systolic delays
    task feed_new_data(input int cycle);
        for (int i = 0; i < N; i++) begin
            if (cycle >= i && cycle < k + i) begin
                data_in_west[i] = test_data_west[i][cycle - i];
            end else begin
                data_in_west[i] = '0;
            end

            if (cycle >= i && cycle < k + i) begin
                data_in_north[i] = test_data_north[i][cycle - i];
            end else begin
                data_in_north[i] = '0;
            end
        end
    endtask

    // Load test data from files
    task load_test_data();
        int file, scan_file;
        string filename;
        logic [bit_width-1:0] temp_data;
        logic [7:0] temp_scale;

        for (int i = 0; i < N; i++) begin
            // Load north input data and scale
            filename = $sformatf("block%0d_mx.txt", i);
            file = $fopen(filename, "r");
            if (file) begin
                for (int j = 0; j < k; j++) begin
                    scan_file = $fscanf(file, "%b\n", test_data_north[i][j]);
                end
                scan_file = $fscanf(file, "%b\n", temp_scale);
                shared_scale_north[i] = temp_scale;
                $fclose(file);
            end

            // Load west input data and scale
            filename = $sformatf("block%0d_mx.txt", N+i);
            file = $fopen(filename, "r");
            if (file) begin
                for (int j = 0; j < k; j++) begin
                    scan_file = $fscanf(file, "%b\n", test_data_west[i][j]);
                end
                scan_file = $fscanf(file, "%b\n", temp_scale);
                shared_scale_west[i] = temp_scale;
                $fclose(file);
            end
        end
    endtask

    // Result display (kept from original)
    task display_results();
        int file = $fopen("result_matrix_bfloat16.txt", "w");
        for (int i = 0; i < N*N; i++) begin
            $display("PE%0d result: %h (bfloat16: %h)",
                    i, result[i], bf16_result[i]);
            $fwrite(file, "%f ", $bitstoshortreal({bf16_result[i], 16'h0}));
            if ((i+1) % N == 0) $fwrite(file, "\n");
        end
        $fclose(file);
    endtask

    // M0 addition: dump raw bf16 hex, one value per line, for the Python checker.
    task dump_hex_results();
        int hf = $fopen("out_hex.txt", "w");
        for (int i = 0; i < N*N; i++) begin
            $fwrite(hf, "%04h\n", bf16_result[i]);
        end
        $fclose(hf);
    endtask

endmodule
