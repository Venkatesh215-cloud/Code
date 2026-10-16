module Pll
#(
    parameter integer NO_OF_REG           = 123,
    parameter integer CLK_HZ              = 100_000_000,
    parameter integer SCLK_HZ             =   1_000_000,
    parameter integer INTER_FRAME_DELAY   = 200,
    parameter integer START_DELAY_CYCLES  = 1000,
    parameter [23:0] RESET_BIT_MASK       = 24'h000002,  // Bit 1 - RESET
    parameter [23:0] FCAL_EN_BIT_MASK     = 24'h000010,  // Bit 4 - FCAL_EN (CORRECTED from 0x000001)
    parameter [23:0] POWERDOWN_BIT_MASK   = 24'h000001   // Bit 0 - POWERDOWN (ADDED - explicitly mask this out)
)
(
    input  wire i_clk,
    input  wire i_rst_n,

    output wire o_sclk,
    output reg  o_sdata,
    output wire o_cs,
    output reg  o_pll_en,
    output reg  o_mute,
    output reg  o_lock_error,

    input  wire i_ld,
    output reg  end_of_transfer
);

    // -------------------------------------------------------------------------
    // SPI clock half period
    // -------------------------------------------------------------------------
    localparam integer SCLK_HALF_SAFE =
        (CLK_HZ / (SCLK_HZ * 2) < 1) ? 1 : CLK_HZ / (SCLK_HZ * 2);

    localparam integer LDO_WAIT_TARGET     = 32'd999_999;
    localparam integer LOCK_TIMEOUT_TARGET = 32'd3_999_999;

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    localparam [3:0]
        S_IDLE           = 4'd0,
        S_CS_SETUP       = 4'd1,
        S_SHIFT          = 4'd2,
        S_SHIFT_CLK_LOW  = 4'd3,   // NEW: wait for clean clock LOW
        S_SHIFT_END_WAIT = 4'd4,   // NEW: hold after last bit
        S_CS_HOLD        = 4'd5,
        S_NEXT           = 4'd6,
        S_LDO_WAIT       = 4'd7,
        S_LOCK_WAIT      = 4'd8,
        S_DONE           = 4'd9;

    reg [3:0] r_state;

    // -------------------------------------------------------------------------
    // Register memory "C:\Users\venky\Desktop\HexRegisterValues.txt"
    // -------------------------------------------------------------------------
    reg [23:0] r_data_mem [0:NO_OF_REG-1];
    //initial $readmemh("6ghz_register_values.txt", r_data_mem);
    
    initial $readmemh("C:/Users/vinitkumar/Downloads/attachments/10To7Ghz.txt", r_data_mem);

    // -------------------------------------------------------------------------
    // R0 derived from register file - automatic for any frequency
    // CORRECTED: All derived words now explicitly force POWERDOWN=0
    // -------------------------------------------------------------------------
    wire [23:0] w_r0_base;
    wire [23:0] w_soft_reset_word;
    wire [23:0] w_reset_clear_word;
    wire [23:0] w_r0_fcal_en;

    assign w_r0_base        = r_data_mem[NO_OF_REG-1];

    // Soft reset word: Set RESET=1, clear FCAL_EN, force POWERDOWN=0
    assign w_soft_reset_word  = (w_r0_base & ~FCAL_EN_BIT_MASK & ~POWERDOWN_BIT_MASK)
                                 |  RESET_BIT_MASK;

    // Reset clear word: Clear RESET, clear FCAL_EN, force POWERDOWN=0
    assign w_reset_clear_word = (w_r0_base & ~FCAL_EN_BIT_MASK & ~POWERDOWN_BIT_MASK)
                                 & ~RESET_BIT_MASK;

    // FCAL enable word: Clear RESET, set FCAL_EN=1, force POWERDOWN=0
    assign w_r0_fcal_en       = (w_r0_base & ~RESET_BIT_MASK & ~POWERDOWN_BIT_MASK)
                                 |  FCAL_EN_BIT_MASK;

    // -------------------------------------------------------------------------
    // SPI datapath registers
    // -------------------------------------------------------------------------
    reg [23:0] r_data;
    reg [31:0] spi_half_ctr;
    reg        spi_clk;
    reg        cs_reg;
    reg [5:0]  rising_count;

    // -------------------------------------------------------------------------
    // Counters
    // -------------------------------------------------------------------------
    reg [31:0] general_ctr;
    reg [7:0]  r_reg_count;
    reg [8:0]  inter_frame_cnt;

    // -------------------------------------------------------------------------
    // Sequence phase flags
    // -------------------------------------------------------------------------
    reg phase_soft_rst_1_done;
    reg phase_soft_rst_0_done;
    reg phase_regs_done;
    reg phase_ldo_done;

    // -------------------------------------------------------------------------
    // CDC synchroniser
    // -------------------------------------------------------------------------
    reg ld_sync0;
    reg ld_sync1;

    assign o_cs   = cs_reg;
    assign o_sclk = spi_clk;

    // =========================================================================
    // MAIN FSM
    // =========================================================================
    always @(posedge i_clk or negedge i_rst_n) begin

        if (!i_rst_n) begin

            r_state               <= S_IDLE;
            o_pll_en              <= 1'b0;
            o_mute                <= 1'b1;
            o_sdata               <= 1'b0;
            o_lock_error          <= 1'b0;
            end_of_transfer       <= 1'b0;
            spi_clk               <= 1'b0;
            cs_reg                <= 1'b1;
            spi_half_ctr          <= 32'd0;
            rising_count          <= 6'd0;
            general_ctr           <= 32'd0;
            r_reg_count           <= 8'd0;
            inter_frame_cnt       <= 9'd0;
            r_data                <= 24'd0;
            phase_soft_rst_1_done <= 1'b0;
            phase_soft_rst_0_done <= 1'b0;
            phase_regs_done       <= 1'b0;
            phase_ldo_done        <= 1'b0;
            ld_sync0              <= 1'b0;
            ld_sync1              <= 1'b0;

        end else begin

            ld_sync0 <= i_ld;
            ld_sync1 <= ld_sync0;

            case (r_state)

                // =============================================================
                // S_IDLE
                // =============================================================
                S_IDLE: begin
                    o_pll_en <= 1'b1;
                    o_mute   <= 1'b1;
                    cs_reg   <= 1'b1;
                    spi_clk  <= 1'b0;
                    o_sdata  <= 1'b0;

                    if (general_ctr < START_DELAY_CYCLES) begin
                        general_ctr <= general_ctr + 1;
                    end else begin
                        general_ctr <= 32'd0;
                        r_data      <= w_soft_reset_word;
                        r_state     <= S_CS_SETUP;
                    end
                end

                // =============================================================
                // S_CS_SETUP
                // CS goes LOW. MOSI = MSB. Wait one half period before clocking.
                // This guarantees tCES (CS to SCK setup = 10ns minimum).
                // =============================================================
                S_CS_SETUP: begin
                    cs_reg       <= 1'b0;
                    spi_clk      <= 1'b0;
                    o_sdata      <= r_data[23];
                    spi_half_ctr <= 32'd0;
                    rising_count <= 6'd0;
                    r_state      <= S_SHIFT;
                end

                // =============================================================
                // S_SHIFT
                //
                // FIX FOR 24th PULSE NOISE:
                //
                // After rising_count reaches 24 (all bits sampled),
                // the clock is HIGH. We must NOT force it low immediately.
                // Instead go to S_SHIFT_CLK_LOW to complete the natural
                // falling edge after the full half period.
                //
                // Timeline:
                //   Rise 23 ? rc=24 ? spi_clk still HIGH
                //   Wait remaining half period ? natural FALL ? S_SHIFT_END_WAIT
                //   Wait one more half period  ? CS deassert ? S_CS_HOLD
                //
                // This gives EXACTLY 24 clean symmetric pulses on scope.
                // =============================================================
                S_SHIFT: begin

                    if (spi_half_ctr >= SCLK_HALF_SAFE - 1) begin

                        spi_half_ctr <= 32'd0;

                        if (rising_count == 6'd24) begin
                            // -------------------------------------------------
                            // All 24 bits sampled. Clock is HIGH.
                            // Let it fall naturally ? go to CLK_LOW state.
                            // Do NOT force clock here.
                            // -------------------------------------------------
                            spi_clk <= 1'b0;      // natural falling edge
                            r_state <= S_SHIFT_CLK_LOW;

                        end else begin

                            spi_clk <= ~spi_clk;

                            if (spi_clk == 1'b0) begin
                                // Rising edge - device samples MOSI
                                rising_count <= rising_count + 1;

                            end else begin
                                // Falling edge - update MOSI for next bit
                                if (rising_count <= 6'd23) begin
                                    o_sdata <= r_data[23 - rising_count];
                                end
                            end

                        end

                    end else begin
                        spi_half_ctr <= spi_half_ctr + 1;
                    end

                end

                // =============================================================
                // S_SHIFT_CLK_LOW  (NEW STATE)
                //
                // Clock has just gone LOW after the 24th rising edge.
                // Hold LOW for one full half period.
                // This makes the 24th pulse width identical to all others.
                // MOSI held at last value until CS rises.
                //
                // SCOPE will show:
                // Pulse 24: __|?????|_____ (clean, same width as 1-23)
                // =============================================================
                S_SHIFT_CLK_LOW: begin

                    spi_clk <= 1'b0;

                    if (spi_half_ctr >= SCLK_HALF_SAFE - 1) begin
                        // One clean low half period done.
                        // Now enter end wait before CS release.
                        spi_half_ctr <= 32'd0;
                        r_state      <= S_SHIFT_END_WAIT;
                    end else begin
                        spi_half_ctr <= spi_half_ctr + 1;
                    end

                end

                // =============================================================
                // S_SHIFT_END_WAIT  (MODIFIED)
                //
                // Clock is LOW. CS is still LOW.
                // Hold for one more half period for tCH (data hold time).
                // Then deassert CS cleanly.
                //
                // tCH (SDI to SCK hold) = 2ns minimum - easily satisfied.
                // =============================================================
                S_SHIFT_END_WAIT: begin

                    spi_clk <= 1'b0;
                    // MOSI held at last bit value during this hold

                    if (spi_half_ctr >= SCLK_HALF_SAFE - 1) begin
                        spi_half_ctr    <= 32'd0;
                        cs_reg          <= 1'b1;   // CS goes HIGH cleanly
                        o_sdata         <= 1'b0;   // MOSI cleared
                        rising_count    <= 6'd0;
                        inter_frame_cnt <= 9'd0;
                        r_state         <= S_CS_HOLD;
                    end else begin
                        spi_half_ctr <= spi_half_ctr + 1;
                    end

                end

                // =============================================================
                // S_CS_HOLD
                // Inter-frame gap. CS HIGH. SCLK LOW. MOSI LOW.
                // 200 cycles = 2µs >> 3ns tEWH minimum.
                // =============================================================
                S_CS_HOLD: begin
                    cs_reg  <= 1'b1;
                    spi_clk <= 1'b0;
                    o_sdata <= 1'b0;

                    if (inter_frame_cnt < INTER_FRAME_DELAY) begin
                        inter_frame_cnt <= inter_frame_cnt + 1;
                    end else begin
                        inter_frame_cnt <= 9'd0;
                        r_state         <= S_NEXT;
                    end
                end

                // =============================================================
                // S_NEXT
                // =============================================================
                S_NEXT: begin

                    if (!phase_soft_rst_1_done) begin
                        phase_soft_rst_1_done <= 1'b1;
                        r_data                <= w_reset_clear_word;
                        r_state               <= S_CS_SETUP;

                    end else if (!phase_soft_rst_0_done) begin
                        phase_soft_rst_0_done <= 1'b1;
                        r_reg_count           <= 8'd0;
                        r_data                <= r_data_mem[0];
                        r_state               <= S_CS_SETUP;

                    end else if (!phase_regs_done) begin

                        if (r_reg_count < NO_OF_REG - 1) begin

                            r_reg_count <= r_reg_count + 1;

                            if ((r_reg_count + 8'd1) == (NO_OF_REG - 1)) begin
                                // Next = R0, mask FCAL_EN and force POWERDOWN=0
                                // CORRECTED: Added POWERDOWN_BIT_MASK clearing
                                r_data <= r_data_mem[r_reg_count + 1]
                                          & ~FCAL_EN_BIT_MASK
                                          & ~POWERDOWN_BIT_MASK;
                            end else begin
                                r_data <= r_data_mem[r_reg_count + 1];
                            end

                            r_state <= S_CS_SETUP;

                        end else begin
                            phase_regs_done <= 1'b1;
                            general_ctr     <= 32'd0;
                            r_state         <= S_LDO_WAIT;
                        end

                    end else if (!phase_ldo_done) begin
                        phase_ldo_done <= 1'b1;
                        r_data         <= w_r0_fcal_en;
                        r_state        <= S_CS_SETUP;

                    end else begin
                        general_ctr <= 32'd0;
                        r_state     <= S_LOCK_WAIT;
                    end

                end

                // =============================================================
                // S_LDO_WAIT - 10ms
                // =============================================================
                S_LDO_WAIT: begin
                    if (general_ctr < LDO_WAIT_TARGET) begin
                        general_ctr <= general_ctr + 1;
                    end else begin
                        general_ctr <= 32'd0;
                        r_state     <= S_NEXT;
                    end
                end

                // =============================================================
                // S_LOCK_WAIT - 40ms timeout
                // =============================================================
                S_LOCK_WAIT: begin
                    if (ld_sync1) begin
                        end_of_transfer <= 1'b1;
                        o_lock_error    <= 1'b0;
                        o_mute          <= 1'b0;
                        r_state         <= S_DONE;

                    end else if (general_ctr < LOCK_TIMEOUT_TARGET) begin
                        general_ctr <= general_ctr + 1;

                    end else begin
                        end_of_transfer <= 1'b0;
                        o_lock_error    <= 1'b1;
                        o_mute          <= 1'b1;
                        r_state         <= S_DONE;
                    end
                end

                // =============================================================
                // S_DONE
                // =============================================================
                S_DONE: begin
                    cs_reg  <= 1'b1;
                    spi_clk <= 1'b0;
                    o_sdata <= 1'b0;
                    r_state <= S_DONE;
                end

                default: begin
                    r_state <= S_IDLE;
                end

            endcase

        end

    end

endmodule