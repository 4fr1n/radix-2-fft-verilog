// fft_top.v
// Top-level 8-point in-place FFT accelerator.
//
// Wires together:
//   - reg_file        (16 sample registers, dual-port)
//   - twiddle_rom     (4 complex constants, combinational)
//   - butterfly       (one compute unit: 4 multipliers + 4 adders)
//   - fsm_controller  (sequences 12 butterfly operations across 3 stages)
//
// DATA FLOW PER BUTTERFLY OPERATION (5 clock cycles):
//
//   Cycle 1 (READ):    FSM drives addr_a, addr_b → reg_file outputs A,B as wires
//   Cycle 2 (LATCH):   latch_en asserted → Ar,Ai,Br,Bi,Wr,Wi captured in regs
//   Cycle 3 (COMPUTE): butterfly computes T=W*B → Tr,Ti registered
//   Cycle 4 (COMPUTE): butterfly computes P=A+T, Q=A-T → Pr,Pi,Qr,Qi registered
//   Cycle 5 (WRITE):   FSM asserts we_a, we_b → P,Q written to mem[]
//
// USAGE:
//   1. Load input samples into reg_file before asserting start.
//      Use the load_* ports: drive load_we=1, load_addr=0..7, load_data each cycle.
//      Samples must be loaded in BIT-REVERSED order (see README).
//   2. Pulse start=1 for one cycle.
//   3. Wait for done=1 (asserted for one cycle, ~60 clock cycles later).
//   4. Read results from reg_file via the result_* ports.

module fft_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,          // pulse to begin FFT computation

    // Sample loading interface (load samples before start)
    input  wire        load_we,        // write enable for loading samples
    input  wire [2:0]  load_addr,      // which sample slot to write (0..7)
    input  wire signed [15:0] load_dr, // sample real part
    input  wire signed [15:0] load_di, // sample imaginary part

    // Result readout interface (read after done)
    input  wire [2:0]  result_addr,    // which output bin to read (0..7)
    output wire signed [15:0] result_r, // X[k] real part
    output wire signed [15:0] result_i, // X[k] imaginary part

    output wire        done            // pulses high for one cycle when FFT is complete
);

    // ---------------------------------------------------------------
    // Internal wires between modules
    // ---------------------------------------------------------------

    // FSM → reg_file
    wire [2:0]  fsm_addr_a, fsm_addr_b;
    wire        fsm_we_a,   fsm_we_b;

    // FSM → twiddle ROM
    wire [1:0]  twiddle_k;

    // FSM → butterfly latch enable
    wire        latch_en;

    // reg_file → butterfly input latches (raw wires from memory read)
    wire signed [15:0] raw_ar, raw_ai;   // port A output (top sample)
    wire signed [15:0] raw_br, raw_bi;   // port B output (bottom sample)

    // twiddle_rom → butterfly
    wire signed [15:0] Wr, Wi;

    // Butterfly input latches (Ar,Ai,Br,Bi captured from raw on latch_en)
    reg signed [15:0] Ar, Ai, Br, Bi;
    reg signed [15:0] Wr_lat, Wi_lat;

    // Butterfly pipeline registers
    reg signed [15:0] Tr, Ti;           // result of W*B (truncated)
    reg signed [15:0] Pr, Pi, Qr, Qi;  // final outputs

    // Butterfly combinational outputs (before registering)
    wire signed [31:0] Tr_full_w = Wr_lat * Br - Wi_lat * Bi;
    wire signed [31:0] Ti_full_w = Wr_lat * Bi + Wi_lat * Br;

    // ---------------------------------------------------------------
    // Mux: reg_file port A address
    //   During loading: use load_addr
    //   During FFT:     use fsm_addr_a
    //   During readout: use result_addr
    // We use a simple priority: load_we wins, else FSM drives.
    // Result readout always uses a separate dedicated port (port B when idle).
    // ---------------------------------------------------------------
    wire [2:0]  rf_addr_a  = load_we ? load_addr  : fsm_addr_a;
    wire [15:0] rf_wdata_ar = load_we ? load_dr    : Pr;
    wire [15:0] rf_wdata_ai = load_we ? load_di    : Pi;
    wire        rf_we_a     = load_we ? 1'b1       : fsm_we_a;

    wire [2:0]  rf_addr_b  = (fsm_we_b || done) ? fsm_addr_b : result_addr;
    wire [15:0] rf_wdata_br = Qr;
    wire [15:0] rf_wdata_bi = Qi;
    wire        rf_we_b     = fsm_we_b;

    // ---------------------------------------------------------------
    // reg_file instantiation
    // ---------------------------------------------------------------
    reg_file u_reg_file (
        .clk      (clk),
        .addr_a   (rf_addr_a),
        .wdata_ar (rf_wdata_ar),
        .wdata_ai (rf_wdata_ai),
        .we_a     (rf_we_a),
        .rdata_ar (raw_ar),
        .rdata_ai (raw_ai),
        .addr_b   (rf_addr_b),
        .wdata_br (rf_wdata_br),
        .wdata_bi (rf_wdata_bi),
        .we_b     (rf_we_b),
        .rdata_br (raw_br),
        .rdata_bi (raw_bi)
    );

    assign result_r = raw_br;
    assign result_i = raw_bi;

    // ---------------------------------------------------------------
    // twiddle_rom instantiation
    // ---------------------------------------------------------------
    twiddle_rom u_twiddle (
        .k  (twiddle_k),
        .Wr (Wr),
        .Wi (Wi)
    );

    // ---------------------------------------------------------------
    // FSM controller instantiation
    // ---------------------------------------------------------------
    fsm_controller u_fsm (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (start),
        .addr_a    (fsm_addr_a),
        .addr_b    (fsm_addr_b),
        .we_a      (fsm_we_a),
        .we_b      (fsm_we_b),
        .twiddle_k (twiddle_k),
        .latch_en  (latch_en),
        .done      (done)
    );

    // ---------------------------------------------------------------
    // Butterfly pipeline
    //
    // Stage 1 (LATCH cycle): capture A, B, W from memory/ROM
    // Stage 2 (COMPUTE cycle 1): compute T = W*B
    // Stage 3 (COMPUTE cycle 2): compute P = A+T, Q = A-T
    // Stage 4 (WRITE cycle): FSM writes P,Q back to reg_file
    // ---------------------------------------------------------------
    always @(posedge clk) begin
        // Stage 1: latch inputs when FSM says so
        if (latch_en) begin
            Ar     <= raw_ar;
            Ai     <= raw_ai;
            Br     <= raw_br;
            Bi     <= raw_bi;
            Wr_lat <= Wr;
            Wi_lat <= Wi;
        end

        // Stage 2: register the multiply result (truncated to Q1.15)
        Tr <= Tr_full_w[30:15];
        Ti <= Ti_full_w[30:15];

        // Stage 3: register the add/subtract results
        Pr <= Ar + Tr;
        Pi <= Ai + Ti;
        Qr <= Ar - Tr;
        Qi <= Ai - Ti;
    end

endmodule
