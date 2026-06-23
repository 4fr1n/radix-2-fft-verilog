// twiddle_rom.v
// Precomputed twiddle factors W^k = e^{-j*2*pi*k/N} for N=8, k=0..3
//
// We only need k=0..3 (N/2 = 4 values) because:
//   W^{k + N/2} = -W^k
// The negative is provided for free by the butterfly's subtraction path.
//
// Values are in Q1.15 fixed-point format:
//   real_value = register_value / 32768.0
//
// This module is PURELY COMBINATIONAL — no flip-flops, no clock.
// The synthesizer implements it as a multiplexer of hardwired constants.
// Cost: zero flip-flops, a handful of LUTs for the mux.
//
//   k  |  cos(-2*pi*k/8)  |  sin(-2*pi*k/8)  |  Wr     |  Wi
//   ---+------------------+------------------+---------+---------
//   0  |   1.0000         |   0.0000         |  32767  |      0
//   1  |   0.7071         |  -0.7071         |  23170  | -23170
//   2  |   0.0000         |  -1.0000         |      0  | -32767
//   3  |  -0.7071         |  -0.7071         | -23170  | -23170

module twiddle_rom (
    input  wire [1:0]        k,    // twiddle index: 0, 1, 2, or 3
    output reg  signed [15:0] Wr,  // real part of W^k
    output reg  signed [15:0] Wi   // imaginary part of W^k
);

    always @(*) begin
        case (k)
            2'd0: begin Wr =  32767; Wi =      0; end   // W^0 = (1, 0)
            2'd1: begin Wr =  23170; Wi = -23170; end   // W^1 = (0.707, -0.707)
            2'd2: begin Wr =      0; Wi = -32767; end   // W^2 = (0, -1)
            2'd3: begin Wr = -23170; Wi = -23170; end   // W^3 = (-0.707, -0.707)
            default: begin Wr = 0; Wi = 0; end
        endcase
    end

endmodule
