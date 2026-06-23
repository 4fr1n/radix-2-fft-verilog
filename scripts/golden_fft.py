#!/usr/bin/env python3
"""
golden_fft.py
Computes the reference 8-point FFT output using numpy.
Run this first to get expected values, then compare against Verilog simulation.
"""

import numpy as np

# Input signal
x = np.array([1, 2, 3, 4, 4, 3, 2, 1], dtype=float)

print("=== Input samples ===")
for i, v in enumerate(x):
    print(f"  x[{i}] = {v}")

print(f"\nSum of all inputs = {x.sum()} (should equal X[0] real part)")

# Full numpy FFT (reference)
X = np.fft.fft(x)

print("\n=== FFT Output X[k] (numpy reference) ===")
print(f"{'k':>3}  {'real':>12}  {'imag':>12}  {'magnitude':>12}")
print("-" * 50)
for k, Xk in enumerate(X):
    print(f"{k:>3}  {Xk.real:>12.4f}  {Xk.imag:>12.4f}  {abs(Xk):>12.4f}")

# Show bit-reversal
print("\n=== Bit-reversal for N=8 (input loading order) ===")
print(f"{'addr':>6}  {'x[n] loaded':>12}  {'value':>8}")
print("-" * 35)
N = 8
nbits = int(np.log2(N))
for addr in range(N):
    # bit-reverse addr
    br = int(f"{addr:0{nbits}b}"[::-1], 2)
    print(f"  mem[{addr}]  =  x[{br}]  =  {int(x[br]):>6}")

# Twiddle factors
print("\n=== Twiddle factors W^k = e^{-j*2*pi*k/8} ===")
print(f"{'k':>3}  {'Wr (float)':>12}  {'Wi (float)':>12}  {'Wr Q1.15':>10}  {'Wi Q1.15':>10}")
print("-" * 60)
for k in range(N//2):
    w = np.exp(-1j * 2 * np.pi * k / N)
    wr_q = int(round(w.real * 32767))
    wi_q = int(round(w.imag * 32767))
    print(f"  {k}  {w.real:>12.6f}  {w.imag:>12.6f}  {wr_q:>10}  {wi_q:>10}")

# Stage-by-stage trace
print("\n=== Stage-by-stage register state ===")
mem = np.zeros(8, dtype=complex)

# Load in bit-reversed order
for addr in range(N):
    br = int(f"{addr:0{nbits}b}"[::-1], 2)
    mem[addr] = x[br]

print("After bit-reversal load:")
for i, v in enumerate(mem):
    print(f"  mem[{i}] = {v.real:+.3f} {v.imag:+.3f}j")

def do_stage(mem, stage):
    distance = 2 ** (stage - 1)
    group_size = 2 * distance
    num_groups = N // group_size
    mem = mem.copy()
    print(f"\nAfter Stage {stage} (distance={distance}):")
    for group in range(num_groups):
        for pos in range(distance):
            addr_top = group * group_size + pos
            addr_bot = addr_top + distance
            twiddle_k = pos * (N // 2 // distance)
            W = np.exp(-1j * 2 * np.pi * twiddle_k / N)
            A = mem[addr_top]
            B = mem[addr_bot]
            T = W * B
            mem[addr_top] = A + T
            mem[addr_bot] = A - T
    for i, v in enumerate(mem):
        print(f"  mem[{i}] = {v.real:+8.3f} {v.imag:+8.3f}j")
    return mem

mem = do_stage(mem, 1)
mem = do_stage(mem, 2)
mem = do_stage(mem, 3)

print("\n=== Verification: our manual FFT vs numpy ===")
all_ok = True
for k in range(N):
    our  = mem[k]
    ref  = X[k]
    ok   = abs(our - ref) < 0.01
    flag = "OK" if ok else "MISMATCH"
    print(f"  X[{k}]: ours={our.real:+8.3f}{our.imag:+8.3f}j  "
          f"numpy={ref.real:+8.3f}{ref.imag:+8.3f}j  [{flag}]")
    if not ok:
        all_ok = False

print(f"\n{'All bins match!' if all_ok else 'ERRORS FOUND'}")
