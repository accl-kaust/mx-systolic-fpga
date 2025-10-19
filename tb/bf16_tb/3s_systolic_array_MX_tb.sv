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
    logic data_valid_west [N];  // Valid signals for west inputslogic data_valid_west [N];
    logic data_valid_north [N]; // Valid signals for north inputslogic data_valid_north [N];
    logic [7:0] shared_scale_west [N];
    logic [7:0] shared_scale_north [N];
//    logic [out_width-1:0] result [N*N];
    logic [15:0]             product[N][N];
    logic [15:0]             odd_acc_debug[N][N];
    logic [15:0]             even_acc_debug[N][N];
    logic [15:0] bf16_result [N*N];
    logic result_valid_out;

    // Test data storage
    logic [bit_width-1:0] test_data_west [N][k];
    logic [bit_width-1:0] test_data_north [N][k];
//    logic [7:0] test_scales [2*N];
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
    
    logic [7:0] cycle_count;
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
        #10;
        
        // Display and verify results
        display_results();
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
                // West input valid signal (row-wise delay)
                data_valid_west[i] <= (cycle_count >= 2*i) && 
                                    (cycle_count < k + 2*i );
                
                // North input valid signal (column-wise delay)
                data_valid_north[i] <= (cycle_count >= 2*i) && 
                                     (cycle_count < k + 2*i);
            end
        end
    end


    // DMA emulation - Data transmission control
    task start_data_transmission();
        for (int cycle = 0; cycle < k + 2*N + 10; cycle++) begin
            @(posedge clk);
            feed_new_data(cycle);
        end
    endtask

    // Load new data each cycle with proper systolic delays
    task feed_new_data(input int cycle);
        for (int i = 0; i < N; i++) begin
            // West data input (row-wise delay)
            if (cycle >= 2*i && cycle < k + 2*i) begin
                data_in_west[i] = test_data_west[i][cycle - 2*i];
            end else begin
                data_in_west[i] = '0;
            end
            
            // North data input (column-wise delay)
            if (cycle >= 2*i && cycle < k + 2*i) begin
                data_in_north[i] = test_data_north[i][cycle - 2*i];
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
        
        // Load matrix data and scales
        for (int i = 0; i < N; i++) begin
            // Load north input data and scale
            filename = $sformatf("block%0d_mx.txt", i);
            file = $fopen(filename, "r");
            if (file) begin
                // Read k data points
                for (int j = 0; j < k; j++) begin
                    scan_file = $fscanf(file, "%b\n", test_data_north[i][j]);
                end
                // Read the scale from k+1 line
                scan_file = $fscanf(file, "%b\n", temp_scale);
                shared_scale_north[i] = temp_scale - 8'd127 + (2**exp_width - 1);
                $fclose(file);
            end
            
            // Load west input data and scale
            filename = $sformatf("block%0d_mx.txt", N+i);
            file = $fopen(filename, "r");
            if (file) begin
                // Read k data points
                for (int j = 0; j < k; j++) begin
                    scan_file = $fscanf(file, "%b\n", test_data_west[i][j]);
                end
                // Read the scale from k+1 line
                scan_file = $fscanf(file, "%b\n", temp_scale);
                shared_scale_west[i] = temp_scale - 8'd127 + (2**exp_width - 1);
                $fclose(file);
            end
        end
    endtask

    // Result display and verification
    task display_results();
        int file = $fopen("result_matrix_bfloat16.txt", "w");
        for (int i = 0; i < N*N; i++) begin
            $display("PE%0d result: (bfloat16: %h)", 
                    i, bf16_result[i]);
            $display("PE%0d in bfloat: %f", 
                    i, $bitstoshortreal({bf16_result[i], 16'h0}));
            $fwrite(file, "%f ", $bitstoshortreal({bf16_result[i], 16'h0}));
            if ((i+1) % N == 0) $fwrite(file, "\n");
        end
        $fclose(file);
    endtask

endmodule
