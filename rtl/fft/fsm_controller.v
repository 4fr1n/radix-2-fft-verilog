// fsm_controller.v
// Sequences all 12 butterfly operations for an 8-point in-place FFT.
//
// The FSM runs through 3 stages, each with 4 butterflies.
// For each butterfly it computes addr_top, addr_bot, twiddle_k from
// the current stage and butterfly index using the formulas:
//
//   distance   = 2^(stage - 1)                  → 1, 2, 4
//   group_size = 2 * distance                   → 2, 4, 8
//   group      = bfly_idx / distance
//   position   = bfly_idx % distance
//   addr_top   = group * group_size + position
//   addr_bot   = addr_top + distance
//   twiddle_k  = position * (4 / distance)      (4 = N/2 for N=8)
//
// STATE MACHINE:
//
//   IDLE     → wait for start pulse
//   LOAD     → external logic writes input samples into reg_file (8 cycles)
//   READ     → assert addr_top, addr_bot; reg_file outputs A and B as wires
//   LATCH    → A and B captured into butterfly input registers; W from ROM
//   COMPUTE  → butterfly multiplies W*B (1 cycle), then adds P,Q (1 cycle)
//   WRITE    → write P back to mem[addr_top], Q to mem[addr_bot]
//   NEXT     → increment bfly_idx; if stage done, increment stage
//   DONE     → assert done flag for one cycle, return to IDLE
//
// The COMPUTE state takes 2 internal cycles (multiply then add/subtract).
// We handle this with a sub-counter inside COMPUTE.

module fsm_controller (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,          // pulse high for 1 cycle to begin FFT

    // Address outputs to reg_file
    output reg  [2:0]  addr_a,         // port A address (addr_top)
    output reg  [2:0]  addr_b,         // port B address (addr_bot)
    output reg         we_a,           // write enable for port A
    output reg         we_b,           // write enable for port B

    // Twiddle index to ROM
    output reg  [1:0]  twiddle_k,

    // Latch enable: tells butterfly registers to capture A, B, W
    output reg         latch_en,

    // Done flag
    output reg         done
);

    // ---------------------------------------------------------------
    // State encoding
    // ---------------------------------------------------------------
    localparam IDLE    = 3'd0;
    localparam READ    = 3'd1;
    localparam LATCH   = 3'd2;
    localparam COMPUTE = 3'd3;
    localparam WRITE   = 3'd4;
    localparam NEXT    = 3'd5;
    localparam DONE    = 3'd6;

    reg [2:0] state;

    // ---------------------------------------------------------------
    // Loop counters
    // ---------------------------------------------------------------
    reg [1:0] stage;        // 1, 2, 3
    reg [1:0] bfly_idx;     // 0, 1, 2, 3
    reg [1:0] compute_cnt;  // sub-counter for the 2-cycle COMPUTE state

    // ---------------------------------------------------------------
    // Address computation (combinational — pure wires)
    //
    // distance = 2^(stage-1). Since stage is 1,2,3 we use a case.
    // Everything else follows from distance.
    // ---------------------------------------------------------------
    reg [2:0] distance;
    reg [2:0] group_size;
    reg [1:0] group;
    reg [1:0] position;
    reg [2:0] addr_top_comb;
    reg [2:0] addr_bot_comb;
    reg [1:0] twiddle_k_comb;

    always @(*) begin
        // distance = 2^(stage-1)
        case (stage)
            2'd1:    distance = 3'd1;
            2'd2:    distance = 3'd2;
            default: distance = 3'd4;   // stage 3
        endcase

        group_size    = distance << 1;                    // 2*distance
        group         = bfly_idx >> (stage - 1);          // bfly_idx / distance
        position      = bfly_idx & (distance - 1);        // bfly_idx % distance

        addr_top_comb = (group * group_size) + position;
        addr_bot_comb = addr_top_comb + distance;

        // twiddle_k = position * (N/2 / distance) = position * (4 / distance)
        case (distance)
            3'd1:    twiddle_k_comb = position << 2;  // position * 4
            3'd2:    twiddle_k_comb = position << 1;  // position * 2
            default: twiddle_k_comb = position;       // position * 1
        endcase
    end

    // ---------------------------------------------------------------
    // State machine
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            stage       <= 2'd1;
            bfly_idx    <= 2'd0;
            compute_cnt <= 2'd0;
            addr_a      <= 3'd0;
            addr_b      <= 3'd0;
            we_a        <= 1'b0;
            we_b        <= 1'b0;
            twiddle_k   <= 2'd0;
            latch_en    <= 1'b0;
            done        <= 1'b0;
        end else begin
            // Default outputs — override below as needed
            we_a     <= 1'b0;
            we_b     <= 1'b0;
            latch_en <= 1'b0;
            done     <= 1'b0;

            case (state)

                // -------------------------------------------------
                // IDLE: wait for start signal
                // -------------------------------------------------
                IDLE: begin
                    stage    <= 2'd1;
                    bfly_idx <= 2'd0;
                    if (start)
                        state <= READ;
                end

                // -------------------------------------------------
                // READ: put address on bus; reg_file outputs A and B
                // combinationally this cycle. We capture next cycle.
                // -------------------------------------------------
                READ: begin
                    addr_a    <= addr_top_comb;
                    addr_b    <= addr_bot_comb;
                    twiddle_k <= twiddle_k_comb;
                    state     <= LATCH;
                end

                // -------------------------------------------------
                // LATCH: reg_file read data is now valid (one cycle
                // after address was driven). Assert latch_en so the
                // butterfly unit registers capture Ar,Ai,Br,Bi,Wr,Wi.
                // -------------------------------------------------
                LATCH: begin
                    latch_en    <= 1'b1;
                    compute_cnt <= 2'd0;
                    state       <= COMPUTE;
                end

                // -------------------------------------------------
                // COMPUTE: butterfly runs for 2 sub-cycles.
                //   compute_cnt=0: multiply W*B  → Tr, Ti registered
                //   compute_cnt=1: add/subtract  → Pr,Pi,Qr,Qi registered
                // -------------------------------------------------
                COMPUTE: begin
                    if (compute_cnt == 2'd1)
                        state <= WRITE;
                    else
                        compute_cnt <= compute_cnt + 1;
                end

                // -------------------------------------------------
                // WRITE: write P to mem[addr_top], Q to mem[addr_bot]
                // The butterfly output registers Pr,Pi,Qr,Qi are stable.
                // -------------------------------------------------
                WRITE: begin
                    we_a  <= 1'b1;
                    we_b  <= 1'b1;
                    state <= NEXT;
                end

                // -------------------------------------------------
                // NEXT: advance butterfly index or stage
                // -------------------------------------------------
                NEXT: begin
                    if (bfly_idx == 2'd3) begin
                        // Finished all 4 butterflies in this stage
                        bfly_idx <= 2'd0;
                        if (stage == 2'd3) begin
                            // All 3 stages done
                            state <= DONE;
                        end else begin
                            stage <= stage + 1;
                            state <= READ;
                        end
                    end else begin
                        bfly_idx <= bfly_idx + 1;
                        state    <= READ;
                    end
                end

                // -------------------------------------------------
                // DONE: assert done for one cycle, go back to IDLE
                // -------------------------------------------------
                DONE: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;

            endcase
        end
    end

endmodule
