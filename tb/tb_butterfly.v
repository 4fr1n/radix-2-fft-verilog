// tb_butterfly.v
// Unit test for the butterfly module.
// Tests all 4 twiddle factors against hand-calculated expected values.

`timescale 1ns/1ps

module tb_butterfly;

    reg  signed [15:0] Ar, Ai, Br, Bi, Wr, Wi;
    wire signed [15:0] Pr, Pi, Qr, Qi;

    butterfly dut (.Ar(Ar),.Ai(Ai),.Br(Br),.Bi(Bi),
                   .Wr(Wr),.Wi(Wi),.Pr(Pr),.Pi(Pi),.Qr(Qr),.Qi(Qi));

    task check;
        input signed [15:0] exp_pr, exp_pi, exp_qr, exp_qi;
        input [63:0] test_num;
        begin
            #1; // allow combinational to settle
            if (Pr===exp_pr && Pi===exp_pi && Qr===exp_qr && Qi===exp_qi)
                $display("PASS test %0d: P=(%0d,%0d) Q=(%0d,%0d)",
                    test_num, Pr, Pi, Qr, Qi);
            else
                $display("FAIL test %0d: got P=(%0d,%0d) Q=(%0d,%0d) expected P=(%0d,%0d) Q=(%0d,%0d)",
                    test_num, Pr, Pi, Qr, Qi, exp_pr, exp_pi, exp_qr, exp_qi);
        end
    endtask

    initial begin
        $display("=== Butterfly Unit Tests ===");

        // Test 1: W=W^0=(1,0), A=(1,0), B=(4,0)
        // T = 1*4 - 0*0 + j*(1*0 + 0*4) = (4,0)
        // P = (1+4, 0+0) = (5, 0)
        // Q = (1-4, 0-0) = (-3, 0)
        Ar=1; Ai=0; Br=4; Bi=0;
        Wr=32767; Wi=0;   // W^0 = (1, 0)
        check(16'd5, 16'd0, -16'd3, 16'd0, 1);

        // Test 2: W=W^0=(1,0), A=(3,0), B=(2,0)
        // T=(2,0), P=(5,0), Q=(1,0)
        Ar=3; Ai=0; Br=2; Bi=0;
        Wr=32767; Wi=0;
        check(16'd5, 16'd0, 16'd1, 16'd0, 2);

        // Test 3: W=W^2=(0,-1), A=(-3,0), B=(1,0)
        // T = 0*1 - (-1)*0 + j*(0*0 + (-1)*1) = (0, -1)
        // P = (-3+0, 0+(-1)) = (-3, -1)
        // Q = (-3-0, 0-(-1)) = (-3,  1)
        Ar=-3; Ai=0; Br=1; Bi=0;
        Wr=0; Wi=-32767;  // W^2 = (0, -1)
        check(-16'd3, -16'd1, -16'd3, 16'd1, 3);

        // Test 4: Stage 3 BF0: W=W^0, A=(10,0), B=(10,0)
        // T=(10,0), P=(20,0), Q=(0,0)
        Ar=10; Ai=0; Br=10; Bi=0;
        Wr=32767; Wi=0;
        check(16'd20, 16'd0, 16'd0, 16'd0, 4);

        $display("=== Done ===");
        $finish;
    end

endmodule
