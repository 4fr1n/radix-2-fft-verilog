// butterfly.v
// Computes one butterfly operation: P = A + W*B,  Q = A - W*B
// All values are complex, represented as (real, imag) pairs in Q1.15 format.
//
// Q1.15 format: 1 sign bit + 15 fractional bits.
//   32767 ≈  1.0
//  -32768 ≈ -1.0
//
// The multiply step produces a 32-bit result to preserve precision.
// We truncate back to 16 bits by taking bits [30:15] (equivalent to dividing by 2^15).
//
// One butterfly costs: 4 DSP48 slices (the 4 multiplications)
//                    + 4 adder/subtractor units (the P and Q outputs)
 
module butterfly (
    input  wire signed [15:0] Ar, Ai,   // top input A: real and imaginary
    input  wire signed [15:0] Br, Bi,   // bottom input B: real and imaginary
    input  wire signed [15:0] Wr, Wi,   // twiddle factor W: real and imaginary
    output wire signed [15:0] Pr, Pi,   // top output    P = A + W*B
    output wire signed [15:0] Qr, Qi    // bottom output Q = A - W*B
);
 
    // ---------------------------------------------------------------
    // Step 1: complex multiply T = W * B
    //
    //   (Wr + j*Wi) * (Br + j*Bi)
    //   = Wr*Br - Wi*Bi  +  j*(Wr*Bi + Wi*Br)
    //
    // Each product is 16x16 = 32 bits. We keep full precision here.
    // ---------------------------------------------------------------
    wire signed [31:0] Tr_full = (Wr * Br) - (Wi * Bi);
    wire signed [31:0] Ti_full = (Wr * Bi) + (Wi * Br);
 
    // Truncate back to Q1.15: drop the lower 15 fractional bits.
    // bit[31] is the extra sign bit (redundant), bit[30] is the true sign,
    // bits[30:15] give us the Q1.15 result.
    wire signed [15:0] Tr = Tr_full[30:15];
    wire signed [15:0] Ti = Ti_full[30:15];
 
    // ---------------------------------------------------------------
    // Step 2: butterfly add and subtract
    //
    //   P = A + T   (top output)
    //   Q = A - T   (bottom output)
    //
    // This is where the "butterfly wings" come from — A fans out to
    // both a + and a - unit, and T (computed once) feeds both.
    // ---------------------------------------------------------------
    assign Pr = Ar + Tr;
    assign Pi = Ai + Ti;
    assign Qr = Ar - Tr;
    assign Qi = Ai - Ti;
 
endmodule
