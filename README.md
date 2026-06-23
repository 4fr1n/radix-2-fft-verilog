# 8-Point FFT Hardware Accelerator

A fixed-point, iterative, in-place Fast Fourier Transform (FFT) accelerator implemented in Verilog, targeting Xilinx Artix-7 FPGAs. The design computes an 8-point Decimation-in-Time (DIT) FFT using a single pipelined butterfly unit, reused across all computation stages under the control of a finite state machine.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Mathematical Foundation — The DFT](#2-mathematical-foundation--the-dft)
3. [Algorithm — The Cooley-Tukey Decomposition](#3-algorithm--the-cooley-tukey-decomposition)
4. [The Butterfly Compute Unit](#4-the-butterfly-compute-unit)
5. [Input Ordering — Bit-Reversal Permutation](#5-input-ordering--bit-reversal-permutation)
6. [Hardware Architecture](#6-hardware-architecture)
   - 6.1 [Sample Register File](#61-sample-register-file)
   - 6.2 [Twiddle Factor ROM](#62-twiddle-factor-rom)
   - 6.3 [Butterfly Unit](#63-butterfly-unit)
   - 6.4 [FSM Controller](#64-fsm-controller)
7. [Computation Stages](#7-computation-stages)
8. [Register State at Each Stage](#8-register-state-at-each-stage)
9. [Frequency Bins — Interpretation of Output](#9-frequency-bins--interpretation-of-output)
10. [Address Generation](#10-address-generation)
11. [In-Place Correctness — No Write Conflicts](#11-in-place-correctness--no-write-conflicts)
12. [Timing — The 5-Cycle Butterfly Sequence](#12-timing--the-5-cycle-butterfly-sequence)
13. [Worked Numerical Example](#13-worked-numerical-example)
14. [Resource Utilisation](#14-resource-utilisation)
15. [Repository Structure and Build Instructions](#15-repository-structure-and-build-instructions)

---

## 1. Overview

The Discrete Fourier Transform (DFT) converts N time-domain samples into N frequency-domain coefficients, revealing the spectral content of a signal. The naive DFT requires O(N²) complex multiplications. For N = 1024, this amounts to approximately one million multiplications per frame — a prohibitive cost for real-time embedded hardware.

The Fast Fourier Transform (FFT) computes the identical result in O(N log₂N) multiplications by exploiting the symmetry of the DFT's complex exponential basis functions. For N = 1024, this reduces the multiply count to approximately 10,000 — a 100× improvement in computational complexity.

This project implements an N = 8 FFT accelerator with the following design properties:

| Property | Choice | Rationale |
|---|---|---|
| Transform length | N = 8 | Tractable for manual verification; architecture scales directly to N = 1024 |
| Arithmetic | Fixed-point, Q1.15 | Avoids floating-point overhead; maps directly to DSP48 slices |
| Architecture | Iterative (single butterfly) | Minimal area; maximises resource reuse |
| Memory | In-place (results overwrite inputs) | Eliminates dedicated output buffers |
| Target | Xilinx Artix-7 FPGA | Widely available; well-supported open-source toolchain |

For N = 8, log₂8 = 3 stages are required, each consisting of N/2 = 4 butterfly operations, yielding 12 butterfly operations in total. At a 100 MHz clock, the complete transform completes in 600 ns.

---

## 2. Mathematical Foundation — The DFT

The DFT of a length-N sequence x[n] is defined as:

```
X[k] = Σ_{n=0}^{N-1}  x[n] · W_N^{kn},    k = 0, 1, ..., N-1
```

where:
- `W_N = e^{−j·2π/N}` is the primitive N-th root of unity (the twiddle factor base)
- `k` indexes the output frequency bin
- `n` indexes the input time-domain sample

For N = 8, the twiddle factors `W_8^k` for k = 0, 1, 2, 3 are:

| k | W⁰ᵏ (real) | W⁰ᵏ (imag) | Interpretation |
|---|---|---|---|
| 0 | 1.000 | 0.000 | 0° rotation (identity) |
| 1 | 0.707 | −0.707 | −45° clockwise rotation |
| 2 | 0.000 | −1.000 | −90° clockwise rotation |
| 3 | −0.707 | −0.707 | −135° clockwise rotation |

Multiplication by `W^k` effects a clockwise rotation of k × 45° in the complex plane. This geometric interpretation underlies the meaning of each stage of the FFT butterfly.

A fundamental symmetry reduces the number of distinct twiddle values to N/2:

```
W^{k + N/2} = −W^k
```

Therefore `W^4 = −W^0`, `W^5 = −W^1`, and so on. The negative values are obtained for free from the butterfly's subtraction output; only W^0 through W^3 must be stored.

---

## 3. Algorithm — The Cooley-Tukey Decomposition

The Cooley-Tukey DIT-FFT recursively partitions the input sequence by even and odd indices:

```
Even-indexed samples:  x[0], x[2], x[4], x[6]
Odd-indexed samples:   x[1], x[3], x[5], x[7]
```

Let E[k] and O[k] denote the N/2-point DFTs of the even and odd subsequences, respectively. The full N-point DFT is then reconstructed as:

```
X[k]     = E[k] + W_N^k · O[k],   k = 0, 1, 2, 3
X[k + 4] = E[k] − W_N^k · O[k],   k = 0, 1, 2, 3
```

The product `W_N^k · O[k]` is computed once and contributes to two outputs — the addition produces X[k] and the subtraction produces X[k+4]. This is the butterfly operation, and it is the source of the FFT's efficiency.

The recursion is applied identically to E[k] and O[k], ultimately reducing each sub-problem to a 2-point DFT at the leaves of the computation tree:

```
{ x[0], x[1], x[2], x[3], x[4], x[5], x[6], x[7] }
            /                        \
  { x[0], x[2], x[4], x[6] }    { x[1], x[3], x[5], x[7] }
         /          \                    /           \
  { x[0], x[4] }  { x[2], x[6] }  { x[1], x[5] }  { x[3], x[7] }
```

Reading the leaf nodes left-to-right yields the required memory loading order:

```
x[0],  x[4],  x[2],  x[6],  x[1],  x[5],  x[3],  x[7]
```

This reordering is the bit-reversal permutation, described in Section 5.

---

## 4. The Butterfly Compute Unit

Every computation in the FFT reduces to the following two-input, two-output operation:

```
P = A + W·B      (addition output)
Q = A − W·B      (subtraction output)
```

where A and B are complex inputs drawn from the register file and W is a twiddle factor from ROM.

The complex multiply `T = W·B` is expanded into real arithmetic as follows:

```
Given:  A = (Ar + j·Ai),  B = (Br + j·Bi),  W = (Wr + j·Wi)

Tr = Wr·Br − Wi·Bi       (real part of W·B)
Ti = Wr·Bi + Wi·Br       (imaginary part of W·B)

Pr = Ar + Tr,  Pi = Ai + Ti     (top output P = A + W·B)
Qr = Ar − Tr,  Qi = Ai − Ti     (bottom output Q = A − W·B)
```

This requires four real multiplications and six additions or subtractions, mapping precisely to four DSP48E1 slices on the Artix-7 fabric.

The name "butterfly" derives from the cross-connecting signal flow of the operation when drawn schematically:

```
A ─────────────────────────────(+)──── P = A + W·B
                              /
B ────[× W]──── T = W·B ─────
                              \
A ─────────────────────────────(−)──── Q = A − W·B
```

**Fixed-point precision note.** Internal multiply products are computed at full 32-bit precision to prevent intermediate overflow. The result is truncated back to 16 bits by discarding the lower 15 bits (equivalent to a right shift by 15, consistent with Q1.15 arithmetic). Signal growth of up to √2 per stage implies a worst-case amplitude growth of (√2)³ ≈ 2.83 across three stages. A guard bit right-shift after each stage is recommended when processing signals that occupy the full dynamic range.

---

## 5. Input Ordering — Bit-Reversal Permutation

Samples must be loaded into memory in bit-reversed order rather than natural order. This requirement arises directly from the structure of the Cooley-Tukey recursion: each level of the recursion partitions the index set according to successive bits of the sample index, reading from LSB to MSB. The leaf position in the recursion tree is therefore the bit-reversal of the sample index.

The complete bit-reversal table for N = 8 (3-bit indices) is:

| Sample | Natural index | Binary | Reversed | Memory address |
|---|---|---|---|---|
| x[0] | 0 | 000 | 000 | 0 |
| x[1] | 1 | 001 | 100 | 4 |
| x[2] | 2 | 010 | 010 | 2 |
| x[3] | 3 | 011 | 110 | 6 |
| x[4] | 4 | 100 | 001 | 1 |
| x[5] | 5 | 101 | 101 | 5 |
| x[6] | 6 | 110 | 011 | 3 |
| x[7] | 7 | 111 | 111 | 7 |

The resulting load order is:

```
mem[0]=x[0], mem[1]=x[4], mem[2]=x[2], mem[3]=x[6],
mem[4]=x[1], mem[5]=x[5], mem[6]=x[3], mem[7]=x[7]
```

**Hardware cost: zero.** The bit-reversal is implemented as a static wire permutation on the address bus at elaboration time. No logic gates, no flip-flops, and no clock cycles are consumed:

```verilog
wire [2:0] addr;           // natural address
wire [2:0] addr_br = {addr[0], addr[1], addr[2]};  // bit-reversed — wires only
```

The synthesiser physically routes these connections in reverse order. No combinational logic is inferred.

---

## 6. Hardware Architecture

### 6.1 Sample Register File

The accelerator maintains 8 complex samples, each represented as a 16-bit real part and a 16-bit imaginary part, for a total of 16 registers (256 flip-flops):

```verilog
reg signed [15:0] mem_r [0:7];   // real parts, samples 0..7
reg signed [15:0] mem_i [0:7];   // imaginary parts, samples 0..7
```

The same physical registers serve three sequential roles:

1. **Before computation:** hold the bit-reversed input samples loaded by the host
2. **During computation:** hold intermediate partial DFT results after each stage
3. **After computation:** hold the final DFT output bins X[0]..X[7]

This is referred to as in-place computation. No additional output buffer is required.

Each butterfly operation reads from two addresses and writes back to those same two addresses within a single stage. Because no two butterflies within a given stage share any address (see Section 11), writes never corrupt values required by subsequent butterflies in the same stage.

The register file is implemented as a **dual-port** structure, permitting simultaneous reads from `addr_top` and `addr_bot` in the same clock cycle:

```verilog
module reg_file (
    input  wire        clk,
    input  wire [2:0]  addr_a, addr_b,
    input  wire [15:0] wdata_ar, wdata_ai,
    input  wire [15:0] wdata_br, wdata_bi,
    input  wire        we_a, we_b,
    output reg  [15:0] rdata_ar, rdata_ai,
    output reg  [15:0] rdata_br, rdata_bi
);
    reg signed [15:0] mem_r [0:7];
    reg signed [15:0] mem_i [0:7];

    always @(posedge clk) begin
        rdata_ar <= mem_r[addr_a];  rdata_ai <= mem_i[addr_a];
        rdata_br <= mem_r[addr_b];  rdata_bi <= mem_i[addr_b];
        if (we_a) begin mem_r[addr_a] <= wdata_ar; mem_i[addr_a] <= wdata_ai; end
        if (we_b) begin mem_r[addr_b] <= wdata_br; mem_i[addr_b] <= wdata_bi; end
    end
endmodule
```

### 6.2 Twiddle Factor ROM

The four distinct twiddle factors W^0 through W^3 are mathematical constants, fixed at design time. They are encoded in Q1.15 fixed-point format (1 sign bit, 15 fractional bits; the value 32767 represents ≈1.0) and synthesise as a combinational multiplexer of constants — consuming zero flip-flops:

| k | Wr (Q1.15) | Wi (Q1.15) | Floating-point value |
|---|---|---|---|
| 0 | 32767 | 0 | (1.000, 0.000) |
| 1 | 23170 | −23170 | (0.707, −0.707) |
| 2 | 0 | −32767 | (0.000, −1.000) |
| 3 | −23170 | −23170 | (−0.707, −0.707) |

```verilog
always @(*) begin
    case (twiddle_k)
        2'd0: begin Wr =  32767; Wi =      0; end
        2'd1: begin Wr =  23170; Wi = -23170; end
        2'd2: begin Wr =      0; Wi = -32767; end
        2'd3: begin Wr = -23170; Wi = -23170; end
    endcase
end
```

Only N/2 = 4 entries are required because `W^{k+N/2} = −W^k`; the negated values emerge from the butterfly subtraction output at no additional cost.

### 6.3 Butterfly Unit

The butterfly is a purely combinational module. It accepts the latched input values A, B, and W and produces outputs P and Q within the same clock cycle:

```verilog
module butterfly (
    input  wire signed [15:0] Ar, Ai,    // top input A
    input  wire signed [15:0] Br, Bi,    // bottom input B
    input  wire signed [15:0] Wr, Wi,    // twiddle factor W
    output wire signed [15:0] Pr, Pi,    // P = A + W·B
    output wire signed [15:0] Qr, Qi     // Q = A − W·B
);
    // Full-precision complex multiply (32-bit intermediate)
    wire signed [31:0] Tr_full = Wr*Br - Wi*Bi;
    wire signed [31:0] Ti_full = Wr*Bi + Wi*Br;

    // Truncate to Q1.15 (discard lower 15 fractional bits)
    wire signed [15:0] Tr = Tr_full[30:15];
    wire signed [15:0] Ti = Ti_full[30:15];

    assign Pr = Ar + Tr;    assign Pi = Ai + Ti;
    assign Qr = Ar - Tr;    assign Qi = Ai - Ti;
endmodule
```

Estimated resource cost: 4 DSP48E1 slices (one per real multiplication) and approximately 200 LUTs for the adders and subtractors.

### 6.4 FSM Controller

The finite state machine sequences all 12 butterfly operations across the three computation stages. It maintains the following state registers:

| Register | Width | Description |
|---|---|---|
| `stage` | 2 bits | Current stage: 1, 2, or 3 |
| `bfly_idx` | 2 bits | Butterfly index within stage: 0–3 |
| `addr_top` | 3 bits | Register file address for input A / output P |
| `addr_bot` | 3 bits | Register file address for input B / output Q |
| `twiddle_k` | 2 bits | ROM address for twiddle factor W |
| `state` | 3 bits | FSM state encoding (see below) |
| `we_top` | 1 bit | Write enable for addr_top |
| `we_bot` | 1 bit | Write enable for addr_bot |

The FSM cycles through six states per butterfly operation:

```
IDLE → READ → LATCH → COMPUTE → WRITE → NEXT → (IDLE or READ)
```

State transitions and their hardware actions are described in Section 12.

---

## 7. Computation Stages

For N = 8, three stages are required (log₂8 = 3). Each stage executes four butterfly operations and corresponds to one level of the Cooley-Tukey recursion tree. The "distance" between the two addresses accessed by each butterfly doubles at every stage.

| Stage | Distance | Partial DFT size | Twiddle factors used | Address pairs |
|---|---|---|---|---|
| 1 | 1 | 2-point | W^0 only | (0,1), (2,3), (4,5), (6,7) |
| 2 | 2 | 4-point | W^0, W^2 | (0,2), (1,3), (4,6), (5,7) |
| 3 | 4 | 8-point (final) | W^0, W^1, W^2, W^3 | (0,4), (1,5), (2,6), (3,7) |

**Stage 1** (distance = 1) computes independent 2-point DFTs on adjacent pairs of bit-reversed input samples. Because all Stage 1 twiddle factors are W^0 = (1, 0), no multiplication occurs — the butterfly reduces to a pure addition and subtraction.

**Stage 2** (distance = 2) combines pairs of 2-point DFT results into 4-point DFTs. Upon completion, `mem[0..3]` holds E[0..3], the 4-point DFT of the even-indexed input samples; `mem[4..7]` holds O[0..3], the 4-point DFT of the odd-indexed samples.

**Stage 3** (distance = 4) combines E[k] and O[k] according to the top-level Cooley-Tukey relation to produce the final 8-point DFT output X[0]..X[7] in natural (non-reversed) order.

In general, the distance at stage s is:

```
distance = 2^(s − 1)
```

---

## 8. Register State at Each Stage

The following traces the contents of all eight registers for the example input x = [1, 2, 3, 4, 4, 3, 2, 1].

**After bit-reversal load:**

```
mem[0]=1  mem[1]=4  mem[2]=3  mem[3]=2
mem[4]=2  mem[5]=3  mem[6]=4  mem[7]=1
```

**After Stage 1** — each register holds one bin of a 2-point DFT:

```
mem[0] = x[0] + x[4] =  5    mem[1] = x[0] − x[4] = −3
mem[2] = x[2] + x[6] =  5    mem[3] = x[2] − x[6] =  1
mem[4] = x[1] + x[5] =  5    mem[5] = x[1] − x[5] = −1
mem[6] = x[3] + x[7] =  5    mem[7] = x[3] − x[7] =  3
```

**After Stage 2** — registers 0..3 hold E[0..3]; registers 4..7 hold O[0..3]:

```
mem[0] = E[0] = (10,  0)    mem[2] = E[2] = ( 0,  0)
mem[1] = E[1] = (−3, −1)    mem[3] = E[3] = (−3, +1)
mem[4] = O[0] = (10,  0)    mem[6] = O[2] = ( 0,  0)
mem[5] = O[1] = (−1, −3)    mem[7] = O[3] = (−1, +3)
```

**After Stage 3** — final DFT output X[0]..X[7]:

```
mem[0] = X[0] = (20,    0  )    mem[4] = X[4] = ( 0,    0  )
mem[1] = X[1] ≈ (−5.83, −2.41)  mem[5] = X[5] ≈ (−0.17, +0.41)
mem[2] = X[2] = ( 0,    0  )    mem[6] = X[6] = ( 0,    0  )
mem[3] = X[3] ≈ (−0.17, −0.41)  mem[7] = X[7] ≈ (−5.83, +2.41)
```

Verification: X[0] = 20 equals the sum of all input samples (1+2+3+4+4+3+2+1 = 20). ✓

---

## 9. Frequency Bins — Interpretation of Output

Each output register X[k] corresponds to a specific frequency component of the input signal. For a signal sampled at rate fₛ, bin k represents the frequency component at k·fₛ/N:

| Bin k | Frequency | Description |
|---|---|---|
| 0 | 0 Hz | DC component (mean of input) |
| 1 | fₛ/8 | Lowest non-DC frequency |
| 2 | fₛ/4 | — |
| 3 | 3fₛ/8 | — |
| 4 | fₛ/2 | Nyquist frequency (highest representable) |
| 5 | 5fₛ/8 | Complex conjugate mirror of bin 3 |
| 6 | 3fₛ/4 | Complex conjugate mirror of bin 2 |
| 7 | 7fₛ/8 | Complex conjugate mirror of bin 1 |

For real-valued inputs, bins N/2+1 through N−1 are complex conjugates of bins N/2−1 through 1, and contain no additional information beyond what bins 0 through N/2 already capture.

The term "bin 0 of a 2-point DFT" encountered in Stage 1 intermediate results denotes the DC component of a 2-point sub-transform — it is a partial result, not the final X[0] of the 8-point transform.

---

## 10. Address Generation

Given the stage index `s` (1, 2, or 3) and butterfly index `b` (0, 1, 2, or 3), the FSM computes the two register addresses and twiddle index as follows:

```
distance  = 2^(s − 1)        // 1, 2, or 4
group_sz  = 2 × distance     // 2, 4, or 8
group     = b / distance      // integer quotient
position  = b mod distance    // integer remainder

addr_top  = group × group_sz + position
addr_bot  = addr_top + distance
twiddle_k = position × (N/2 / distance)    // N/2 = 4 for N=8
```

The complete address lookup table for all 12 butterfly operations:

| Stage | BF | Dist | Group | Pos | addr_top | addr_bot | twiddle_k |
|---|---|---|---|---|---|---|---|
| 1 | 0 | 1 | 0 | 0 | 0 | 1 | 0 |
| 1 | 1 | 1 | 1 | 0 | 2 | 3 | 0 |
| 1 | 2 | 1 | 2 | 0 | 4 | 5 | 0 |
| 1 | 3 | 1 | 3 | 0 | 6 | 7 | 0 |
| 2 | 0 | 2 | 0 | 0 | 0 | 2 | 0 |
| 2 | 1 | 2 | 0 | 1 | 1 | 3 | 2 |
| 2 | 2 | 2 | 1 | 0 | 4 | 6 | 0 |
| 2 | 3 | 2 | 1 | 1 | 5 | 7 | 2 |
| 3 | 0 | 4 | 0 | 0 | 0 | 4 | 0 |
| 3 | 1 | 4 | 0 | 1 | 1 | 5 | 1 |
| 3 | 2 | 4 | 0 | 2 | 2 | 6 | 2 |
| 3 | 3 | 4 | 0 | 3 | 3 | 7 | 3 |

Because `distance` is always a power of two, the integer division reduces to a right-shift and the modulo reduces to a bitwise AND. The entire address computation is therefore purely combinational, requiring no multipliers and consuming zero clock cycles.

---

## 11. In-Place Correctness — No Write Conflicts

A correctness concern inherent to in-place computation is whether a butterfly's write-back to `mem[addr_top]` and `mem[addr_bot]` will corrupt values that a later butterfly in the same stage still requires as inputs.

This concern is eliminated by the following property: within any single stage, every register address appears in exactly one butterfly's address pair. Inspection of the address table confirms this:

```
Stage 1:  (0,1)  (2,3)  (4,5)  (6,7)   — disjoint, covering {0..7}
Stage 2:  (0,2)  (1,3)  (4,6)  (5,7)   — disjoint, covering {0..7}
Stage 3:  (0,4)  (1,5)  (2,6)  (3,7)   — disjoint, covering {0..7}
```

Once butterfly 0 in Stage 1 writes to `mem[0]` and `mem[1]`, no subsequent butterfly in Stage 1 accesses those addresses. The overwrite is unconditionally safe.

This is not coincidental — it is a consequence of the Cooley-Tukey algorithm's construction. The butterfly pairs form a perfect partition of the address space at every stage. Between stages, the FSM waits until all four butterflies of stage s complete before commencing stage s+1, ensuring that all Stage s outputs are stable before Stage s+1 reads begin.

---

## 12. Timing — The 5-Cycle Butterfly Sequence

Each butterfly operation occupies exactly five clock cycles. The five FSM states and their associated register-transfer actions are:

**Cycle 1 — READ**
The FSM presents `addr_top` and `addr_bot` on the register file address bus and presents `twiddle_k` to the ROM. The register file and ROM produce combinational output; nothing is latched.

**Cycle 2 — LATCH**
The combinational outputs from Cycle 1 are captured into dedicated input registers:
```
Ar, Ai ← mem_r[addr_top], mem_i[addr_top]
Br, Bi ← mem_r[addr_bot], mem_i[addr_bot]
Wr, Wi ← ROM[twiddle_k]
```
The address bus is released; the FSM may begin computing the next address while the multiply proceeds.

**Cycle 3 — MULTIPLY**
The four DSP48 slices compute the complex product T = W·B at full 32-bit precision:
```
Tr_full = Wr·Br − Wi·Bi
Ti_full = Wr·Bi + Wi·Br
```
Results are latched into 32-bit intermediate registers `Tr`, `Ti`.

**Cycle 4 — ADD/SUBTRACT**
The adder units compute the butterfly outputs and latch results:
```
Pr = Ar + Tr,   Pi = Ai + Ti
Qr = Ar − Tr,   Qi = Ai − Ti
```

**Cycle 5 — WRITE BACK**
The FSM asserts `we_top` and `we_bot`, writing the butterfly results to the register file:
```
mem[addr_top] ← (Pr, Pi)
mem[addr_bot] ← (Qr, Qi)
```
The butterfly index `bfly_idx` is incremented. If `bfly_idx` reaches 4, `stage` is incremented. If all three stages are complete, the FSM asserts `done` and returns to IDLE.

The input registers introduced in Cycle 2 are necessary to prevent A and B from changing mid-computation: if the register file address were permitted to change before the multiply completed, glitches on the memory output would corrupt the result.

**Total latency:**

| Configuration | Butterfly count | Cycles | Latency at 100 MHz |
|---|---|---|---|
| N = 8 | 12 | 60 | 600 ns |
| N = 1024 | 5,120 | 25,600 | 256 μs |

---

## 13. Worked Numerical Example

**Input:** x = [1, 2, 3, 4, 4, 3, 2, 1]

**Step 0 — Bit-reversal load:**
```
mem[0]=1  mem[1]=4  mem[2]=3  mem[3]=2
mem[4]=2  mem[5]=3  mem[6]=4  mem[7]=1
```

**Stage 1** (all butterflies use W^0 = (1, 0)):
```
BF0: A=(1,0)  B=(4,0)  W=(1,0) → P=( 5,0)  Q=(−3,0) → mem[0]=( 5,0)  mem[1]=(−3,0)
BF1: A=(3,0)  B=(2,0)  W=(1,0) → P=( 5,0)  Q=( 1,0) → mem[2]=( 5,0)  mem[3]=( 1,0)
BF2: A=(2,0)  B=(3,0)  W=(1,0) → P=( 5,0)  Q=(−1,0) → mem[4]=( 5,0)  mem[5]=(−1,0)
BF3: A=(4,0)  B=(1,0)  W=(1,0) → P=( 5,0)  Q=( 3,0) → mem[6]=( 5,0)  mem[7]=( 3,0)
```

**Stage 2** (butterflies alternate W^0 and W^2):
```
BF0: (0,2) W^0=(1,0)
     A=(5,0) B=(5,0) T=(5,0)
     P=(10,0) Q=(0,0) → mem[0]=(10,0) mem[2]=(0,0)

BF1: (1,3) W^2=(0,−1)
     A=(−3,0) B=(1,0) T=(0·1−(−1)·0, 0·0+(−1)·1)=(0,−1)
     P=(−3,−1) Q=(−3,1) → mem[1]=(−3,−1) mem[3]=(−3,1)

BF2: (4,6) W^0=(1,0)
     A=(5,0) B=(5,0) T=(5,0)
     P=(10,0) Q=(0,0) → mem[4]=(10,0) mem[6]=(0,0)

BF3: (5,7) W^2=(0,−1)
     A=(−1,0) B=(3,0) T=(0,−3)
     P=(−1,−3) Q=(−1,3) → mem[5]=(−1,−3) mem[7]=(−1,3)
```

**Stage 3** (butterflies use W^0, W^1, W^2, W^3 sequentially):
```
BF0: (0,4) W^0=(1,0)
     A=(10,0) B=(10,0) T=(10,0)
     P=(20,0) Q=(0,0)
     → mem[0]=X[0]=(20,0)  mem[4]=X[4]=(0,0)

BF1: (1,5) W^1=(0.707,−0.707)
     A=(−3,−1) B=(−1,−3)
     Tr = 0.707·(−1) − (−0.707)·(−3) = −0.707 − 2.121 = −2.828
     Ti = 0.707·(−3) + (−0.707)·(−1) = −2.121 + 0.707 = −1.414
     P=(−3−2.828, −1−1.414)=(−5.828, −2.414)
     Q=(−3+2.828, −1+1.414)=(−0.172, +0.414)
     → mem[1]=X[1]≈(−5.83, −2.41)  mem[5]=X[5]≈(−0.17, +0.41)

BF2: (2,6) W^2=(0,−1)
     A=(0,0) B=(0,0) → P=(0,0) Q=(0,0)
     → mem[2]=X[2]=(0,0)  mem[6]=X[6]=(0,0)

BF3: (3,7) W^3=(−0.707,−0.707)
     A=(−3,1) B=(−1,3)
     Tr = (−0.707)·(−1) − (−0.707)·3 = 0.707 + 2.121 = 2.828
     Ti = (−0.707)·3 + (−0.707)·(−1) = −2.121 + 0.707 = −1.414
     P=(−3+2.828, 1−1.414)=(−0.172, −0.414)
     Q=(−3−2.828, 1+1.414)=(−5.828, +2.414)
     → mem[3]=X[3]≈(−0.17, −0.41)  mem[7]=X[7]≈(−5.83, +2.41)
```

**Final output:**

| Bin | Value (real, imag) | Magnitude | Notes |
|---|---|---|---|
| X[0] | (20.00, 0.00) | 20.00 | DC; equals sum of inputs ✓ |
| X[1] | (−5.83, −2.41) | 6.31 | — |
| X[2] | (0.00, 0.00) | 0.00 | — |
| X[3] | (−0.17, −0.41) | 0.44 | — |
| X[4] | (0.00, 0.00) | 0.00 | — |
| X[5] | (−0.17, +0.41) | 0.44 | Conjugate mirror of X[3] |
| X[6] | (0.00, 0.00) | 0.00 | Conjugate mirror of X[2] |
| X[7] | (−5.83, +2.41) | 6.31 | Conjugate mirror of X[1] |

---

## 14. Resource Utilisation

| Block | Registers | Width (bits) | Total bits |
|---|---|---|---|
| Sample memory (real) | 8 | 16 | 128 |
| Sample memory (imaginary) | 8 | 16 | 128 |
| Butterfly input latch A | 2 | 16 | 32 |
| Butterfly input latch B | 2 | 16 | 32 |
| Twiddle latch W | 2 | 16 | 32 |
| Butterfly multiply result | 2 | 32 | 64 |
| Butterfly output P | 2 | 16 | 32 |
| Butterfly output Q | 2 | 16 | 32 |
| FSM: stage | 1 | 2 | 2 |
| FSM: bfly_idx | 1 | 2 | 2 |
| FSM: addr_top | 1 | 3 | 3 |
| FSM: addr_bot | 1 | 3 | 3 |
| FSM: twiddle_k | 1 | 2 | 2 |
| FSM: state | 1 | 3 | 3 |
| FSM: write enables | 2 | 1 | 2 |
| **Total** | **~36** | — | **~539 bits** |

Twiddle ROM synthesises as combinational wiring: **0 flip-flops**.

The complete N = 8 design consumes approximately **539 flip-flops** on the target device. For reference, the smallest Xilinx Artix-7 (XC7A12T) provides 16,000 flip-flops; the design utilises less than 0.004% of available registers.

**Scaling to N = 1024:** Replace the 16-register file with a single 18 Kb block RAM (RAMB18E1). The twiddle ROM grows to 512 entries but continues to synthesise as LUT-based memory. The butterfly unit, FSM structure, and address generation logic require no modification.

---

## 15. Repository Structure and Build Instructions

```
fft-fir-accelerator/
├── rtl/
│   ├── fft/
│   │   ├── butterfly.v        Butterfly compute unit (4 DSP48 + adders)
│   │   ├── twiddle_rom.v      Hardwired twiddle constants W^0..W^(N/2−1)
│   │   ├── reg_file.v         Dual-port 16-register sample memory
│   │   ├── fsm_controller.v   Butterfly sequencer FSM
│   │   └── fft_top.v          Top-level integration
│   └── fir/
│       ├── fir_filter.v       Direct-form FIR (shift register + MAC)
│       └── coeffs.hex         Filter coefficients (generated by Python)
├── tb/
│   ├── tb_butterfly.v         Unit test: single butterfly operation
│   ├── tb_fft.v               Full 8-point FFT test against Python reference
│   └── tb_fir.v               FIR filter test
├── scripts/
│   ├── gen_twiddle.py         Generates twiddle_rom.v constants
│   ├── gen_coeffs.py          Generates FIR filter coefficients
│   └── golden_fft.py          Python reference FFT for testbench comparison
├── sim/
│   └── Makefile               Simulation targets (iverilog + vvp + gtkwave)
└── README.md
```

### Prerequisites

```bash
sudo apt install iverilog gtkwave
pip install numpy scipy
```

### Build Order

1. Generate twiddle constants:
   ```bash
   python3 scripts/gen_twiddle.py
   ```
2. Generate the Python golden reference output:
   ```bash
   python3 scripts/golden_fft.py
   ```
3. Implement and unit-test `butterfly.v`:
   ```bash
   iverilog -g2012 -o sim_butterfly rtl/fft/butterfly.v tb/tb_butterfly.v
   vvp sim_butterfly
   ```
4. Implement `reg_file.v` (dual-port register file).
5. Implement `fsm_controller.v`.
6. Integrate all modules in `fft_top.v`.
7. Run the full-system testbench:
   ```bash
   iverilog -g2012 -o sim_fft rtl/fft/*.v tb/tb_fft.v
   vvp sim_fft
   ```
8. Compare output bins against the Python golden model. All bins should match within fixed-point rounding tolerance (±1 LSB).

### Viewing Waveforms

```bash
gtkwave dump.vcd
```

### Scaling to N = 1024

The following modifications are sufficient to extend the design to a 1024-point FFT:

1. Set the parameter `N_LOG2 = 10` (10 stages, 512 butterfly operations per stage).
2. Replace `reg_file.v` with a BRAM instantiation (Xilinx primitive: `RAMB18E1`).
3. Extend the twiddle ROM to 512 entries — the ROM still synthesises as LUT-based memory.
4. All FSM loop bounds and address generation expressions update automatically from the `N_LOG2` parameter.

The butterfly unit, FSM architecture, and address generation logic require no further modification.

---

*This document was produced as part of the fft-fir-accelerator project.*
