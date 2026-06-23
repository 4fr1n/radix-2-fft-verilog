// reg_file.v
// Dual-port register file: 8 complex samples (real + imag), 16 bits each.
// Total: 16 registers of 16 bits = 256 flip-flops.
//
// WHY DUAL-PORT:
//   Each butterfly needs to read TWO addresses simultaneously in one clock
//   cycle (addr_top for A, addr_bot for B). A single-port file can only
//   read one address per cycle. Dual-port solves this.
//
// PORTS:
//   Port A — reads/writes mem[addr_a]   (used for addr_top, input A)
//   Port B — reads/writes mem[addr_b]   (used for addr_bot, input B)
//
// Both ports can read simultaneously every clock cycle.
// Write is controlled by we_a and we_b independently.
//
// Read-during-write behaviour: write takes effect on the NEXT cycle.
// (This is standard synchronous RAM behaviour — new data appears one
//  cycle after we is asserted, which is fine because our FSM writes
//  in WRITE state and reads in READ state two states later.)
//
// This register file holds:
//   - Input samples x[n] before computation starts
//   - Intermediate partial DFT results between stages
//   - Final DFT output X[k] after all 3 stages complete
// Same 16 physical flip-flops, three different logical meanings over time.

module reg_file (
    input  wire        clk,

    // Port A (top address — used for addr_top / input A / output P)
    input  wire [2:0]  addr_a,
    input  wire signed [15:0] wdata_ar,   // write data: real part
    input  wire signed [15:0] wdata_ai,   // write data: imag part
    input  wire        we_a,              // write enable
    output reg  signed [15:0] rdata_ar,   // read data: real part
    output reg  signed [15:0] rdata_ai,   // read data: imag part

    // Port B (bottom address — used for addr_bot / input B / output Q)
    input  wire [2:0]  addr_b,
    input  wire signed [15:0] wdata_br,
    input  wire signed [15:0] wdata_bi,
    input  wire        we_b,
    output reg  signed [15:0] rdata_br,
    output reg  signed [15:0] rdata_bi
);

    // The 16 registers: 8 real + 8 imaginary
    reg signed [15:0] mem_r [0:7];
    reg signed [15:0] mem_i [0:7];

    // Initialise to zero (for simulation)
    integer idx;
    initial begin
        for (idx = 0; idx < 8; idx = idx + 1) begin
            mem_r[idx] = 0;
            mem_i[idx] = 0;
        end
    end

    always @(posedge clk) begin
        // Port A: read (always)
        rdata_ar <= mem_r[addr_a];
        rdata_ai <= mem_i[addr_a];

        // Port B: read (always)
        rdata_br <= mem_r[addr_b];
        rdata_bi <= mem_i[addr_b];

        // Port A: write (when enabled)
        if (we_a) begin
            mem_r[addr_a] <= wdata_ar;
            mem_i[addr_a] <= wdata_ai;
        end

        // Port B: write (when enabled)
        if (we_b) begin
            mem_r[addr_b] <= wdata_br;
            mem_i[addr_b] <= wdata_bi;
        end
    end

endmodule
