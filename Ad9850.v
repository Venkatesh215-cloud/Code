module ad9850_controller_fig10 #(
    parameter [31:0] FTW = 32'h147AE148,
    parameter        PWRDN = 1'b0,
    parameter [4:0]  PHASE = 5'd0,
    parameter [19:0] CLK_DIV = 20'd49,
    parameter [15:0] RESET_HOLD_CYCLES    = 16'd200,
    parameter [15:0] RESET_RECOVER_CYCLES = 16'd400,
    parameter [3:0]  FQUD_PULSE_CYCLES    = 4'd4
)(
    input  wire clk,
    input  wire rst,
    input  wire start,

    output reg  [7:0] d,
    output reg  w_clk,
    output reg  fq_ud,
    output reg  ad9850_rst,

    output reg  busy,
    output reg  done
);

    wire [39:0] serial_word = {PHASE[4:0], PWRDN, 2'b00, FTW};

    // W_CLK generator
    reg        wclk_run;
    reg [19:0] wclk_cnt;
    reg        wclk_rise, wclk_fall;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            w_clk     <= 1'b0;
            wclk_cnt  <= 20'd0;
            wclk_rise <= 1'b0;
            wclk_fall <= 1'b0;
        end else begin
            wclk_rise <= 1'b0;
            wclk_fall <= 1'b0;
            if (!wclk_run) begin
                w_clk    <= 1'b0;
                wclk_cnt <= 20'd0;
            end else begin
                if (wclk_cnt == CLK_DIV) begin
                    wclk_cnt <= 20'd0;
                    if (w_clk == 1'b0) begin
                        w_clk     <= 1'b1;
                        wclk_rise <= 1'b1;
                    end else begin
                        w_clk     <= 1'b0;
                        wclk_fall <= 1'b1;
                    end
                end else begin
                    wclk_cnt <= wclk_cnt + 1'b1;
                end
            end
        end
    end

    // FSM States
    localparam [3:0]
        IDLE          = 4'd0,
        RESET_HOLD    = 4'd1,
        RESET_RELEASE = 4'd2,
        RESET_RECOVER = 4'd3,
        SER_EN_LOAD   = 4'd4,
        SER_EN_CLK    = 4'd5,
        SER_EN_FQH    = 4'd6,
        SER_EN_FQL    = 4'd7,
        LOAD          = 4'd8,
        SHIFT         = 4'd9,
        UPDATE_H      = 4'd10,
        UPDATE_L      = 4'd11,
        DONE_STATE    = 4'd12;

    reg [3:0]  state;
    reg [39:0] shift_reg;
    reg [5:0]  rise_count;
    reg        ser_en_rise_seen;
    reg        shift_done_pending;
    reg [15:0] rst_count;
    reg [3:0]  fqud_count;

    // ============================================
    // FIXED: Start synchronizer
    // start_pulse is already 1 cycle wide
    // just sync and latch it
    // ============================================
    reg start_ff1, start_ff2;
    reg start_req;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            start_ff1 <= 1'b0;
            start_ff2 <= 1'b0;
            start_req <= 1'b0;
        end else begin
            start_ff1 <= start;
            start_ff2 <= start_ff1;

            // Latch pulse - clear only when FSM accepts it
            if (start_ff2)
                start_req <= 1'b1;
            else if (state == IDLE && start_req)
                start_req <= 1'b0;
        end
    end

    // Main FSM
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state              <= IDLE;
            d                  <= 8'h00;
            fq_ud              <= 1'b0;
            ad9850_rst         <= 1'b0;
            busy               <= 1'b0;
            done               <= 1'b0;
            shift_reg          <= 40'd0;
            rise_count         <= 6'd0;
            ser_en_rise_seen   <= 1'b0;
            shift_done_pending <= 1'b0;
            rst_count          <= 16'd0;
            fqud_count         <= 4'd0;
            wclk_run           <= 1'b0;
        end else begin
            case (state)

                IDLE: begin
                    d          <= 8'h00;
                    fq_ud      <= 1'b0;
                    ad9850_rst <= 1'b0;
                    busy       <= 1'b0;
                    done       <= 1'b0;
                    rst_count  <= 16'd0;
                    fqud_count <= 4'd0;
                    wclk_run   <= 1'b0;
                    if (start_req) begin
                        busy  <= 1'b1;
                        state <= RESET_HOLD;
                    end
                end

                RESET_HOLD: begin
                    ad9850_rst <= 1'b1;
                    if (rst_count == RESET_HOLD_CYCLES - 1) begin
                        rst_count <= 16'd0;
                        state     <= RESET_RELEASE;
                    end else
                        rst_count <= rst_count + 1'b1;
                end

                RESET_RELEASE: begin
                    ad9850_rst <= 1'b0;
                    rst_count  <= 16'd0;
                    state      <= RESET_RECOVER;
                end

                RESET_RECOVER: begin
                    if (rst_count == RESET_RECOVER_CYCLES - 1) begin
                        rst_count <= 16'd0;
                        state     <= SER_EN_LOAD;
                    end else
                        rst_count <= rst_count + 1'b1;
                end

                SER_EN_LOAD: begin
                    d                <= 8'h03;
                    fq_ud            <= 1'b0;
                    ser_en_rise_seen <= 1'b0;
                    wclk_run         <= 1'b1;
                    state            <= SER_EN_CLK;
                end

                SER_EN_CLK: begin
                    if (wclk_rise)
                        ser_en_rise_seen <= 1'b1;
                    if (ser_en_rise_seen && wclk_fall) begin
                        wclk_run   <= 1'b0;
                        fqud_count <= 4'd0;
                        state      <= SER_EN_FQH;
                    end
                end

                SER_EN_FQH: begin
                    fq_ud <= 1'b1;
                    if (fqud_count == FQUD_PULSE_CYCLES - 1) begin
                        fqud_count <= 4'd0;
                        state      <= SER_EN_FQL;
                    end else
                        fqud_count <= fqud_count + 1'b1;
                end

                SER_EN_FQL: begin
                    fq_ud <= 1'b0;
                    state <= LOAD;
                end

                LOAD: begin
                    shift_reg          <= serial_word;
                    rise_count         <= 6'd0;
                    d                  <= {serial_word[0], 7'b0};
                    shift_done_pending <= 1'b0;
                    fq_ud              <= 1'b0;
                    wclk_run           <= 1'b1;
                    state              <= SHIFT;
                end

                SHIFT: begin
                    if (wclk_rise) begin
                        rise_count <= rise_count + 1'b1;
                        if (rise_count == 6'd39)
                            shift_done_pending <= 1'b1;
                    end

                    if (wclk_fall && (rise_count < 6'd40)) begin
                        shift_reg <= shift_reg >> 1;
                        d         <= {shift_reg[1], 7'b0};
                    end

                    if (shift_done_pending && wclk_fall) begin
                        wclk_run   <= 1'b0;
                        fqud_count <= 4'd0;
                        state      <= UPDATE_H;
                    end
                end

                UPDATE_H: begin
                    fq_ud <= 1'b1;
                    if (fqud_count == FQUD_PULSE_CYCLES - 1) begin
                        fqud_count <= 4'd0;
                        state      <= UPDATE_L;
                    end else
                        fqud_count <= fqud_count + 1'b1;
                end

                UPDATE_L: begin
                    fq_ud <= 1'b0;
                    state <= DONE_STATE;
                end

                DONE_STATE: begin
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule