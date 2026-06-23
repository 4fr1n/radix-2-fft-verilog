/ tb_fft.v
// Testbench for the 8-point FFT accelerator.
//
// Test input: x = [1, 2, 3, 4, 4, 3, 2, 1]
//
// Expected output (from Python numpy.fft.fft):
//   X[0] = 20 + 0j          (DC — equals sum of all inputs)
//   X[1] = -5.828 - 2.414j
//   X[2] =  0 + 0j
//   X[3] = -0.172 - 0.414j
//   X[4] =  0 + 0j
//   X[5] = -0.172 + 0.414j
//   X[6] =  0 + 0j
//   X[7] = -5.828 + 2.414j
//
// In Q1.15 fixed-point (multiply by 32768 to convert):
//   X[0] real ≈ 20 (we use integer inputs so values are not normalised;
//                   DC = sum of inputs = 20, stored as integer 20)
//
// NOTE: Because our inputs are integers (not Q1.15 fractions), the
// output will also be integers scaled by the input amplitude.
// X[0] = 20 means the DC component is 20 counts.
//
// BIT-REVERSED INPUT ORDER for x = [1,2,3,4,4,3,2,1]:
//   mem[0] = x[0] = 1    (bit-rev of 0 = 0)
//   mem[1] = x[4] = 4    (bit-rev of 1 = 4)
//   mem[2] = x[2] = 3    (bit-rev of 2 = 2)
//   mem[3] = x[6] = 2    (bit-rev of 3 = 6)
//   mem[4] = x[1] = 2    (bit-rev of 4 = 1)
//   mem[5] = x[5] = 3    (bit-rev of 5 = 5)
//   mem[6] = x[3] = 4    (bit-rev of 6 = 3)
//   mem[7] = x[7] = 1    (bit-rev of 7 = 7)
 
`timescale 1ns/1ps
 
module tb_fft;
 
    // ---------------------------------------------------------------
    // DUT signals
    // ---------------------------------------------------------------
    reg         clk, rst_n, start;
    reg         load_we;
    reg  [2:0]  load_addr;
    reg  signed [15:0] load_dr, load_di;
    reg  [2:0]  result_addr;
    wire signed [15:0] result_r, result_i;
    wire        done;
 
    // ---------------------------------------------------------------
    // DUT instantiation
    // ---------------------------------------------------------------
    fft_top dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .load_we    (load_we),
        .load_addr  (load_addr),
        .load_dr    (load_dr),
        .load_di    (load_di),
        .result_addr(result_addr),
        .result_r   (result_r),
        .result_i   (result_i),
        .done       (done)
    );
 
    // ---------------------------------------------------------------
    // Clock: 10ns period (100 MHz)
    // ---------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;
 
    // ---------------------------------------------------------------
    // Bit-reversed input: x = [1, 2, 3, 4, 4, 3, 2, 1]
    // mem[i] = x[bit_reverse(i)]
    // ---------------------------------------------------------------
    reg signed [15:0] input_real [0:7];
    reg signed [15:0] input_imag [0:7];
 
    initial begin
        // bit-reversed order
        input_real[0] = 16'd1;   input_imag[0] = 16'd0;   // x[0]
        input_real[1] = 16'd4;   input_imag[1] = 16'd0;   // x[4]
        input_real[2] = 16'd3;   input_imag[2] = 16'd0;   // x[2]
        input_real[3] = 16'd2;   input_imag[3] = 16'd0;   // x[6]
        input_real[4] = 16'd2;   input_imag[4] = 16'd0;   // x[1]
        input_real[5] = 16'd3;   input_imag[5] = 16'd0;   // x[5]
        input_real[6] = 16'd4;   input_imag[6] = 16'd0;   // x[3]
        input_real[7] = 16'd1;   input_imag[7] = 16'd0;   // x[7]
    end
 
    // ---------------------------------------------------------------
    // Test sequence
    // ---------------------------------------------------------------
    integer i;
 
    initial begin
        $dumpfile("fft_sim.vcd");
        $dumpvars(0, tb_fft);
 
        // Reset
        rst_n     = 0;
        start     = 0;
        load_we   = 0;
        load_addr = 0;
        load_dr   = 0;
        load_di   = 0;
        result_addr = 0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;
 
        // -------------------------------------------------------
        // Load samples in bit-reversed order into reg_file
        // -------------------------------------------------------
        $display("--- Loading samples (bit-reversed) ---");
        for (i = 0; i < 8; i = i + 1) begin
            load_we   = 1;
            load_addr = i[2:0];
            load_dr   = input_real[i];
            load_di   = input_imag[i];
            @(posedge clk); #1;
        end
        load_we = 0;
        @(posedge clk); #1;
 
        // -------------------------------------------------------
        // Start FFT
        // -------------------------------------------------------
        $display("--- Starting FFT ---");
        start = 1;
        @(posedge clk); #1;
        start = 0;
 
        // -------------------------------------------------------
        // Wait for done
        // -------------------------------------------------------
        @(posedge done);
        @(posedge clk); #1;
        $display("--- FFT complete ---");
 
        // -------------------------------------------------------
        // Read and display results
        // -------------------------------------------------------
        $display("\n--- FFT Output X[k] ---");
        $display("k  |  real       |  imag      ");
        $display("---+-------------+------------");
 
        for (i = 0; i < 8; i = i + 1) begin
            result_addr = i[2:0];
            @(posedge clk); #1;
            @(posedge clk); #1;   // wait one extra cycle for read to settle
            $display("%0d  |  %d\t|  %d", i, $signed(result_r), $signed(result_i));
        end
 
        $display("\n--- Expected output (reference) ---");
        $display("X[0] real=20,    imag=0");
        $display("X[1] real=-5828, imag=-2414  (x32768 scaled from -0.1777, -0.0736)");
        $display("X[2] real=0,     imag=0");
        $display("X[3] real~0,     imag~0");
        $display("X[4] real=0,     imag=0");
        $display("X[5] real~0,     imag~0");
        $display("X[6] real=0,     imag=0");
        $display("X[7] real=-5828, imag=2414");
        $display("\nNote: DC bin X[0]=20 = sum of all inputs (1+2+3+4+4+3+2+1). Check this first.");
 
        #100;
        $finish;
    end
 
    // -------------------------------------------------------
    // Timeout watchdog — fail if FFT takes more than 500 cycles
    // -------------------------------------------------------
    initial begin
        #5000;
        $display("TIMEOUT: FFT did not complete in 500 cycles.");
        $finish;
    end
 
endmodule
