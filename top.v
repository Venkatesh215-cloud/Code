module top_lmx_ad9850 #(
    // -------------------------------------------------------------------------
    // Timing parameters  (@100MHz clock)
    // -------------------------------------------------------------------------
    parameter integer POR_CYCLES         = 1_000_000,   // 10ms power-on reset
    parameter integer AUTO_START_DELAY   = 10_000,      // 100us before DDS start
    parameter integer REF_SETTLE_CYCLES  = 500_000      // 5ms ref settle time
)(
    input  wire clk100,
    input  wire btn0,           // active HIGH reset button

    // -------------------------------------------------------------------------
    // PLL SPI interface
    // -------------------------------------------------------------------------
    output wire pll_sclk,
    output wire pll_sdata,
    output wire pll_cs,
    output wire pll_pll_en,
    output wire pll_mute,
    output wire pll_lock_error,
    input  wire pll_ld,         // lock detect from PLL chip
    output wire pll_done,

    // -------------------------------------------------------------------------
    // AD9850 interface (serial mode - D7 only)
    // -------------------------------------------------------------------------
    output wire ad9850_d7,
    output wire ad9850_w_clk,
    output wire ad9850_fq_ud,
    output wire ad9850_rst_pin,

    output wire ad9850_busy,
    output wire ad9850_done,

    // -------------------------------------------------------------------------
    // Status outputs
    // -------------------------------------------------------------------------
    output wire system_done,    // HIGH when both devices ready
    output wire system_error    // HIGH on PLL lock timeout OR post-lock lock-loss
);

    // =========================================================================
    // 1. BUTTON SYNCHRONIZER (2-FF)
    // =========================================================================
    reg btn0_ff1;
    reg btn0_ff2;

    always @(posedge clk100) begin
        btn0_ff1 <= btn0;
        btn0_ff2 <= btn0_ff1;
    end

    wire btn0_sync = btn0_ff2;

    // =========================================================================
    // ADDED: Independent synchronizer for pll_ld, owned by the TOP module.
    //
    // This is deliberately separate from whatever synchronizer exists inside
    // Pll.v (ld_sync0/ld_sync1 in that module). Pll.v's internal FSM only
    // samples lock status up through S_LOCK_WAIT and goes dead after S_DONE,
    // so it cannot report a lock LOSS that happens after initial lock
    // acquisition. Rather than modifying the (already-reviewed) Pll module,
    // the top level keeps its own view of pll_ld and uses it to watch for
    // lock loss continuously, even after SYS_DONE is reached.
    // =========================================================================
    reg pll_ld_ff1;
    reg pll_ld_ff2;

    always @(posedge clk100) begin
        pll_ld_ff1 <= pll_ld;
        pll_ld_ff2 <= pll_ld_ff1;
    end

    wire pll_ld_sync = pll_ld_ff2;

    // =========================================================================
    // 2. POWER-ON RESET
    //    Active HIGH sys_rst for POR_CYCLES after power-up or button press.
    //    [G2] Width is now parametric - no silent overflow if POR_CYCLES changes.
    // =========================================================================
    reg [$clog2(POR_CYCLES+1)-1:0] por_cnt = 0;
    reg                            por_rst = 1'b1;

    always @(posedge clk100) begin
        if (btn0_sync) begin
            por_cnt <= 0;
            por_rst <= 1'b1;
        end else if (por_rst) begin
            if (por_cnt == POR_CYCLES - 1) begin
                por_rst <= 1'b0;
                por_cnt <= 0;
            end else begin
                por_cnt <= por_cnt + 1'b1;
            end
        end
    end

    wire sys_rst = por_rst | btn0_sync;   // active HIGH

    // =========================================================================
    // 3. SEQUENCER - AUTO START AFTER POR
    //    Generates one-cycle pulse AUTO_START_DELAY cycles after reset clears.
    // =========================================================================
    reg [$clog2(AUTO_START_DELAY+1)-1:0] start_delay_cnt = 0;
    reg        started;
    reg        start_pulse;     // 1-cycle pulse to kick off AD9850

    always @(posedge clk100) begin
        if (sys_rst) begin
            start_delay_cnt <= 0;
            started         <= 1'b0;
            start_pulse     <= 1'b0;
        end else begin
            start_pulse <= 1'b0;                // default: no pulse

            if (!started) begin
                if (start_delay_cnt == AUTO_START_DELAY - 1) begin
                    start_pulse <= 1'b1;        // one-cycle trigger
                    started     <= 1'b1;
                end else begin
                    start_delay_cnt <= start_delay_cnt + 1'b1;
                end
            end
        end
    end

    // =========================================================================
    // 4. SYSTEM FSM
    //
    // CORRECTED SEQUENCE:
    //   IDLE ? DDS_START ? DDS_WAIT ? REF_SETTLE ? PLL_RUN ? DONE/ERROR
    //
    // AD9850 programmed first.
    // PLL released from reset only after 10MHz is stable.
    //
    // MODIFIED: SYS_DONE now continuously monitors pll_ld_sync (top-level
    // synchronizer, see above) and pll_err. If either indicates the PLL has
    // lost lock after having previously succeeded, the FSM transitions to
    // SYS_ERROR. Pll.v itself is UNCHANGED from the original - this
    // monitoring lives entirely in the top-level integration layer.
    // =========================================================================
    localparam [2:0]
        SYS_IDLE        = 3'd0,
        SYS_DDS_START   = 3'd1,   // trigger AD9850
        SYS_DDS_WAIT    = 3'd2,   // wait for AD9850 done
        SYS_REF_SETTLE  = 3'd3,   // wait for 10MHz to stabilize
        SYS_PLL_RUN     = 3'd4,   // PLL programs itself
        SYS_DONE        = 3'd5,
        SYS_ERROR       = 3'd6;

    reg [2:0]                           sys_state;
    reg [$clog2(REF_SETTLE_CYCLES+1)-1:0] settle_cnt;
    reg        ad9850_start;     // one-cycle start pulse for AD9850
    reg        pll_rst_n;        // active LOW reset for PLL
    reg        r_dds_done;       // latched AD9850 done

    // Internal wires from submodules
    wire       dds_done_wire;    // raw single-cycle done from AD9850
    wire       pll_end;          // end_of_transfer from Pll module
    wire       pll_err;          // o_lock_error from Pll module

    always @(posedge clk100) begin
        if (sys_rst) begin
            sys_state    <= SYS_IDLE;
            settle_cnt   <= 0;
            ad9850_start <= 1'b0;
            pll_rst_n    <= 1'b0;    // PLL held in reset
            r_dds_done   <= 1'b0;
        end else begin

            ad9850_start <= 1'b0;    // default: no pulse

            // Latch AD9850 done permanently
            if (dds_done_wire)
                r_dds_done <= 1'b1;

            case (sys_state)

                // -------------------------------------------------------------
                // Wait for auto-start pulse from POR sequencer
                // -------------------------------------------------------------
                SYS_IDLE: begin
                    pll_rst_n <= 1'b0;      // PLL held in reset
                    if (start_pulse) begin
                        sys_state <= SYS_DDS_START;
                    end
                end

                // -------------------------------------------------------------
                // Send one-cycle start pulse to AD9850
                // -------------------------------------------------------------
                SYS_DDS_START: begin
                    ad9850_start <= 1'b1;   // one-cycle pulse
                    sys_state    <= SYS_DDS_WAIT;
                end

                // -------------------------------------------------------------
                // Wait until AD9850 finishes programming
                // 10MHz output now active on PLL OSCin
                // -------------------------------------------------------------
                SYS_DDS_WAIT: begin
                    if (r_dds_done) begin
                        settle_cnt <= 0;
                        sys_state  <= SYS_REF_SETTLE;
                    end
                end

                // -------------------------------------------------------------
                // Wait REF_SETTLE_CYCLES for 10MHz to be stable
                // before releasing PLL from reset
                // -------------------------------------------------------------
                SYS_REF_SETTLE: begin
                    if (settle_cnt == REF_SETTLE_CYCLES - 1) begin
                        settle_cnt <= 0;
                        pll_rst_n  <= 1'b1;  // release PLL
                        sys_state  <= SYS_PLL_RUN;
                    end else begin
                        settle_cnt <= settle_cnt + 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // PLL programs itself automatically after i_rst_n goes HIGH.
                // No start port needed - Pll module auto-starts.
                // Wait for lock or timeout error.
                // -------------------------------------------------------------
                SYS_PLL_RUN: begin
                    if (pll_err) begin
                        sys_state <= SYS_ERROR;
                    end else if (pll_end) begin
                        sys_state <= SYS_DONE;
                    end
                end

                // -------------------------------------------------------------
                // DONE state.
                //
                // MODIFIED: previously this was a pure unconditional sink
                // (`sys_state <= SYS_DONE;`). Pll.v's own FSM stops sampling
                // i_ld meaningfully once it reaches its internal S_DONE, so
                // a lock loss occurring AFTER initial lock would otherwise go
                // completely unreported at the top level.
                //
                // Using the top-level pll_ld_sync (independent 2-FF
                // synchronizer declared above, fed directly from the pll_ld
                // top-level input pin) and pll_err (Pll's own o_lock_error),
                // we now detect that condition here instead of inside Pll.v.
                // -------------------------------------------------------------
                SYS_DONE: begin
                    if (pll_err || !pll_ld_sync) begin
                        sys_state <= SYS_ERROR;
                    end else begin
                        sys_state <= SYS_DONE;
                    end
                end

                // -------------------------------------------------------------
                // Lock timeout / lock-loss - stays here until reset
                // -------------------------------------------------------------
                SYS_ERROR: begin
                    sys_state <= SYS_ERROR;
                end

                default: begin
                    sys_state <= SYS_IDLE;
                end

            endcase
        end
    end

    // =========================================================================
    // 5. AD9850 CONTROLLER INSTANCE
    //    Programs AD9850 for 10MHz output.
    //    FTW = 10e6 / 125e6 * 2^32 = 0x147AE148
    //    Adjust FTW if your AD9850 reference crystal differs from 125MHz.
    // =========================================================================
    wire [7:0] ad9850_d_bus;

    ad9850_controller_fig10 #(
        .FTW                 (32'h147AE148),  // 10MHz @ 125MHz CLKIN
        .PWRDN               (1'b0),
        .PHASE               (5'd0),
        .CLK_DIV             (20'd49),        // W_CLK ~1MHz @ 100MHz sys_clk
        .RESET_HOLD_CYCLES   (16'd200),       // 2us reset hold
        .RESET_RECOVER_CYCLES(16'd400),       // 4us recovery
        .FQUD_PULSE_CYCLES   (4'd4)           // 4-cycle FQ_UD pulse
    ) u_ad9850 (
        .clk        (clk100),
        .rst        (sys_rst),           // active HIGH reset
        .start      (ad9850_start),      // one-cycle trigger

        .d          (ad9850_d_bus),
        .w_clk      (ad9850_w_clk),
        .fq_ud      (ad9850_fq_ud),
        .ad9850_rst (ad9850_rst_pin),

        .busy       (ad9850_busy),
        .done       (dds_done_wire)      // single-cycle done pulse
    );

    // Serial mode: only D7 pin used
    assign ad9850_d7   = ad9850_d_bus[7];
    assign ad9850_done = r_dds_done;     // latched version for top-level output

    // =========================================================================
    // 6. PLL CONTROLLER INSTANCE  (UNCHANGED from original - no modifications
    //    to Pll.v are required for the lock-loss monitoring added above;
    //    all of that logic lives in the SYS_DONE case and the pll_ld_sync
    //    synchronizer declared earlier in this module.)
    //
    //    i_rst_n held LOW by sequencer until 10MHz reference is confirmed stable.
    //    Pll module auto-starts its programming sequence when i_rst_n goes HIGH.
    //
    // [G1] FCAL_EN_BIT_MASK override REMOVED - uses Pll's own corrected
    //      default (24'h000008 = R0[3]).
    //
    // [G3] NOTE: Pll module's internal comments document LMX2694-SEP R0
    //      bit positions. Confirm against actual silicon before trusting
    //      as-is if using a different part (e.g. LMX2820).
    // =========================================================================
    Pll #(
        .NO_OF_REG         (123),
        .CLK_HZ            (100_000_000),
        .SCLK_HZ           (1_000_000),
        .INTER_FRAME_DELAY (200),
        .START_DELAY_CYCLES(1000),
        .RESET_BIT_MASK    (24'h000002)
        // FCAL_EN_BIT_MASK intentionally NOT overridden -
        // uses Pll's corrected default (24'h000008)
    ) u_pll (
        .i_clk          (clk100),
        .i_rst_n        (pll_rst_n),     // sequencer controls this
        .o_sclk         (pll_sclk),
        .o_sdata        (pll_sdata),
        .o_cs           (pll_cs),
        .o_pll_en       (pll_pll_en),
        .o_mute         (pll_mute),
        .o_lock_error   (pll_lock_error),
        .i_ld           (pll_ld),        // Pll.v keeps its own internal sync too
        .end_of_transfer(pll_end)
    );

    assign pll_err  = pll_lock_error;
    assign pll_done = pll_end;

    // =========================================================================
    // 7. SYSTEM STATUS OUTPUTS
    // =========================================================================
    assign system_done  = (sys_state == SYS_DONE);
    assign system_error = (sys_state == SYS_ERROR);

endmodule