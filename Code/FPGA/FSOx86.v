// V3.3.2 Measurement Repair TEST. See README.md and VALIDATION.md before use.
module FSOx86 (
    input  wire        CLOCK_50,
    input  wire        reset_n,

    // Manual board-test switch
    // Assign this to one FPGA switch, for example SW0
    input  wire        blink_sw,

    // Digital loopback / comparator input
    // First test: laser_ep -> 220 ohm or 330 ohm resistor -> rx_in
    input  wire        rx_in,
    input  wire        rx_in2,

    // FT601 FIFO interface, keep this on FT601 100 MHz clock
    input  wire        ft_clk,
    inout  wire [31:0] ft_data,

    input  wire        ft_rxf_n,
    input  wire        ft_txe_n,

    output reg         ft_oe_n,
    output reg         ft_rd_n,
    output reg         ft_wr_n,
    output wire        ft_siwu_n,

    // FSO transmitter output, generated from PLL 250 MHz
    output reg         laser_ep,
    output wire        laser_ep2,

    // Display
    output reg  [7:0]  led,

    output reg  [6:0]  HEX0,
    output reg  [6:0]  HEX1,
    output reg  [6:0]  HEX2,
    output reg  [6:0]  HEX4
);

    assign ft_siwu_n = 1'b1;

    // SISO/DIV retain the waveform copy. SMP uses its own serializer.
    // Pin assignments remain in the project QSF (TX2 GPIO5, RX2 GPIO15).
    reg laser_smp2;
    wire smp_mode;
    reg data_bit2, data_bit2_previous, data_bit2_previous2, data_bit2_previous3;
    wire [31:0] smp_status_tx;
    reg [255:0] smp_capture_data;
    reg [31:0] smp_first_pair_id, smp_last_pair_id;
    assign laser_ep2 = smp_mode ? laser_smp2 : laser_ep;

    // ============================================================
    // PLL 250 MHz for data plane / laser transmitter
    // ============================================================
    wire clk_250;

    PLL_x86 pll_250_inst (
        .refclk   (CLOCK_50),
        .rst      (~reset_n),
        .outclk_0 (clk_250)
    );

    // ============================================================
    // FT601 bidirectional data bus
    //
    // Normal START / STOP / RESET commands are write-only.
    // Only status command R returns one 32-bit word.
    // ============================================================
    reg [31:0] usb_tx_word;
    reg        usb_tx_drive;

    assign ft_data = usb_tx_drive ? usb_tx_word : 32'hZZZZ_ZZZZ;

    // ============================================================
    // Command registers in FT601 clock domain
    //
    // Normal 4-byte command:
    // Byte 0 = Data type
    // Byte 1 = Coding
    // Byte 2 = Bit rate
    // Byte 3 = Modulation
    //
    // Example:
    // A E K G = PRBS7 + None + 1 Mbps + OOK-NRZ
    //
    // Special commands:
    // X 00 00 00 = Stop
    // S 00 00 00 = Stop
    // Z 00 00 00 = FPGA soft reset, clear everything
    // Y 00 00 00 = NOP / keep-alive
    // I MODE 00 00 = select 0:SISO, 1:diversity, 2:SMP (OOK-NRZ)
    // V PH DL LINK = tune one OOK-NRZ receiver at every bit rate
    //               PH = sample phase (0..active_bit_ticks-1)
    //               DL = TX-reference delay in whole bits, 0..3
    //               LINK = 0 for RX1, 1 for RX2
    //
    // Status query:
    // R 00 00 ID = return one 32-bit status word
    //
    // ID 1 = Line bits in fully completed encoded TX frames (TXF1)
    // ID 2 = RX checked line samples after lock
    // ID 3 = Line-level sample errors
    // ID 6 = Legacy live launched-bit TX counter (diagnostic only)
    // ID 7 = RX checked line samples before payload decoding
    // ID 8 = Line-level error samples before payload decoding
    // ID 4 = Status word: {mod, speed, flags, 'R'}
    // ID 5 = Active bit ticks
    // ID 9 = User Text length
    // ID 10..17 = RX User Text, four ASCII bytes per word
    // ID 19 = Number of captured RX User Text bytes (0..32)
    // ID 28 = RX2 checked line samples after lock
    // ID 29 = RX2 line-sample errors (paired by the ID 28 query)
    // ID 34 = RX2 tune setting, bits 10:9 delay and bits 8:0 phase
    // ID 35 = Counter firmware identifier 0x54584631 (TXF1)
    // ID 36 = Legacy TX paired with ID1 after 1,2,3,28,29,4; live otherwise
    // ID 37 = SMP protocol capability 0x534D5031 (SMP1)
    // ID 38 = {30-bit run epoch, 2-bit mode}, frozen with ID1
    // ID 39 = rearm paired RX capture, returns the new 32-bit request token
    // ID 40 = freeze paired snapshot: ready[0], locks[2:1], mode[4:3],
    //         pair count[10:5]. Never insert into the legacy BER query group.
    // ID 41 = frozen request token; IDs 42..49 = 32 actual RX bytes, LE
    // ID 50 = frozen first pair ID; ID 51 = frozen 30-bit run epoch
    //
    // Text write commands:
    // W INDEX CHAR 00 = write one TX text character into FPGA memory
    // L LEN   00   00 = set TX text length
    //
    // flags bit0 = tx_enable
    // flags bit1 = rx_locked
    // flags bit2 = rx_supported
    // flags bit3 = blink_sw
    // flags bit4 = payload_rx_supported
    // flags bit5 = RX2 locked
    // flags bit6 = diversity mode active
    // flags bit7 = diversity decoder currently selecting RX2
    // ============================================================
    reg [7:0] cmd_data_ft;
    reg [7:0] cmd_code_ft;
    reg [7:0] cmd_speed_ft;
    reg [7:0] cmd_mod_ft;

    reg       tx_enable_ft;
    reg       got_command_ft;

    // Command event crossing from ft_clk to clk_250
    reg       cmd_toggle_ft;
    reg [3:0] cmd_action_ft;

    localparam [3:0] CMD_ACTION_START     = 4'd0;
    localparam [3:0] CMD_ACTION_STOP      = 4'd1;
    localparam [3:0] CMD_ACTION_RESTART   = 4'd2;
    localparam [3:0] CMD_ACTION_NOP       = 4'd3;
    localparam [3:0] CMD_ACTION_SOFTRESET = 4'd4;
    localparam [3:0] CMD_ACTION_TEXTWRITE = 4'd5;
    localparam [3:0] CMD_ACTION_TEXTLEN   = 4'd6;
    localparam [3:0] CMD_ACTION_RX_TUNE   = 4'd7;
    localparam [3:0] CMD_ACTION_MIMO_MODE = 4'd8;

    localparam [1:0] MIMO_SISO = 2'd0;
    localparam [1:0] MIMO_DIV  = 2'd1;
    localparam [1:0] MIMO_SMP  = 2'd2;

    reg [5:0] text_index_ft;
    reg [7:0] text_char_ft;
    reg [5:0] text_len_ft;
    reg       text_capture_reset_toggle_ft;

    // SMP rearm request uses a stable bundled token plus an event toggle.
    reg [31:0] smp_request_token_ft;
    reg smp_request_toggle_ft;
    reg [31:0] smp_request_token_meta_tx, smp_request_token_sync_tx;
    reg [2:0] smp_request_toggle_sync_tx;
    reg smp_request_toggle_seen_tx;
    wire smp_rearm_tx = smp_request_toggle_sync_tx[2] != smp_request_toggle_seen_tx;
    reg [31:0] smp_capture_token_tx;
    reg [29:0] run_epoch_tx;

    // Extended fields travel with the existing counter snapshot event.
    reg [31:0] run_mode_snapshot_tx, run_mode_meta_ft, run_mode_sync_ft;
    reg [31:0] run_mode_status_ft, run_mode_query_ft;
    reg [31:0] smp_status_snapshot_tx, smp_status_meta_ft, smp_status_sync_ft;
    reg [31:0] smp_status_status_ft, smp_status_query_ft;
    reg [31:0] smp_token_snapshot_tx, smp_token_meta_ft, smp_token_sync_ft;
    reg [31:0] smp_token_status_ft, smp_token_query_ft;
    reg [31:0] smp_first_snapshot_tx, smp_first_meta_ft, smp_first_sync_ft;
    reg [31:0] smp_first_status_ft, smp_first_query_ft;
    reg [29:0] smp_epoch_query_ft;
    reg [255:0] smp_data_snapshot_tx, smp_data_meta_ft, smp_data_sync_ft;
    reg [255:0] smp_data_status_ft, smp_data_query_ft;
    // V3.1 optional SMP diagnostics, frozen by R40 with the existing bundle.
    reg [223:0] smp_diag_snapshot_tx, smp_diag_meta_ft, smp_diag_sync_ft;
    reg [223:0] smp_diag_status_ft, smp_diag_query_ft;
    wire [223:0] smp_diag_tx;

    // Runtime OOK-NRZ receiver tuning request in ft_clk domain.
    reg [8:0] nrz_tune_phase_ft;
    reg [1:0] nrz_tune_delay_ft;
    reg       nrz_tune_link_ft;
    reg [1:0] mimo_mode_ft;

    // ============================================================
    // Data-plane command registers in 250 MHz domain
    // ============================================================
    reg [7:0] cmd_data_tx;
    reg [7:0] cmd_code_tx;
    reg [7:0] cmd_speed_tx;
    reg [7:0] cmd_mod_tx;

    reg       tx_enable_tx;
    reg       tx_restart_pulse_tx;
    reg       soft_reset_pulse_tx;

    // Runtime OOK-NRZ tuning for the currently selected bit rate.
    reg [8:0] nrz_phase_tx;
    reg [1:0] nrz_delay_tx;
    reg [8:0] nrz_phase2_tx;
    reg [1:0] nrz_delay2_tx;
    reg [1:0] mimo_mode_tx;

    reg [2:0] cmd_toggle_sync_tx;
    reg       cmd_toggle_seen_tx;

    reg [2:0] text_capture_reset_sync_tx;
    reg       text_capture_reset_seen_tx;
    reg       text_capture_reset_pulse_tx;

    // ============================================================
    // User Text TX memory and decoded RX text memory
    // ============================================================
    localparam integer USER_TEXT_MAX = 32;

    reg [7:0] user_text_mem [0:USER_TEXT_MAX-1];
    wire [7:0] rx_text_mem   [0:USER_TEXT_MAX-1];

    reg [5:0] user_text_len;
    reg [5:0] user_text_tx_index;

    reg [23:0] text_rx_shift;
    reg [4:0]  text_rx_count;
    reg [5:0]  text_rx_index;
    reg text_ready_ft, text_wait_low_ft, text_rearm_seen_ft;
    reg [255:0] text_data_ft;
    wire [255:0] text_source_bus;
    reg text_v23_request_toggle_ft, text_v23_pending_ft, text_v23_ready_ft;
    reg [31:0] text_v23_request_token_ft;
    reg text_v23_response_toggle_tx;
    reg [255:0] text_v23_data_tx, text_v23_data_ft;
    reg [31:0] text_v23_status_tx, text_v23_status_ft;
    reg [31:0] text_v23_token_tx, text_v23_token_ft;
    reg [31:0] text_v23_epoch_tx, text_v23_epoch_ft;
    reg [31:0] text_v23_payload_bits_tx, text_v23_payload_bits_ft;
    reg [31:0] text_v23_payload_errors_tx, text_v23_payload_errors_ft;
    // V23I diagnostics are frozen by the same request/token as the text.
    reg [31:0] text_diag_bytes_tx, text_diag_bytes_ft;
    reg [31:0] text_diag_commits_tx, text_diag_commits_ft;
    reg [31:0] text_diag_first_tx, text_diag_first_ft;
    reg [31:0] text_diag_flags_tx, text_diag_flags_ft;
    reg [7:0] text_last_loaded_tx;
    reg text_loaded_seen, text_decoded_seen;
    reg [31:0] text_commit_count;
    reg [7:0] text_last_committed;


    integer user_mem_i;
    integer rx_mem_i;


    // ============================================================
    // Manual board-test blink mode
    // clk_250 = 250 MHz
    // blink_state toggles every 1 second
    // ============================================================
    localparam [27:0] BLINK_1S_TICKS = 28'd250_000_000;

    reg [27:0] blink_counter = 28'd0;
    reg        blink_state   = 1'b0;

    // Synchronise physical switch into clk_250 domain
    reg blink_sw_meta = 1'b0;
    reg blink_sw_tx   = 1'b0;

    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            blink_sw_meta <= 1'b0;
            blink_sw_tx   <= 1'b0;
        end else begin
            blink_sw_meta <= blink_sw;
            blink_sw_tx   <= blink_sw_meta;
        end
    end

    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            blink_counter <= 28'd0;
            blink_state   <= 1'b0;
        end else if (soft_reset_pulse_tx) begin
            blink_counter <= 28'd0;
            blink_state   <= 1'b0;
        end else begin
            if (blink_sw_tx) begin
                if (blink_counter == BLINK_1S_TICKS - 28'd1) begin
                    blink_counter <= 28'd0;
                    blink_state   <= ~blink_state;
                end else begin
                    blink_counter <= blink_counter + 28'd1;
                end
            end else begin
                blink_counter <= 28'd0;
                blink_state   <= 1'b0;
            end
        end
    end

    // ============================================================
    // Speed timing with 250 MHz data-plane clock
    //
    // 1 Mbps  = 250 ticks
    // 2 Mbps  = 125 ticks
    // 5 Mbps  = 50 ticks
    // 10 Mbps = 25 ticks
    // 25 Mbps = 10 ticks
    // 50 Mbps = 5 ticks
    // ============================================================
    localparam [8:0] TICKS_1M  = 9'd250;
    localparam [8:0] TICKS_2M  = 9'd125;
    localparam [8:0] TICKS_5M  = 9'd50;
    localparam [8:0] TICKS_10M = 9'd25;
    localparam [8:0] TICKS_25M = 9'd10;
    localparam [8:0] TICKS_50M = 9'd5;

    // Data type modes
    localparam [2:0] MODE_PRBS7     = 3'd0;
    localparam [2:0] MODE_PRBS15    = 3'd1;
    localparam [2:0] MODE_ASCII_S   = 3'd2;
    localparam [2:0] MODE_COUNTER   = 3'd3;
    localparam [2:0] MODE_USER_TEXT = 3'd4;

    // Modulation modes
    localparam [1:0] MOD_OOK_NRZ = 2'b00;
    localparam [1:0] MOD_OOK_RZ  = 2'b01;
    localparam [1:0] MOD_PWM     = 2'b10;
    localparam [1:0] MOD_PPM     = 2'b11;

    // Coding modes
    localparam [1:0] CODE_NONE    = 2'b00;
    localparam [1:0] CODE_CRC8    = 2'b01;
    localparam [1:0] CODE_REPEAT3 = 2'b10;
    localparam [1:0] CODE_HAMMING = 2'b11;

    // ============================================================
    // Convert command bytes to active data-plane settings
    // ============================================================
    // Decode on command acceptance, not on every 250 MHz data-plane edge.
    // These values change on the SAME edge as the corresponding command bytes.
    // Keeping the terminal phase explicit removes the speed-mux/subtractor
    // chain from bit_phase and TX frame-completion control.
    reg [2:0] active_mode;
    reg [1:0] active_code;
    reg [8:0] active_bit_ticks;
    reg [8:0] active_last_phase;
    reg [8:0] active_penultimate_phase;
    reg [1:0] active_mod;
    wire user_text_active = (active_mode == MODE_USER_TEXT);

    function [2:0] decode_command_mode;
        input [7:0] command_byte;
        begin
            case (command_byte)
                "A": decode_command_mode = MODE_PRBS7;
                "B": decode_command_mode = MODE_PRBS15;
                "C": decode_command_mode = MODE_ASCII_S;
                "D": decode_command_mode = MODE_COUNTER;
                "U": decode_command_mode = MODE_USER_TEXT;
                default: decode_command_mode = MODE_ASCII_S;
            endcase
        end
    endfunction

    function [1:0] decode_command_code;
        input [7:0] command_byte;
        begin
            case (command_byte)
                "F": decode_command_code = CODE_CRC8;
                "Q": decode_command_code = CODE_REPEAT3;
                "R": decode_command_code = CODE_HAMMING;
                default: decode_command_code = CODE_NONE;
            endcase
        end
    endfunction

    function [1:0] decode_command_mod;
        input [7:0] command_byte;
        begin
            case (command_byte)
                "H": decode_command_mod = MOD_OOK_RZ;
                "I": decode_command_mod = MOD_PWM;
                "J": decode_command_mod = MOD_PPM;
                default: decode_command_mod = MOD_OOK_NRZ;
            endcase
        end
    endfunction

    // ============================================================
    // TX bit timing registers and Status/RX counters in clk_250 domain
    // ============================================================
    reg [8:0]  bit_phase;
    reg bit_start_tick, bit_end_tick;
    reg        data_bit;

    // Line-level counters: compare coded/waveform samples before decoding.
    wire [31:0] tx_line_bits; // Retained legacy launched-bit diagnostic.
    wire [31:0] tx_frame_bits; // Line bits in fully completed encoded frames.
    reg        tx_last_bit_pending;
    reg [4:0]  tx_last_frame_len;
    reg        tx_frame_done_pending;
    reg [4:0]  tx_frame_done_len;
    reg [31:0] rx_total_bits;
    reg [31:0] rx_error_bits;
    reg [31:0] rx2_total_bits;
    reg [31:0] rx2_error_bits;

    // Payload-level counters: compare decoded payload bits after coding.
    // These are the main BER values returned to the GUI.
    reg [31:0] payload_tx_bits;
    reg [31:0] payload_rx_bits;
    reg [31:0] payload_error_bits;
    reg [23:0] payload_rx_shift;
    reg [23:0] payload_tx_shift;
    reg [4:0]  payload_bit_count;

    // Coherent status snapshot crossing from clk_250 to ft_clk. All nine
    // RX1/RX2/payload/line counters are captured together and held stable,
    // then accepted in ft_clk
    // only after a synchronized snapshot toggle arrives.
    localparam [17:0] STATUS_SNAPSHOT_MAX = 18'd249999; // 1 ms at 250 MHz
    reg [17:0] status_snapshot_div;
    reg        status_snapshot_toggle_tx;

    reg [31:0] payload_tx_bits_snapshot_tx;
    reg [31:0] payload_rx_bits_snapshot_tx;
    reg [31:0] payload_error_bits_snapshot_tx;
    reg [31:0] tx_line_bits_snapshot_tx;
    reg [31:0] tx_frame_bits_snapshot_tx;
    reg [31:0] rx_total_bits_snapshot_tx;
    reg [31:0] rx_error_bits_snapshot_tx;
    reg [31:0] rx2_total_bits_snapshot_tx;
    reg [31:0] rx2_error_bits_snapshot_tx;
    reg        rx_locked_snapshot_tx;
    reg        rx2_locked_snapshot_tx;
    reg        diversity_mode_snapshot_tx;
    reg        selected_rx2_snapshot_tx;
    reg        tx_enable_snapshot_tx;
    reg        rx_supported_snapshot_tx;
    reg        blink_sw_snapshot_tx;
    reg        payload_rx_supported_snapshot_tx;

    reg [31:0] payload_tx_bits_meta_ft;
    reg [31:0] payload_rx_bits_meta_ft;
    reg [31:0] payload_error_bits_meta_ft;
    reg [31:0] tx_line_bits_meta_ft;
    reg [31:0] tx_frame_bits_meta_ft;
    reg [31:0] rx_total_bits_meta_ft;
    reg [31:0] rx_error_bits_meta_ft;
    reg [31:0] rx2_total_bits_meta_ft;
    reg [31:0] rx2_error_bits_meta_ft;
    reg        rx_locked_meta_ft;
    reg        rx2_locked_meta_ft;
    reg        diversity_mode_meta_ft;
    reg        selected_rx2_meta_ft;
    reg        tx_enable_meta_ft;
    reg        rx_supported_meta_ft;
    reg        blink_sw_meta_ft;
    reg        payload_rx_supported_meta_ft;

    reg [31:0] payload_tx_bits_sync_ft;
    reg [31:0] payload_rx_bits_sync_ft;
    reg [31:0] payload_error_bits_sync_ft;
    reg [31:0] tx_line_bits_sync_ft;
    reg [31:0] tx_frame_bits_sync_ft;
    reg [31:0] rx_total_bits_sync_ft;
    reg [31:0] rx_error_bits_sync_ft;
    reg [31:0] rx2_total_bits_sync_ft;
    reg [31:0] rx2_error_bits_sync_ft;
    reg        rx_locked_sync_ft;
    reg        rx2_locked_sync_ft;
    reg        diversity_mode_sync_ft;
    reg        selected_rx2_sync_ft;
    reg        tx_enable_sync_ft;
    reg        rx_supported_sync_ft;
    reg        blink_sw_sync_ft;
    reg        payload_rx_supported_sync_ft;

    reg [31:0] payload_tx_bits_status_ft;
    reg [31:0] payload_rx_bits_status_ft;
    reg [31:0] payload_error_bits_status_ft;
    reg [31:0] tx_line_bits_status_ft;
    reg [31:0] tx_frame_bits_status_ft;
    reg [31:0] rx_total_bits_status_ft;
    reg [31:0] rx_error_bits_status_ft;
    reg [31:0] rx2_total_bits_status_ft;
    reg [31:0] rx2_error_bits_status_ft;
    reg        rx_locked_status_ft;
    reg        rx2_locked_status_ft;
    reg        diversity_mode_status_ft;
    reg        selected_rx2_status_ft;
    reg        tx_enable_status_ft;
    reg        rx_supported_status_ft;
    reg        blink_sw_status_ft;
    reg        payload_rx_supported_status_ft;

    reg [2:0] status_snapshot_toggle_sync_ft;
    reg       status_snapshot_toggle_seen_ft;

    // IDs 1,2,3 are returned as one coherent line-BER query group. ID 1
    // latches these companions so later USB reads cannot mix snapshots.
    reg [31:0] payload_rx_bits_query_ft;
    reg [31:0] payload_error_bits_query_ft;
    reg [31:0] line_error_bits_query_ft;
    reg [31:0] rx2_total_bits_query_ft;
    reg [31:0] rx2_error_bits_query_ft;
    reg [31:0] status_word_query_ft;
    reg [31:0] legacy_tx_bits_query_ft;
    reg [2:0]  ber_query_stage_ft;

    // One accepted CDC snapshot supplies every status flag. ID 1 freezes this
    // byte together with both receivers' counters for the complete periodic
    // query sequence ID 1,2,3,28,29,4.
    wire [7:0] status_flags_ft;

    // Clean payload-frame collector.
    // The previous decoder could start counting in the middle of an encoded
    // frame after RX lock, which caused BER even with a clean loopback.
    // This collector only starts on the sampled first bit of a TX encoded frame.
    reg        payload_collecting;
    reg [4:0]  payload_frame_len;
    reg [1:0]  payload_frame_code;
    reg [5:0]  payload_frame_text_index;

    // TX frame-boundary information held through the current line bit.
    // frame_start_bit is asserted during the first line bit of each encoded frame.
    reg        frame_start_bit;
    reg [4:0]  frame_len_latched;
    reg [1:0]  frame_code_latched;
    reg [5:0]  frame_text_index_latched;

    // Three-bit TX-reference history. At 50 Mbps one bit is only 20 ns, so the
    // same receiver latency can require two or more whole-bit delays.
    reg        data_bit_previous;
    reg        data_bit_previous2;
    reg        data_bit_previous3;
    reg        frame_start_bit_previous;
    reg        frame_start_bit_previous2;
    reg        frame_start_bit_previous3;
    reg [4:0]  frame_len_latched_previous;
    reg [4:0]  frame_len_latched_previous2;
    reg [4:0]  frame_len_latched_previous3;
    reg [1:0]  frame_code_latched_previous;
    reg [1:0]  frame_code_latched_previous2;
    reg [1:0]  frame_code_latched_previous3;
    reg [5:0]  frame_text_index_latched_previous;
    reg [5:0]  frame_text_index_latched_previous2;
    reg [5:0]  frame_text_index_latched_previous3;

    reg        rx_meta;
    reg        rx_sync;
    reg        rx_locked;
    reg [4:0]  rx_match_count;
    reg [5:0]  rx_health_count;
    reg [5:0]  rx_health_errors;
    reg        rx2_meta;
    reg        rx2_sync;
    reg        rx2_locked;
    reg [4:0]  rx2_match_count;
    reg [5:0]  rx2_health_count;
    reg [5:0]  rx2_health_errors;

    // Acquisition needs 16 consecutive matches. Once locked, a 32-sample
    // health window drops lock at 8 or more mismatches (25%); this catches a
    // lost/stuck beam while avoiding chatter from sparse line errors.
    localparam [5:0] RX_HEALTH_WINDOW_LAST  = 6'd31;
    localparam [5:0] RX_HEALTH_UNLOCK_ERRORS = 6'd8;

    // Selection-diversity quality estimator. Each receiver keeps its own
    // checked-bit and error exposure for the previous one-second window.
    // Equal BER deliberately keeps the selected branch to prevent chatter.
    localparam [27:0] QUALITY_WINDOW_MAX = 28'd249_999_999;
    reg [27:0] quality_window_count;
    reg [31:0] rx1_window_bits;
    reg [31:0] rx2_window_bits;
    reg [31:0] rx1_window_errors;
    reg [31:0] rx2_window_errors;
    reg [31:0] rx1_previous_window_bits;
    reg [31:0] rx2_previous_window_bits;
    reg [31:0] rx1_previous_window_errors;
    reg [31:0] rx2_previous_window_errors;
    reg        preferred_rx2;
    reg        selected_rx2;

    // Exact normalized BER comparison, pipelined over eight core clocks.
    // Window exposure and frame-boundary switching remain unchanged.
    wire quality_compare_cancel;
    wire quality_compare_start = !quality_compare_cancel &&
        (quality_window_count == QUALITY_WINDOW_MAX) &&
        (rx1_window_bits != 32'd0) && (rx2_window_bits != 32'd0);
    wire quality_compare_valid, quality_rx2_better, quality_rx1_better;
    ExactDivCompare16 quality_compare (
        .clk(clk_250), .reset_n(reset_n), .cancel(quality_compare_cancel),
        .start(quality_compare_start),
        .bits1(rx1_window_bits), .errors1(rx1_window_errors),
        .bits2(rx2_window_bits), .errors2(rx2_window_errors),
        .result_valid(quality_compare_valid),
        .rx2_better(quality_rx2_better), .rx1_better(quality_rx1_better)
    );

    // PPM early/late demodulator counters.
    // For PPM, the receiver must recover the data bit from pulse position,
    // not from a single sampled level.
    reg [8:0] ppm_early_count;
    reg [8:0] ppm_late_count;

    wire [8:0] ppm_mid_phase;
    wire [8:0] ppm_early_count_now;
    wire [8:0] ppm_late_count_now;
    wire       ppm_decision_bit;
    wire       demod_rx_bit;
    wire       demod_sample_tick;

    wire rx_rate_supported;
    wire rx_supported;
    wire rx2_supported;
    wire text_rx_supported;
    wire payload_rx_supported;
    wire diversity_mode;
    assign smp_mode = (mimo_mode_tx == MIMO_SMP);

    wire [8:0] nrz_sample_phase;
    wire [8:0] rz_sample_phase;
    wire [8:0] pwm_sample_phase;
    wire [8:0] ppm_zero_sample_phase;
    wire [8:0] ppm_one_sample_phase;
    wire [8:0] ppm_sample_phase;
    wire [8:0] rx_sample_phase;
    wire       rx_sample_tick;
    wire       rx_expected_level;
    wire       rx_sample_value;
    wire [8:0] active_nrz_phase;
    wire [1:0] active_nrz_delay;
    wire [8:0] active_nrz_phase2;
    wire [1:0] active_nrz_delay2;
    wire [1:0] effective_reference_delay;
    wire [1:0] effective_reference_delay2;
    wire       use_delayed_line_bit;
    wire       aligned_data_bit;
    wire       aligned_frame_start_bit;
    wire [4:0] aligned_frame_len;
    wire [1:0] aligned_frame_code;
    wire [5:0] aligned_frame_text_index;
    wire       rx2_sample_tick;
    wire       rx2_demod_bit;
    wire       aligned2_data_bit;
    wire       aligned2_frame_start_bit;
    wire [4:0] aligned2_frame_len;
    wire [1:0] aligned2_frame_code;
    wire [5:0] aligned2_frame_text_index;

    // Common decoder mux. A pending branch change is accepted on the new
    // branch's own aligned encoded-frame boundary, allowing that first bit to
    // enter the decoder on the same clk_250 edge as the selection update.
    wire       requested_rx2;
    wire       switch_to_rx2_at_boundary;
    wire       switch_to_rx1_at_boundary;
    wire       selected_rx2_for_mux;
    wire       selected_rx_locked;
    wire       selected_sample_tick;
    wire       selected_demod_rx_bit;
    wire       selected_aligned_data_bit;
    wire       selected_aligned_frame_start_bit;
    wire [4:0] selected_aligned_frame_len;
    wire [1:0] selected_aligned_frame_code;
    wire [5:0] selected_aligned_frame_text_index;

    // Measured stable digital-loopback limits for the current setup:
    // OOK-NRZ : runtime phase/delay tuning enabled up to 50 Mbps
    // OOK-RZ  : stable up to 10 Mbps
    // PWM     : stable up to 5 Mbps
    // PPM     : stable up to 5 Mbps
    // Higher rates can still be transmitted, but RX/status BER is marked unsupported
    // until we tune the sampling windows later.
    assign rx_rate_supported =
        ((active_mod == MOD_OOK_NRZ) &&
            ((active_bit_ticks == TICKS_1M)  ||
             (active_bit_ticks == TICKS_2M)  ||
             (active_bit_ticks == TICKS_5M)  ||
             (active_bit_ticks == TICKS_10M) ||
             (active_bit_ticks == TICKS_25M) ||
             (active_bit_ticks == TICKS_50M))) ||

        ((active_mod == MOD_OOK_RZ) &&
            ((active_bit_ticks == TICKS_1M)  ||
             (active_bit_ticks == TICKS_2M)  ||
             (active_bit_ticks == TICKS_5M)  ||
             (active_bit_ticks == TICKS_10M))) ||

        (((active_mod == MOD_PWM) || (active_mod == MOD_PPM)) &&
            ((active_bit_ticks == TICKS_1M)  ||
             (active_bit_ticks == TICKS_2M)  ||
             (active_bit_ticks == TICKS_5M)));

    // RX/status support follows the measured stable limits above.
    assign rx_supported =
        tx_enable_tx &&
        !blink_sw_tx &&
        (!smp_mode || (active_mod == MOD_OOK_NRZ)) &&
        rx_rate_supported;

    assign diversity_mode = (mimo_mode_tx == MIMO_DIV);

    // V2.1 RX2 is deliberately limited to the requested first-stage
    // diversity mode: same-polarity OOK-NRZ at any of the six supported rates.
    assign rx2_supported =
        (diversity_mode || smp_mode) &&
        tx_enable_tx &&
        !blink_sw_tx &&
        (active_mod == MOD_OOK_NRZ) &&
        ((active_bit_ticks == TICKS_1M)  ||
         (active_bit_ticks == TICKS_2M)  ||
         (active_bit_ticks == TICKS_5M)  ||
         (active_bit_ticks == TICKS_10M) ||
         (active_bit_ticks == TICKS_25M) ||
         (active_bit_ticks == TICKS_50M));

    // Payload/text decoding is now enabled for all modulation modes
    // inside the measured stable limits, including PPM.
    assign text_rx_supported    = rx_supported && user_text_active;
    assign payload_rx_supported = rx_supported;

    assign active_nrz_phase = nrz_phase_tx;
    assign active_nrz_delay = nrz_delay_tx;
    assign active_nrz_phase2 = nrz_phase2_tx;
    assign active_nrz_delay2 = nrz_delay2_tx;

    // OOK-NRZ: sample after the data has settled, near the middle of the bit.
    assign nrz_sample_phase = active_nrz_phase;

    // OOK-RZ: sample inside the early high window for a logic 1.
    assign rz_sample_phase =
        (active_bit_ticks == TICKS_1M)  ? 9'd64 :
        (active_bit_ticks == TICKS_2M)  ? 9'd32 :
        (active_bit_ticks == TICKS_5M)  ? 9'd14 :
        (active_bit_ticks == TICKS_10M) ? 9'd7  :
        (active_bit_ticks == TICKS_25M) ? 9'd5  :
        (active_bit_ticks == TICKS_50M) ? 9'd3  :
                                          (active_bit_ticks >> 2);

    // PWM: sample between the short-width 0 pulse and the long-width 1 pulse.
    // At this point, expected level is 0 for data 0 and 1 for data 1.
    assign pwm_sample_phase =
        (active_bit_ticks == TICKS_1M)  ? 9'd127 :
        (active_bit_ticks == TICKS_2M)  ? 9'd64  :
        (active_bit_ticks == TICKS_5M)  ? 9'd25  :
        (active_bit_ticks == TICKS_10M) ? 9'd13  :
        (active_bit_ticks == TICKS_25M) ? 9'd6   :
        (active_bit_ticks == TICKS_50M) ? 9'd4   :
                                          (active_bit_ticks >> 1);

    // PPM payload demodulation uses an early/late counter.
    // 0 = pulse in the early half, 1 = pulse in the late half.
    assign ppm_mid_phase = (active_bit_ticks >> 1);

    assign ppm_early_count_now =
        ppm_early_count + ((rx_sync && (bit_phase < ppm_mid_phase)) ? 9'd1 : 9'd0);

    assign ppm_late_count_now =
        ppm_late_count + ((rx_sync && (bit_phase >= ppm_mid_phase)) ? 9'd1 : 9'd0);

    assign ppm_decision_bit =
        (ppm_late_count_now > ppm_early_count_now);

    assign rx_sample_phase =
        (active_mod == MOD_OOK_NRZ) ? nrz_sample_phase :
        (active_mod == MOD_OOK_RZ)  ? rz_sample_phase  :
        (active_mod == MOD_PWM)     ? pwm_sample_phase :
                                      (active_last_phase);

    // For OOK/PWM, the recovered data bit is the sampled level.
    // For PPM, the recovered data bit is the early/late pulse-position decision.
    assign rx_sample_value = rx_sync;

    assign rx_sample_tick =
        rx_supported &&
        (
            ((active_mod != MOD_PPM) && (bit_phase == rx_sample_phase)) ||
            ((active_mod == MOD_PPM) && bit_end_tick)
        );

    assign demod_sample_tick = rx_sample_tick;

    assign demod_rx_bit =
        (active_mod == MOD_PPM) ? ppm_decision_bit : rx_sample_value;

    // Apply the programmable whole-bit alignment to every OOK-NRZ rate.
    // Low-rate local sweeps use delay 0; high-rate defaults use delay 1 or 3.
    assign use_delayed_line_bit = (active_mod == MOD_OOK_NRZ);

    // At phase 0 the TX nonblocking update has not taken effect, so data_bit
    // already describes the preceding nominal bit. Compensate by reducing the
    // requested history index by one only for that sampling edge.
    assign effective_reference_delay =
        (use_delayed_line_bit && bit_start_tick &&
         (active_nrz_delay != 2'd0)) ?
            (active_nrz_delay - 2'd1) : active_nrz_delay;

    assign aligned_data_bit =
        !use_delayed_line_bit                     ? data_bit :
        (effective_reference_delay == 2'd0)       ? data_bit :
        (effective_reference_delay == 2'd1)       ? data_bit_previous :
        (effective_reference_delay == 2'd2)       ? data_bit_previous2 :
                                                    data_bit_previous3;

    assign aligned_frame_start_bit =
        !use_delayed_line_bit                     ? frame_start_bit :
        (effective_reference_delay == 2'd0)       ? frame_start_bit :
        (effective_reference_delay == 2'd1)       ? frame_start_bit_previous :
        (effective_reference_delay == 2'd2)       ? frame_start_bit_previous2 :
                                                    frame_start_bit_previous3;

    assign aligned_frame_len =
        !use_delayed_line_bit                     ? frame_len_latched :
        (effective_reference_delay == 2'd0)       ? frame_len_latched :
        (effective_reference_delay == 2'd1)       ? frame_len_latched_previous :
        (effective_reference_delay == 2'd2)       ? frame_len_latched_previous2 :
                                                    frame_len_latched_previous3;

    assign aligned_frame_code =
        !use_delayed_line_bit                     ? frame_code_latched :
        (effective_reference_delay == 2'd0)       ? frame_code_latched :
        (effective_reference_delay == 2'd1)       ? frame_code_latched_previous :
        (effective_reference_delay == 2'd2)       ? frame_code_latched_previous2 :
                                                    frame_code_latched_previous3;

    assign aligned_frame_text_index =
        !use_delayed_line_bit                     ? frame_text_index_latched :
        (effective_reference_delay == 2'd0)       ? frame_text_index_latched :
        (effective_reference_delay == 2'd1)       ? frame_text_index_latched_previous :
        (effective_reference_delay == 2'd2)       ? frame_text_index_latched_previous2 :
                                                    frame_text_index_latched_previous3;

    // Line-level expected bit after demodulation and timing alignment.
    assign rx_expected_level = aligned_data_bit;

    // RX2 has an independent fractional-bit sample phase and whole-bit TX
    // reference alignment. SMP compares against lane 2's own data history.
    // Frame boundaries/code/length are shared because both serializers use
    // the same rate and code, with each lane applying its own exact delay.
    assign rx2_sample_tick =
        rx2_supported && (bit_phase == active_nrz_phase2);

    assign rx2_demod_bit = rx2_sync;

    assign effective_reference_delay2 =
        (bit_start_tick && (active_nrz_delay2 != 2'd0)) ?
            (active_nrz_delay2 - 2'd1) : active_nrz_delay2;

    assign aligned2_data_bit =
        smp_mode ?
            ((effective_reference_delay2 == 2'd0) ? data_bit2 :
             (effective_reference_delay2 == 2'd1) ? data_bit2_previous :
             (effective_reference_delay2 == 2'd2) ? data_bit2_previous2 :
                                                   data_bit2_previous3) :
            ((effective_reference_delay2 == 2'd0) ? data_bit :
             (effective_reference_delay2 == 2'd1) ? data_bit_previous :
             (effective_reference_delay2 == 2'd2) ? data_bit_previous2 :
                                                   data_bit_previous3);

    assign aligned2_frame_start_bit =
        (effective_reference_delay2 == 2'd0) ? frame_start_bit :
        (effective_reference_delay2 == 2'd1) ? frame_start_bit_previous :
        (effective_reference_delay2 == 2'd2) ? frame_start_bit_previous2 :
                                               frame_start_bit_previous3;

    assign aligned2_frame_len =
        (effective_reference_delay2 == 2'd0) ? frame_len_latched :
        (effective_reference_delay2 == 2'd1) ? frame_len_latched_previous :
        (effective_reference_delay2 == 2'd2) ? frame_len_latched_previous2 :
                                               frame_len_latched_previous3;

    assign aligned2_frame_code =
        (effective_reference_delay2 == 2'd0) ? frame_code_latched :
        (effective_reference_delay2 == 2'd1) ? frame_code_latched_previous :
        (effective_reference_delay2 == 2'd2) ? frame_code_latched_previous2 :
                                               frame_code_latched_previous3;

    assign aligned2_frame_text_index =
        (effective_reference_delay2 == 2'd0) ? frame_text_index_latched :
        (effective_reference_delay2 == 2'd1) ? frame_text_index_latched_previous :
        (effective_reference_delay2 == 2'd2) ? frame_text_index_latched_previous2 :
                                               frame_text_index_latched_previous3;

    // A lock override changes the requested branch immediately. The actual
    // selected_rx2 register changes only when the requested receiver presents
    // the first sampled bit of an encoded frame.
    assign requested_rx2 =
        !diversity_mode             ? 1'b0 :
        (rx2_locked && !rx_locked)  ? 1'b1 :
        (rx_locked && !rx2_locked)  ? 1'b0 :
                                      preferred_rx2;

    assign switch_to_rx2_at_boundary =
        diversity_mode && !selected_rx2 && requested_rx2 && rx2_locked &&
        rx2_sample_tick && aligned2_frame_start_bit;

    assign switch_to_rx1_at_boundary =
        diversity_mode && selected_rx2 && !requested_rx2 && rx_locked &&
        rx_sample_tick && aligned_frame_start_bit;

    assign selected_rx2_for_mux =
        !diversity_mode               ? 1'b0 :
        switch_to_rx2_at_boundary     ? 1'b1 :
        switch_to_rx1_at_boundary     ? 1'b0 :
                                        selected_rx2;

    assign selected_rx_locked =
        selected_rx2_for_mux ? rx2_locked : rx_locked;
    assign selected_sample_tick =
        selected_rx2_for_mux ? rx2_sample_tick : rx_sample_tick;
    assign selected_demod_rx_bit =
        selected_rx2_for_mux ? rx2_demod_bit : demod_rx_bit;
    assign selected_aligned_data_bit =
        selected_rx2_for_mux ? aligned2_data_bit : aligned_data_bit;
    assign selected_aligned_frame_start_bit =
        selected_rx2_for_mux ? aligned2_frame_start_bit : aligned_frame_start_bit;
    assign selected_aligned_frame_len =
        selected_rx2_for_mux ? aligned2_frame_len : aligned_frame_len;
    assign selected_aligned_frame_code =
        selected_rx2_for_mux ? aligned2_frame_code : aligned_frame_code;
    assign selected_aligned_frame_text_index =
        selected_rx2_for_mux ? aligned2_frame_text_index : aligned_frame_text_index;

    // ============================================================
    // Coherent counter snapshots: clk_250 -> ft_clk bundled-data CDC
    // ============================================================
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            status_snapshot_div              <= 18'd0;
            status_snapshot_toggle_tx        <= 1'b0;
            payload_tx_bits_snapshot_tx      <= 32'd0;
            payload_rx_bits_snapshot_tx      <= 32'd0;
            payload_error_bits_snapshot_tx   <= 32'd0;
            tx_line_bits_snapshot_tx         <= 32'd0;
            tx_frame_bits_snapshot_tx         <= 32'd0;
            rx_total_bits_snapshot_tx        <= 32'd0;
            rx_error_bits_snapshot_tx        <= 32'd0;
            rx2_total_bits_snapshot_tx       <= 32'd0;
            rx2_error_bits_snapshot_tx       <= 32'd0;
            rx_locked_snapshot_tx            <= 1'b0;
            rx2_locked_snapshot_tx           <= 1'b0;
            diversity_mode_snapshot_tx       <= 1'b0;
            selected_rx2_snapshot_tx         <= 1'b0;
            tx_enable_snapshot_tx            <= 1'b0;
            rx_supported_snapshot_tx         <= 1'b0;
            blink_sw_snapshot_tx             <= 1'b0;
            payload_rx_supported_snapshot_tx <= 1'b0;
        end else if (tx_restart_pulse_tx || soft_reset_pulse_tx) begin
            status_snapshot_div              <= 18'd0;
            status_snapshot_toggle_tx        <= ~status_snapshot_toggle_tx;
            payload_tx_bits_snapshot_tx      <= 32'd0;
            payload_rx_bits_snapshot_tx      <= 32'd0;
            payload_error_bits_snapshot_tx   <= 32'd0;
            tx_line_bits_snapshot_tx         <= 32'd0;
            tx_frame_bits_snapshot_tx         <= 32'd0;
            rx_total_bits_snapshot_tx        <= 32'd0;
            rx_error_bits_snapshot_tx        <= 32'd0;
            rx2_total_bits_snapshot_tx       <= 32'd0;
            rx2_error_bits_snapshot_tx       <= 32'd0;
            rx_locked_snapshot_tx            <= 1'b0;
            rx2_locked_snapshot_tx           <= 1'b0;
            diversity_mode_snapshot_tx       <= diversity_mode;
            selected_rx2_snapshot_tx         <= 1'b0;
            tx_enable_snapshot_tx            <= tx_enable_tx;
            rx_supported_snapshot_tx         <= 1'b0;
            blink_sw_snapshot_tx             <= blink_sw_tx;
            payload_rx_supported_snapshot_tx <= 1'b0;
        end else if (status_snapshot_div == STATUS_SNAPSHOT_MAX) begin
            status_snapshot_div              <= 18'd0;
            status_snapshot_toggle_tx        <= ~status_snapshot_toggle_tx;
            payload_tx_bits_snapshot_tx      <= payload_tx_bits;
            payload_rx_bits_snapshot_tx      <= payload_rx_bits;
            payload_error_bits_snapshot_tx   <= payload_error_bits;
            tx_line_bits_snapshot_tx         <= tx_line_bits;
            tx_frame_bits_snapshot_tx         <= tx_frame_bits;
            rx_total_bits_snapshot_tx        <= rx_total_bits;
            rx_error_bits_snapshot_tx        <= rx_error_bits;
            rx2_total_bits_snapshot_tx       <= rx2_total_bits;
            rx2_error_bits_snapshot_tx       <= rx2_error_bits;
            rx_locked_snapshot_tx            <= rx_locked;
            rx2_locked_snapshot_tx           <= rx2_locked;
            diversity_mode_snapshot_tx       <= diversity_mode;
            selected_rx2_snapshot_tx         <= selected_rx2;
            tx_enable_snapshot_tx            <= tx_enable_tx;
            rx_supported_snapshot_tx         <= rx_supported;
            blink_sw_snapshot_tx             <= blink_sw_tx;
            payload_rx_supported_snapshot_tx <= payload_rx_supported;
        end else begin
            status_snapshot_div <= status_snapshot_div + 18'd1;
        end
    end

    always @(posedge ft_clk or negedge reset_n) begin
        if (!reset_n) begin
            payload_tx_bits_meta_ft          <= 32'd0;
            payload_rx_bits_meta_ft          <= 32'd0;
            payload_error_bits_meta_ft       <= 32'd0;
            tx_line_bits_meta_ft             <= 32'd0;
            tx_frame_bits_meta_ft             <= 32'd0;
            rx_total_bits_meta_ft            <= 32'd0;
            rx_error_bits_meta_ft            <= 32'd0;
            rx2_total_bits_meta_ft           <= 32'd0;
            rx2_error_bits_meta_ft           <= 32'd0;
            rx_locked_meta_ft                <= 1'b0;
            rx2_locked_meta_ft               <= 1'b0;
            diversity_mode_meta_ft           <= 1'b0;
            selected_rx2_meta_ft             <= 1'b0;
            tx_enable_meta_ft                <= 1'b0;
            rx_supported_meta_ft             <= 1'b0;
            blink_sw_meta_ft                 <= 1'b0;
            payload_rx_supported_meta_ft     <= 1'b0;

            payload_tx_bits_sync_ft          <= 32'd0;
            payload_rx_bits_sync_ft          <= 32'd0;
            payload_error_bits_sync_ft       <= 32'd0;
            tx_line_bits_sync_ft             <= 32'd0;
            tx_frame_bits_sync_ft             <= 32'd0;
            rx_total_bits_sync_ft            <= 32'd0;
            rx_error_bits_sync_ft            <= 32'd0;
            rx2_total_bits_sync_ft           <= 32'd0;
            rx2_error_bits_sync_ft           <= 32'd0;
            rx_locked_sync_ft                <= 1'b0;
            rx2_locked_sync_ft               <= 1'b0;
            diversity_mode_sync_ft           <= 1'b0;
            selected_rx2_sync_ft             <= 1'b0;
            tx_enable_sync_ft                <= 1'b0;
            rx_supported_sync_ft             <= 1'b0;
            blink_sw_sync_ft                 <= 1'b0;
            payload_rx_supported_sync_ft     <= 1'b0;

            payload_tx_bits_status_ft        <= 32'd0;
            payload_rx_bits_status_ft        <= 32'd0;
            payload_error_bits_status_ft     <= 32'd0;
            tx_line_bits_status_ft           <= 32'd0;
            tx_frame_bits_status_ft           <= 32'd0;
            rx_total_bits_status_ft          <= 32'd0;
            rx_error_bits_status_ft          <= 32'd0;
            rx2_total_bits_status_ft         <= 32'd0;
            rx2_error_bits_status_ft         <= 32'd0;
            rx_locked_status_ft              <= 1'b0;
            rx2_locked_status_ft              <= 1'b0;
            diversity_mode_status_ft          <= 1'b0;
            selected_rx2_status_ft            <= 1'b0;
            tx_enable_status_ft               <= 1'b0;
            rx_supported_status_ft             <= 1'b0;
            blink_sw_status_ft                 <= 1'b0;
            payload_rx_supported_status_ft     <= 1'b0;

            status_snapshot_toggle_sync_ft   <= 3'b000;
            status_snapshot_toggle_seen_ft   <= 1'b0;
        end else begin
            // The two bus stages settle before the three-stage event toggle
            // reaches the acceptance test below.
            payload_tx_bits_meta_ft        <= payload_tx_bits_snapshot_tx;
            payload_rx_bits_meta_ft        <= payload_rx_bits_snapshot_tx;
            payload_error_bits_meta_ft     <= payload_error_bits_snapshot_tx;
            tx_line_bits_meta_ft           <= tx_line_bits_snapshot_tx;
            tx_frame_bits_meta_ft           <= tx_frame_bits_snapshot_tx;
            rx_total_bits_meta_ft          <= rx_total_bits_snapshot_tx;
            rx_error_bits_meta_ft          <= rx_error_bits_snapshot_tx;
            rx2_total_bits_meta_ft         <= rx2_total_bits_snapshot_tx;
            rx2_error_bits_meta_ft         <= rx2_error_bits_snapshot_tx;
            rx_locked_meta_ft              <= rx_locked_snapshot_tx;
            rx2_locked_meta_ft             <= rx2_locked_snapshot_tx;
            diversity_mode_meta_ft         <= diversity_mode_snapshot_tx;
            selected_rx2_meta_ft           <= selected_rx2_snapshot_tx;
            tx_enable_meta_ft              <= tx_enable_snapshot_tx;
            rx_supported_meta_ft           <= rx_supported_snapshot_tx;
            blink_sw_meta_ft               <= blink_sw_snapshot_tx;
            payload_rx_supported_meta_ft   <= payload_rx_supported_snapshot_tx;

            payload_tx_bits_sync_ft        <= payload_tx_bits_meta_ft;
            payload_rx_bits_sync_ft        <= payload_rx_bits_meta_ft;
            payload_error_bits_sync_ft     <= payload_error_bits_meta_ft;
            tx_line_bits_sync_ft           <= tx_line_bits_meta_ft;
            tx_frame_bits_sync_ft           <= tx_frame_bits_meta_ft;
            rx_total_bits_sync_ft          <= rx_total_bits_meta_ft;
            rx_error_bits_sync_ft          <= rx_error_bits_meta_ft;
            rx2_total_bits_sync_ft         <= rx2_total_bits_meta_ft;
            rx2_error_bits_sync_ft         <= rx2_error_bits_meta_ft;
            rx_locked_sync_ft              <= rx_locked_meta_ft;
            rx2_locked_sync_ft             <= rx2_locked_meta_ft;
            diversity_mode_sync_ft         <= diversity_mode_meta_ft;
            selected_rx2_sync_ft           <= selected_rx2_meta_ft;
            tx_enable_sync_ft              <= tx_enable_meta_ft;
            rx_supported_sync_ft           <= rx_supported_meta_ft;
            blink_sw_sync_ft               <= blink_sw_meta_ft;
            payload_rx_supported_sync_ft   <= payload_rx_supported_meta_ft;

            status_snapshot_toggle_sync_ft <=
                {status_snapshot_toggle_sync_ft[1:0], status_snapshot_toggle_tx};

            if (status_snapshot_toggle_sync_ft[2] !=
                status_snapshot_toggle_seen_ft) begin
                status_snapshot_toggle_seen_ft <= status_snapshot_toggle_sync_ft[2];
                payload_tx_bits_status_ft      <= payload_tx_bits_sync_ft;
                payload_rx_bits_status_ft      <= payload_rx_bits_sync_ft;
                payload_error_bits_status_ft   <= payload_error_bits_sync_ft;
                tx_line_bits_status_ft         <= tx_line_bits_sync_ft;
                tx_frame_bits_status_ft         <= tx_frame_bits_sync_ft;
                rx_total_bits_status_ft        <= rx_total_bits_sync_ft;
                rx_error_bits_status_ft        <= rx_error_bits_sync_ft;
                rx2_total_bits_status_ft       <= rx2_total_bits_sync_ft;
                rx2_error_bits_status_ft       <= rx2_error_bits_sync_ft;
                rx_locked_status_ft            <= rx_locked_sync_ft;
                rx2_locked_status_ft           <= rx2_locked_sync_ft;
                diversity_mode_status_ft       <= diversity_mode_sync_ft;
                selected_rx2_status_ft         <= selected_rx2_sync_ft;
                tx_enable_status_ft            <= tx_enable_sync_ft;
                rx_supported_status_ft          <= rx_supported_sync_ft;
                blink_sw_status_ft              <= blink_sw_sync_ft;
                payload_rx_supported_status_ft  <= payload_rx_supported_sync_ft;
            end
        end
    end

    // ============================================================
    // SMP extension uses the SAME publication edge/event as the legacy
    // counter bundle. These fields cannot describe another counter interval.
    // The 256-bit RX capture and all metadata settle through two bus stages
    // before the existing three-stage event is accepted.
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            run_mode_snapshot_tx <= 32'd0;
            smp_status_snapshot_tx <= 32'd0;
            smp_token_snapshot_tx <= 32'd0;
            smp_first_snapshot_tx <= 32'd0;
            smp_data_snapshot_tx <= 256'd0;
            smp_diag_snapshot_tx <= 224'd0;
        end else if (tx_restart_pulse_tx || soft_reset_pulse_tx) begin
            run_mode_snapshot_tx <= {run_epoch_tx + 30'd1, mimo_mode_tx};
            smp_status_snapshot_tx <= {27'd0, mimo_mode_tx, 3'd0};
            smp_token_snapshot_tx <= smp_capture_token_tx;
            smp_first_snapshot_tx <= 32'd0;
            smp_data_snapshot_tx <= 256'd0;
            smp_diag_snapshot_tx <= 224'd0;
        end else if (status_snapshot_div == STATUS_SNAPSHOT_MAX) begin
            run_mode_snapshot_tx <= {run_epoch_tx, mimo_mode_tx};
            smp_status_snapshot_tx <= smp_status_tx;
            smp_token_snapshot_tx <= smp_capture_token_tx;
            smp_first_snapshot_tx <= smp_first_pair_id;
            smp_data_snapshot_tx <= smp_capture_data;
            smp_diag_snapshot_tx <= smp_diag_tx;
        end
    end

    always @(posedge ft_clk or negedge reset_n) begin
        if (!reset_n) begin
            run_mode_meta_ft <= 32'd0;
            run_mode_sync_ft <= 32'd0;
            run_mode_status_ft <= 32'd0;
            smp_status_meta_ft <= 32'd0;
            smp_status_sync_ft <= 32'd0;
            smp_status_status_ft <= 32'd0;
            smp_token_meta_ft <= 32'd0;
            smp_token_sync_ft <= 32'd0;
            smp_token_status_ft <= 32'd0;
            smp_first_meta_ft <= 32'd0;
            smp_first_sync_ft <= 32'd0;
            smp_first_status_ft <= 32'd0;
            smp_data_meta_ft <= 256'd0;
            smp_data_sync_ft <= 256'd0;
            smp_data_status_ft <= 256'd0;
            smp_diag_meta_ft <= 224'd0;
            smp_diag_sync_ft <= 224'd0;
            smp_diag_status_ft <= 224'd0;
        end else begin
            run_mode_meta_ft <= run_mode_snapshot_tx;
            run_mode_sync_ft <= run_mode_meta_ft;
            smp_status_meta_ft <= smp_status_snapshot_tx;
            smp_status_sync_ft <= smp_status_meta_ft;
            smp_token_meta_ft <= smp_token_snapshot_tx;
            smp_token_sync_ft <= smp_token_meta_ft;
            smp_first_meta_ft <= smp_first_snapshot_tx;
            smp_first_sync_ft <= smp_first_meta_ft;
            smp_data_meta_ft <= smp_data_snapshot_tx;
            smp_data_sync_ft <= smp_data_meta_ft;
            smp_diag_meta_ft <= smp_diag_snapshot_tx;
            smp_diag_sync_ft <= smp_diag_meta_ft;
            if (status_snapshot_toggle_sync_ft[2] != status_snapshot_toggle_seen_ft) begin
                run_mode_status_ft <= run_mode_sync_ft;
                smp_status_status_ft <= smp_status_sync_ft;
                smp_token_status_ft <= smp_token_sync_ft;
                smp_first_status_ft <= smp_first_sync_ft;
                smp_data_status_ft <= smp_data_sync_ft;
                smp_diag_status_ft <= smp_diag_sync_ft;
            end
        end
    end

    // Status word builder (all multi-bit counters are now in ft_clk)
    // ============================================================
    assign status_flags_ft = {
        selected_rx2_status_ft,
        diversity_mode_status_ft,
        rx2_locked_status_ft,
        payload_rx_supported_status_ft,
        blink_sw_status_ft,
        rx_supported_status_ft,
        rx_locked_status_ft,
        tx_enable_status_ft
    };

    reg [31:0] delivery_request_token_ft, delivery_completed_token_ft;
    reg delivery_request_toggle_ft, delivery_pending_ft;
    reg [639:0] delivery_bank_tx, delivery_bank_ft;
    function [31:0] make_status_word;
        input [7:0] status_id;
        reg [7:0] flags;
        begin
            flags = status_flags_ft;

            case (status_id)
                // Main TX count credits complete encoded frames. RX/error
                // still count individual checked samples after lock.
                8'd1: make_status_word = tx_frame_bits_status_ft;
                8'd2: make_status_word = payload_rx_bits_query_ft;
                8'd3: make_status_word = payload_error_bits_query_ft;
                8'd4: make_status_word =
                    (ber_query_stage_ft == 3'd5) ? status_word_query_ft :
                    {cmd_mod_tx, cmd_speed_tx, flags, 8'h52}; // "R" header
                8'd5: make_status_word = {23'd0, active_bit_ticks};

                // Optional raw line-level debug counters.
                8'd6: make_status_word = tx_line_bits_status_ft;
                8'd35: make_status_word = 32'h5458_4631; // TXF1
                8'd37: make_status_word = 32'h534D_5031; // SMP1
                8'd38: make_status_word = run_mode_query_ft;
                8'd39: make_status_word = smp_request_token_ft + 32'd1;
                8'd40: make_status_word = smp_status_status_ft;
                8'd41: make_status_word = smp_token_query_ft;
                8'd42: make_status_word = smp_data_query_ft[31:0];
                8'd43: make_status_word = smp_data_query_ft[63:32];
                8'd44: make_status_word = smp_data_query_ft[95:64];
                8'd45: make_status_word = smp_data_query_ft[127:96];
                8'd46: make_status_word = smp_data_query_ft[159:128];
                8'd47: make_status_word = smp_data_query_ft[191:160];
                8'd48: make_status_word = smp_data_query_ft[223:192];
                8'd49: make_status_word = smp_data_query_ft[255:224];
                8'd50: make_status_word = smp_first_query_ft;
                8'd51: make_status_word = {2'd0, smp_epoch_query_ft};
                8'd36: make_status_word =
                    (ber_query_stage_ft == 3'd6) ? legacy_tx_bits_query_ft :
                    tx_line_bits_status_ft;
                8'd7: make_status_word = rx_total_bits_status_ft;
                8'd8: make_status_word = line_error_bits_query_ft;

                // Runtime sweep setting: bits 10:9 delay, bits 8:0 phase.
                8'd18: make_status_word =
                    {21'd0, active_nrz_delay, active_nrz_phase};

                // Independent RX2 line BER and OOK-NRZ tune setting.
                8'd28: make_status_word =
                    (ber_query_stage_ft == 3'd3) ? rx2_total_bits_query_ft :
                    rx2_total_bits_status_ft;
                8'd29: make_status_word = rx2_error_bits_query_ft;
                8'd34: make_status_word =
                    {21'd0, active_nrz_delay2, active_nrz_phase2};

                8'd9: make_status_word = {24'd0, user_text_len};

                // Once this reaches 32, rx_text_mem is frozen and therefore
                // safe for the GUI to read across eight sequential queries.
                8'd19: make_status_word = text_ready_ft ? 32'd32 : 32'd0;

                // RX text output, 4 characters per 32-bit word.
                // PC little-endian byte order gives char0, char1, char2, char3.
                8'd10: make_status_word = text_data_ft[31:0];
                8'd11: make_status_word = text_data_ft[63:32];
                8'd12: make_status_word = text_data_ft[95:64];
                8'd13: make_status_word = text_data_ft[127:96];
                8'd14: make_status_word = text_data_ft[159:128];
                8'd15: make_status_word = text_data_ft[191:160];
                8'd16: make_status_word = text_data_ft[223:192];
                8'd17: make_status_word = text_data_ft[255:224];

                // TX text memory debug, 4 characters per 32-bit word.
                // This lets the GUI verify that the typed User Text was loaded.
                8'd20: make_status_word = {user_text_mem[3],  user_text_mem[2],  user_text_mem[1],  user_text_mem[0]};
                8'd21: make_status_word = {user_text_mem[7],  user_text_mem[6],  user_text_mem[5],  user_text_mem[4]};
                8'd22: make_status_word = {user_text_mem[11], user_text_mem[10], user_text_mem[9],  user_text_mem[8]};
                8'd23: make_status_word = {user_text_mem[15], user_text_mem[14], user_text_mem[13], user_text_mem[12]};
                8'd24: make_status_word = {user_text_mem[19], user_text_mem[18], user_text_mem[17], user_text_mem[16]};
                8'd25: make_status_word = {user_text_mem[23], user_text_mem[22], user_text_mem[21], user_text_mem[20]};
                8'd26: make_status_word = {user_text_mem[27], user_text_mem[26], user_text_mem[25], user_text_mem[24]};
                8'd27: make_status_word = {user_text_mem[31], user_text_mem[30], user_text_mem[29], user_text_mem[28]};

                // V2.3 text protocol; legacy IDs and SMP protocol remain intact.
                8'd52: make_status_word = 32'h54323331; // T231: V2.3.1 Text Repair TEST
                8'd53: make_status_word = text_v23_pending_ft ?
                    text_v23_request_token_ft : text_v23_request_token_ft + 32'd1;
                8'd54: make_status_word = text_v23_ready_ft ? text_v23_status_ft : 32'd0;
                8'd55: make_status_word = text_v23_token_ft;
                8'd56: make_status_word = text_v23_data_ft[31:0];
                8'd57: make_status_word = text_v23_data_ft[63:32];
                8'd58: make_status_word = text_v23_data_ft[95:64];
                8'd59: make_status_word = text_v23_data_ft[127:96];
                8'd60: make_status_word = text_v23_data_ft[159:128];
                8'd61: make_status_word = text_v23_data_ft[191:160];
                8'd62: make_status_word = text_v23_data_ft[223:192];
                8'd63: make_status_word = text_v23_data_ft[255:224];
                8'd64: make_status_word = text_v23_epoch_ft;
                8'd65: make_status_word = text_v23_payload_bits_ft;
                8'd66: make_status_word = text_v23_payload_errors_ft;
                8'd67: make_status_word = 32'h54323350; // T23P: pipelined paired text diagnostics
                8'd68: make_status_word = text_diag_bytes_ft;
                8'd69: make_status_word = text_diag_commits_ft;
                8'd70: make_status_word = text_diag_first_ft;
                8'd71: make_status_word = text_diag_flags_ft;
                8'd72: make_status_word = 32'hA5963CC3;
                8'd73: make_status_word = 32'h5A69C33C;
                8'd75: make_status_word = 32'h53333144; // S31D
                8'd76: make_status_word = smp_diag_query_ft[31:0];
                8'd77: make_status_word = smp_diag_query_ft[63:32];
                8'd78: make_status_word = smp_diag_query_ft[95:64];
                8'd79: make_status_word = smp_diag_query_ft[127:96];
                8'd80: make_status_word = smp_diag_query_ft[159:128];
                8'd81: make_status_word = smp_diag_query_ft[191:160];
                8'd82: make_status_word = smp_diag_query_ft[223:192];
                // V3.3.2 passive, coherent delivery telemetry. R91 requests a
                // new bank; all data words remain immutable until its ACK.
                8'd90: make_status_word = 32'h4D333302;
                8'd91: make_status_word = delivery_pending_ft ? delivery_request_token_ft : delivery_request_token_ft + 32'd1;
                8'd92: make_status_word = delivery_completed_token_ft;
                8'd93: make_status_word = delivery_bank_ft[31:0];
                8'd94: make_status_word = delivery_bank_ft[63:32];
                8'd95: make_status_word = delivery_bank_ft[95:64];
                8'd96: make_status_word = delivery_bank_ft[127:96];
                8'd97: make_status_word = delivery_bank_ft[159:128];
                8'd98: make_status_word = delivery_bank_ft[191:160];
                8'd99: make_status_word = delivery_bank_ft[223:192];
                8'd100: make_status_word = delivery_bank_ft[255:224];
                8'd101: make_status_word = delivery_bank_ft[287:256];
                8'd102: make_status_word = delivery_bank_ft[319:288];
                8'd103: make_status_word = delivery_bank_ft[351:320];
                8'd104: make_status_word = delivery_bank_ft[383:352];
                8'd105: make_status_word = delivery_bank_ft[415:384];
                8'd106: make_status_word = delivery_bank_ft[447:416];
                8'd107: make_status_word = delivery_bank_ft[479:448];
                8'd108: make_status_word = delivery_bank_ft[511:480];
                8'd109: make_status_word = delivery_bank_ft[543:512];
                8'd110: make_status_word = delivery_bank_ft[575:544];
                8'd111: make_status_word = 32'd250000000;
                8'd112: make_status_word = 32'd32;
                8'd113: make_status_word = delivery_bank_ft[607:576];
                8'd114: make_status_word = delivery_bank_ft[639:608];

                default: make_status_word = 32'hBAD0_0000 | {24'd0, status_id};
            endcase
        end
    endfunction

    // ============================================================
    // FT601 FSM states
    // ============================================================
    localparam USB_IDLE         = 3'd0;
    localparam USB_OE_LOW       = 3'd1;
    localparam USB_RD_LOW       = 3'd2;
    localparam USB_STATUS_WAIT  = 3'd3;
    localparam USB_STATUS_WRITE = 3'd4;

    reg [2:0] usb_state;

    // ============================================================
    // FT601 receive command
    //
    // Normal controls: no echo.
    // Status command R: return exactly one 32-bit word.
    // ============================================================
    always @(posedge ft_clk or negedge reset_n) begin
        if (!reset_n) begin
            usb_state    <= USB_IDLE;

            ft_oe_n      <= 1'b1;
            ft_rd_n      <= 1'b1;
            ft_wr_n      <= 1'b1;

            usb_tx_word  <= 32'h0000_0000;
            usb_tx_drive <= 1'b0;

            cmd_data_ft  <= 8'h00;
            cmd_code_ft  <= 8'h00;
            cmd_speed_ft <= 8'h00;
            cmd_mod_ft   <= 8'h00;

            text_index_ft <= 6'd0;
            text_char_ft  <= 8'h20;
            text_len_ft   <= 6'd1;
            text_capture_reset_toggle_ft <= 1'b0;
            text_v23_request_toggle_ft <= 0;
            text_v23_request_token_ft <= 0;
            smp_request_token_ft <= 32'd0;
            smp_request_toggle_ft <= 1'b0;
            run_mode_query_ft <= 32'd0;
            smp_status_query_ft <= 32'd0;
            smp_token_query_ft <= 32'd0;
            smp_first_query_ft <= 32'd0;
            smp_epoch_query_ft <= 30'd0;
            smp_data_query_ft <= 256'd0;
            smp_diag_query_ft <= 224'd0;

            nrz_tune_phase_ft <= 9'd0;
            nrz_tune_delay_ft <= 2'd0;
            nrz_tune_link_ft  <= 1'b0;
            mimo_mode_ft      <= MIMO_SISO;

            payload_rx_bits_query_ft    <= 32'd0;
            payload_error_bits_query_ft <= 32'd0;
            line_error_bits_query_ft    <= 32'd0;
            rx2_total_bits_query_ft     <= 32'd0;
            rx2_error_bits_query_ft     <= 32'd0;
            status_word_query_ft        <= 32'd0;
            legacy_tx_bits_query_ft <= 32'd0;
            ber_query_stage_ft          <= 3'd0;

            tx_enable_ft   <= 1'b0;
            got_command_ft <= 1'b0;

            cmd_toggle_ft <= 1'b0;
            cmd_action_ft <= CMD_ACTION_NOP;

        end else begin

            case (usb_state)

                USB_IDLE: begin
                    ft_oe_n      <= 1'b1;
                    ft_rd_n      <= 1'b1;
                    ft_wr_n      <= 1'b1;
                    usb_tx_drive <= 1'b0;

                    if (!ft_rxf_n) begin
                        ft_oe_n   <= 1'b0;
                        usb_state <= USB_OE_LOW;
                    end
                end

                USB_OE_LOW: begin
                    ft_wr_n      <= 1'b1;
                    usb_tx_drive <= 1'b0;

                    if (!ft_rxf_n) begin
                        ft_rd_n   <= 1'b0;
                        usb_state <= USB_RD_LOW;
                    end else begin
                        ft_oe_n   <= 1'b1;
                        ft_rd_n   <= 1'b1;
                        usb_state <= USB_IDLE;
                    end
                end

                USB_RD_LOW: begin
                    if (!ft_rxf_n) begin

                        // Any non-status command aborts a partially completed
                        // periodic BER query group before changing FPGA state.
                        if (ft_data[7:0] != "R")
                            ber_query_stage_ft <= 3'd0;

                        // ------------------------------------------------
                        // R 00 00 ID = status query
                        // Return one 32-bit status word to PIPE_IN.
                        // ID is byte 3, ft_data[31:24].
                        // ------------------------------------------------
                        if (ft_data[7:0] == "R") begin
                            usb_tx_word <= make_status_word(ft_data[31:24]);
                            if (ft_data[31:24] == 8'd53 && !text_v23_pending_ft) begin
                                text_v23_request_token_ft <= text_v23_request_token_ft + 32'd1;
                                text_v23_request_toggle_ft <= ~text_v23_request_toggle_ft;
                            end

                            // ID 1 freezes the entire periodic DIV query group.
                            // The exact GUI order 1,2,3,28,29,4 therefore sees
                            // one accepted clk_250 snapshot even when a new
                            // 1-ms CDC snapshot arrives between USB reads.
                            if (ft_data[31:24] == 8'd1) begin
                                run_mode_query_ft <= run_mode_status_ft;
                                legacy_tx_bits_query_ft <= tx_line_bits_status_ft;
                                payload_rx_bits_query_ft <=
                                    rx_total_bits_status_ft;
                                payload_error_bits_query_ft <=
                                    rx_error_bits_status_ft;
                                rx2_total_bits_query_ft <=
                                    rx2_total_bits_status_ft;
                                rx2_error_bits_query_ft <=
                                    rx2_error_bits_status_ft;
                                status_word_query_ft <= {
                                    cmd_mod_tx,
                                    cmd_speed_tx,
                                    status_flags_ft,
                                    8'h52
                                };
                                ber_query_stage_ft <= 3'd1;
                            end else begin
                                // Enforce the expected sequence so an aborted
                                // group cannot make a later standalone query
                                // return stale frozen data.
                                case (ber_query_stage_ft)
                                    3'd1: ber_query_stage_ft <=
                                        (ft_data[31:24] == 8'd2) ? 3'd2 : 3'd0;
                                    3'd2: ber_query_stage_ft <=
                                        (ft_data[31:24] == 8'd3) ? 3'd3 : 3'd0;
                                    3'd3: ber_query_stage_ft <=
                                        (ft_data[31:24] == 8'd28) ? 3'd4 : 3'd0;
                                    3'd4: ber_query_stage_ft <=
                                        (ft_data[31:24] == 8'd29) ? 3'd5 : 3'd0;
                                    3'd5: ber_query_stage_ft <=
                                        (ft_data[31:24] == 8'd4) ? 3'd6 : 3'd0;
                                    3'd6: ber_query_stage_ft <= 3'd0;
                                    default: ber_query_stage_ft <= 3'd0;
                                endcase
                            end

                            // Sweep code reads ID 7 followed by ID 8. Latch
                            // its matching error count when ID 7 is requested.
                            if (ft_data[31:24] == 8'd7)
                                line_error_bits_query_ft <=
                                    rx_error_bits_status_ft;

                            // RX2 checked-bit query opens its coherent pair;
                            // the following ID 29 returns the same snapshot.
                            if ((ft_data[31:24] == 8'd28) &&
                                (ber_query_stage_ft != 3'd3)) begin
                                rx2_total_bits_query_ft <=
                                    rx2_total_bits_status_ft;
                                rx2_error_bits_query_ft <=
                                    rx2_error_bits_status_ft;
                            end

                            // ID 17 is the last word of the frozen 32-byte RX
                            // text block. Reset the capture only after this word
                            // has already been copied into usb_tx_word.
                            if (ft_data[31:24] == 8'd17)
                                text_capture_reset_toggle_ft <=
                                    ~text_capture_reset_toggle_ft;

                            if (ft_data[31:24] == 8'd39) begin
                                smp_request_token_ft <= smp_request_token_ft + 32'd1;
                                smp_request_toggle_ft <= ~smp_request_toggle_ft;
                            end

                            // R40 returns and freezes ONE accepted source
                            // snapshot. All following fields remain unchanged
                            // even if locks/dropouts/rearm occur during USB reads.
                            if (ft_data[31:24] == 8'd40) begin
                                smp_status_query_ft <= smp_status_status_ft;
                                smp_token_query_ft <= smp_token_status_ft;
                                smp_first_query_ft <= smp_first_status_ft;
                                smp_epoch_query_ft <= run_mode_status_ft[31:2];
                                smp_data_query_ft <= smp_data_status_ft;
                                smp_diag_query_ft <= smp_diag_status_ft;
                            end

                            cmd_action_ft <= CMD_ACTION_NOP;

                            ft_rd_n   <= 1'b1;
                            ft_oe_n   <= 1'b1;
                            usb_state <= USB_STATUS_WAIT;
                        end

                        // ------------------------------------------------
                        // W INDEX CHAR 00 = write one User Text character.
                        // ------------------------------------------------
                        else if (ft_data[7:0] == "W") begin
                            text_index_ft <= ft_data[13:8];
                            text_char_ft  <= ft_data[23:16];

                            cmd_action_ft <= CMD_ACTION_TEXTWRITE;
                            cmd_toggle_ft <= ~cmd_toggle_ft;

                            ft_rd_n      <= 1'b1;
                            ft_oe_n      <= 1'b1;
                            ft_wr_n      <= 1'b1;
                            usb_tx_drive <= 1'b0;
                            usb_state    <= USB_IDLE;
                        end

                        // ------------------------------------------------
                        // L LEN 00 00 = set User Text length.
                        // ------------------------------------------------
                        else if (ft_data[7:0] == "L") begin
                            if (ft_data[13:8] == 6'd0)
                                text_len_ft <= 6'd1;
                            else if (ft_data[13:8] > 6'd32)
                                text_len_ft <= 6'd32;
                            else
                                text_len_ft <= ft_data[13:8];

                            cmd_action_ft <= CMD_ACTION_TEXTLEN;
                            cmd_toggle_ft <= ~cmd_toggle_ft;

                            ft_rd_n      <= 1'b1;
                            ft_oe_n      <= 1'b1;
                            ft_wr_n      <= 1'b1;
                            usb_tx_drive <= 1'b0;
                            usb_state    <= USB_IDLE;
                        end

                        // ------------------------------------------------
                        // I MODE 00 00 = select SISO/diversity/SMP.
                        // MODE 0:SISO, 1:DIV, 2:SMP (independent OOK-NRZ).
                        // ------------------------------------------------
                        else if (ft_data[7:0] == "I") begin
                            if (ft_data[15:8] <= 8'd2)
                                mimo_mode_ft <= ft_data[9:8];
                            else
                                mimo_mode_ft <= MIMO_SISO;

                            cmd_action_ft <= CMD_ACTION_MIMO_MODE;
                            cmd_toggle_ft <= ~cmd_toggle_ft;

                            ft_rd_n      <= 1'b1;
                            ft_oe_n      <= 1'b1;
                            ft_wr_n      <= 1'b1;
                            usb_tx_drive <= 1'b0;
                            usb_state    <= USB_IDLE;
                        end

                        // ------------------------------------------------
                        // V PH DL LINK = tune one OOK-NRZ receiver.
                        // PH is carried as an 8-bit command value and clamped
                        // to the active bit period in the data-plane domain.
                        // DL is clamped to 0..3 whole bits.
                        // LINK 0 selects RX1; LINK 1 selects RX2.
                        // The data-plane restart clears all BER counters.
                        // ------------------------------------------------
                        else if (ft_data[7:0] == "V") begin
                            nrz_tune_phase_ft <= {1'b0, ft_data[15:8]};

                            if (ft_data[23:16] > 8'd3)
                                nrz_tune_delay_ft <= 2'd3;
                            else
                                nrz_tune_delay_ft <= ft_data[17:16];

                            nrz_tune_link_ft <= (ft_data[31:24] == 8'd1);

                            cmd_action_ft <= CMD_ACTION_RX_TUNE;
                            cmd_toggle_ft <= ~cmd_toggle_ft;

                            ft_rd_n      <= 1'b1;
                            ft_oe_n      <= 1'b1;
                            ft_wr_n      <= 1'b1;
                            usb_tx_drive <= 1'b0;
                            usb_state    <= USB_IDLE;
                        end

                        // ------------------------------------------------
                        // Z = FPGA soft reset
                        // Clear command/display state and reset TX/RX plane.
                        // ------------------------------------------------
                        else if (ft_data[7:0] == "Z") begin
                            cmd_data_ft  <= 8'h00;
                            cmd_code_ft  <= 8'h00;
                            cmd_speed_ft <= 8'h00;
                            cmd_mod_ft   <= 8'h00;

                            tx_enable_ft   <= 1'b0;
                            got_command_ft <= 1'b0;

                            nrz_tune_phase_ft <= 9'd0;
                            nrz_tune_delay_ft <= 2'd0;
                            nrz_tune_link_ft  <= 1'b0;
                            mimo_mode_ft      <= MIMO_SISO;

                            cmd_action_ft <= CMD_ACTION_SOFTRESET;
                            cmd_toggle_ft <= ~cmd_toggle_ft;

                            ft_rd_n      <= 1'b1;
                            ft_oe_n      <= 1'b1;
                            ft_wr_n      <= 1'b1;
                            usb_tx_drive <= 1'b0;
                            usb_state    <= USB_IDLE;
                        end

                        // ------------------------------------------------
                        // X or S = stop
                        // ------------------------------------------------
                        else if ((ft_data[7:0] == "X") || (ft_data[7:0] == "S")) begin
                            cmd_data_ft  <= 8'h00;
                            cmd_code_ft  <= 8'h00;
                            cmd_speed_ft <= 8'h00;
                            cmd_mod_ft   <= 8'h00;

                            tx_enable_ft   <= 1'b0;
                            got_command_ft <= 1'b0;

                            cmd_action_ft <= CMD_ACTION_STOP;
                            cmd_toggle_ft <= ~cmd_toggle_ft;

                            ft_rd_n      <= 1'b1;
                            ft_oe_n      <= 1'b1;
                            ft_wr_n      <= 1'b1;
                            usb_tx_drive <= 1'b0;
                            usb_state    <= USB_IDLE;
                        end

                        // ------------------------------------------------
                        // Y = NOP / keep-alive only
                        // ------------------------------------------------
                        else if (ft_data[7:0] == "Y") begin
                            cmd_action_ft <= CMD_ACTION_NOP;

                            ft_rd_n      <= 1'b1;
                            ft_oe_n      <= 1'b1;
                            ft_wr_n      <= 1'b1;
                            usb_tx_drive <= 1'b0;
                            usb_state    <= USB_IDLE;
                        end

                        // ------------------------------------------------
                        // Normal 4-byte start command
                        // ------------------------------------------------
                        else begin
                            cmd_data_ft  <= ft_data[7:0];
                            cmd_code_ft  <= ft_data[15:8];
                            cmd_speed_ft <= ft_data[23:16];
                            cmd_mod_ft   <= ft_data[31:24];

                            tx_enable_ft   <= 1'b1;
                            got_command_ft <= 1'b1;

                            cmd_action_ft <= CMD_ACTION_START;
                            cmd_toggle_ft <= ~cmd_toggle_ft;

                            ft_rd_n      <= 1'b1;
                            ft_oe_n      <= 1'b1;
                            ft_wr_n      <= 1'b1;
                            usb_tx_drive <= 1'b0;
                            usb_state    <= USB_IDLE;
                        end

                    end else begin
                        ft_rd_n      <= 1'b1;
                        ft_oe_n      <= 1'b1;
                        ft_wr_n      <= 1'b1;
                        usb_tx_drive <= 1'b0;
                        usb_state    <= USB_IDLE;
                    end
                end

                USB_STATUS_WAIT: begin
                    ft_oe_n <= 1'b1;
                    ft_rd_n <= 1'b1;
                    ft_wr_n <= 1'b1;

                    if (!ft_txe_n) begin
                        usb_tx_drive <= 1'b1;
                        ft_wr_n      <= 1'b0;
                        usb_state    <= USB_STATUS_WRITE;
                    end
                end

                USB_STATUS_WRITE: begin
                    ft_wr_n      <= 1'b1;
                    usb_tx_drive <= 1'b0;
                    usb_state    <= USB_IDLE;
                end

                default: begin
                    usb_state    <= USB_IDLE;
                    ft_oe_n      <= 1'b1;
                    ft_rd_n      <= 1'b1;
                    ft_wr_n      <= 1'b1;
                    usb_tx_drive <= 1'b0;
                end

            endcase
        end
    end

    // ============================================================
    // Command transfer from ft_clk domain to clk_250 domain
    // ============================================================
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            cmd_toggle_sync_tx <= 3'b000;
            cmd_toggle_seen_tx <= 1'b0;

            cmd_data_tx  <= 8'h00;
            cmd_code_tx  <= 8'h00;
            cmd_speed_tx <= 8'h00;
            cmd_mod_tx   <= 8'h00;
            active_mode <= MODE_ASCII_S;
            active_code <= CODE_NONE;
            active_bit_ticks <= TICKS_1M;
            active_last_phase <= 9'd249; active_penultimate_phase <= 9'd248;
            active_mod <= MOD_OOK_NRZ;

            tx_enable_tx        <= 1'b0;
            tx_restart_pulse_tx <= 1'b0;
            soft_reset_pulse_tx <= 1'b0;

            // Power-on/default command decoding selects 1 Mbps.
            nrz_phase_tx <= 9'd127;
            nrz_delay_tx <= 2'd0;
            nrz_phase2_tx <= 9'd127;
            nrz_delay2_tx <= 2'd0;
            mimo_mode_tx  <= MIMO_SISO;

            user_text_len <= 6'd1;
            for (user_mem_i = 0; user_mem_i < USER_TEXT_MAX; user_mem_i = user_mem_i + 1) begin
                user_text_mem[user_mem_i] <= 8'h20;
            end
            user_text_mem[0] <= 8'h53; // default User Text = "S"

        end else begin
            tx_restart_pulse_tx <= 1'b0;
            soft_reset_pulse_tx <= 1'b0;

            // Synchronise command toggle into clk_250 domain
            cmd_toggle_sync_tx <= {cmd_toggle_sync_tx[1:0], cmd_toggle_ft};

            if (cmd_toggle_sync_tx[2] != cmd_toggle_seen_tx) begin
                cmd_toggle_seen_tx <= cmd_toggle_sync_tx[2];

                if (cmd_action_ft == CMD_ACTION_TEXTWRITE) begin
                    if (text_index_ft < USER_TEXT_MAX)
                        user_text_mem[text_index_ft] <= text_char_ft;
                end

                else if (cmd_action_ft == CMD_ACTION_TEXTLEN) begin
                    user_text_len <= text_len_ft;
                end

                else if (cmd_action_ft == CMD_ACTION_RX_TUNE) begin
                    if (nrz_tune_link_ft) begin
                        if (nrz_tune_phase_ft >= active_bit_ticks)
                            nrz_phase2_tx <= active_last_phase;
                        else
                            nrz_phase2_tx <= nrz_tune_phase_ft;

                        nrz_delay2_tx <= nrz_tune_delay_ft;
                    end else begin
                        if (nrz_tune_phase_ft >= active_bit_ticks)
                            nrz_phase_tx <= active_last_phase;
                        else
                            nrz_phase_tx <= nrz_tune_phase_ft;

                        nrz_delay_tx <= nrz_tune_delay_ft;
                    end

                    // Restart the stream and clear TX/RX/payload counters so
                    // every sweep point is an independent measurement.
                    tx_restart_pulse_tx <= 1'b1;
                end

                else if (cmd_action_ft == CMD_ACTION_MIMO_MODE) begin
                    mimo_mode_tx <= mimo_mode_ft;

                    // Changing mode starts a clean quality/BER interval. The
                    // next normal START command may restart once more; that is
                    // intentional and keeps live mode changes deterministic.
                    tx_restart_pulse_tx <= 1'b1;
                end

                else if (cmd_action_ft == CMD_ACTION_SOFTRESET) begin
                    cmd_data_tx  <= 8'h00;
                    cmd_code_tx  <= 8'h00;
                    cmd_speed_tx <= 8'h00;
                    cmd_mod_tx   <= 8'h00;
                    active_mode <= MODE_ASCII_S;
                    active_code <= CODE_NONE;
                    active_bit_ticks <= TICKS_1M;
                    active_last_phase <= 9'd249; active_penultimate_phase <= 9'd248;
                    active_mod <= MOD_OOK_NRZ;

                    tx_enable_tx        <= 1'b0;
                    tx_restart_pulse_tx <= 1'b1;
                    soft_reset_pulse_tx <= 1'b1;

                    nrz_phase_tx <= 9'd127;
                    nrz_delay_tx <= 2'd0;
                    nrz_phase2_tx <= 9'd127;
                    nrz_delay2_tx <= 2'd0;
                    mimo_mode_tx  <= MIMO_SISO;

                    user_text_len <= 6'd1;
                    for (user_mem_i = 0; user_mem_i < USER_TEXT_MAX; user_mem_i = user_mem_i + 1) begin
                        user_text_mem[user_mem_i] <= 8'h20;
                    end
                    user_text_mem[0] <= 8'h53;
                end

                else if (cmd_action_ft == CMD_ACTION_STOP) begin
                    cmd_data_tx  <= 8'h00;
                    cmd_code_tx  <= 8'h00;
                    cmd_speed_tx <= 8'h00;
                    cmd_mod_tx   <= 8'h00;
                    active_mode <= MODE_ASCII_S;
                    active_code <= CODE_NONE;
                    active_bit_ticks <= TICKS_1M;
                    active_last_phase <= 9'd249; active_penultimate_phase <= 9'd248;
                    active_mod <= MOD_OOK_NRZ;

                    tx_enable_tx        <= 1'b0;
                    tx_restart_pulse_tx <= 1'b1;
                end

                else if (cmd_action_ft == CMD_ACTION_RESTART) begin
                    tx_restart_pulse_tx <= 1'b1;
                end

                else if (cmd_action_ft == CMD_ACTION_START) begin
                    cmd_data_tx  <= cmd_data_ft;
                    cmd_code_tx  <= cmd_code_ft;
                    cmd_speed_tx <= cmd_speed_ft;
                    cmd_mod_tx   <= cmd_mod_ft;
                    active_mode <= decode_command_mode(cmd_data_ft);
                    active_code <= decode_command_code(cmd_code_ft);
                    active_mod <= decode_command_mod(cmd_mod_ft);

                    tx_enable_tx        <= 1'b1;
                    tx_restart_pulse_tx <= 1'b1;

                    // Load the measured default for the selected OOK-NRZ rate.
                    // The GUI immediately performs the requested local sweep.
                    case (cmd_speed_ft)
                        "K": begin
                            active_bit_ticks <= 9'd250; active_last_phase <= 9'd249; active_penultimate_phase <= 9'd248;
                            nrz_phase_tx <= 9'd127; nrz_delay_tx <= 2'd0;
                            nrz_phase2_tx <= 9'd127; nrz_delay2_tx <= 2'd0;
                        end
                        "L": begin
                            active_bit_ticks <= 9'd125; active_last_phase <= 9'd124; active_penultimate_phase <= 9'd123;
                            nrz_phase_tx <= 9'd64; nrz_delay_tx <= 2'd0;
                            nrz_phase2_tx <= 9'd64; nrz_delay2_tx <= 2'd0;
                        end
                        "M": begin
                            active_bit_ticks <= 9'd50; active_last_phase <= 9'd49; active_penultimate_phase <= 9'd48;
                            nrz_phase_tx <= 9'd28; nrz_delay_tx <= 2'd0;
                            nrz_phase2_tx <= 9'd28; nrz_delay2_tx <= 2'd0;
                        end
                        "N": begin
                            active_bit_ticks <= 9'd25; active_last_phase <= 9'd24; active_penultimate_phase <= 9'd23;
                            nrz_phase_tx <= 9'd18; nrz_delay_tx <= 2'd0;
                            nrz_phase2_tx <= 9'd18; nrz_delay2_tx <= 2'd0;
                        end
                        "O": begin
                            active_bit_ticks <= 9'd10; active_last_phase <= 9'd9; active_penultimate_phase <= 9'd8;
                            nrz_phase_tx <= 9'd8; nrz_delay_tx <= 2'd1;
                            nrz_phase2_tx <= 9'd8; nrz_delay2_tx <= 2'd1;
                        end
                        "P": begin
                            active_bit_ticks <= 9'd5; active_last_phase <= 9'd4; active_penultimate_phase <= 9'd3;
                            nrz_phase_tx <= 9'd2; nrz_delay_tx <= 2'd3;
                            nrz_phase2_tx <= 9'd2; nrz_delay2_tx <= 2'd3;
                        end
                        default: begin
                            active_bit_ticks <= TICKS_1M; active_last_phase <= 9'd249; active_penultimate_phase <= 9'd248;
                            nrz_phase_tx <= 9'd127; nrz_delay_tx <= 2'd0;
                            nrz_phase2_tx <= 9'd127; nrz_delay2_tx <= 2'd0;
                        end
                    endcase
                end

                else begin
                    // NOP
                end
            end
        end
    end

    // ============================================================
    // Text-capture reset event: ft_clk -> clk_250
    // This resets only the 32-byte display capture. It does not restart TX,
    // disturb receiver lock, or clear any BER/line counters.
    // ============================================================
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            text_capture_reset_sync_tx  <= 3'b000;
            text_capture_reset_seen_tx  <= 1'b0;
            text_capture_reset_pulse_tx <= 1'b0;
        end else begin
            text_capture_reset_pulse_tx <= 1'b0;
            text_capture_reset_sync_tx <=
                {text_capture_reset_sync_tx[1:0],
                 text_capture_reset_toggle_ft};

            if (text_capture_reset_sync_tx[2] !=
                text_capture_reset_seen_tx) begin
                text_capture_reset_seen_tx  <= text_capture_reset_sync_tx[2];
                text_capture_reset_pulse_tx <= 1'b1;
            end
        end
    end

    // ============================================================
    // Three-line-bit alignment pipeline for the OOK-NRZ local sweeps.
    // Capture at phase 0 before the TX nonblocking assignments install the
    // next line bit. The delayed values are therefore valid at phases 1..9.
    // ============================================================
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            data_bit_previous                 <= 1'b0;
            data_bit_previous2                <= 1'b0;
            data_bit_previous3                <= 1'b0;
            frame_start_bit_previous          <= 1'b0;
            frame_start_bit_previous2         <= 1'b0;
            frame_start_bit_previous3         <= 1'b0;
            frame_len_latched_previous        <= 5'd8;
            frame_len_latched_previous2       <= 5'd8;
            frame_len_latched_previous3       <= 5'd8;
            frame_code_latched_previous       <= CODE_NONE;
            frame_code_latched_previous2      <= CODE_NONE;
            frame_code_latched_previous3      <= CODE_NONE;
            frame_text_index_latched_previous <= 6'd0;
            frame_text_index_latched_previous2 <= 6'd0;
            frame_text_index_latched_previous3 <= 6'd0;
        end else if (tx_restart_pulse_tx || soft_reset_pulse_tx ||
                     !tx_enable_tx) begin
            data_bit_previous                 <= 1'b0;
            data_bit_previous2                <= 1'b0;
            data_bit_previous3                <= 1'b0;
            frame_start_bit_previous          <= 1'b0;
            frame_start_bit_previous2         <= 1'b0;
            frame_start_bit_previous3         <= 1'b0;
            frame_len_latched_previous        <= 5'd8;
            frame_len_latched_previous2       <= 5'd8;
            frame_len_latched_previous3       <= 5'd8;
            frame_code_latched_previous       <= CODE_NONE;
            frame_code_latched_previous2      <= CODE_NONE;
            frame_code_latched_previous3      <= CODE_NONE;
            frame_text_index_latched_previous <= 6'd0;
            frame_text_index_latched_previous2 <= 6'd0;
            frame_text_index_latched_previous3 <= 6'd0;
        end else if (bit_start_tick) begin
            data_bit_previous3                <= data_bit_previous2;
            data_bit_previous2                <= data_bit_previous;
            data_bit_previous                 <= data_bit;

            frame_start_bit_previous3         <= frame_start_bit_previous2;
            frame_start_bit_previous2         <= frame_start_bit_previous;
            frame_start_bit_previous          <= frame_start_bit;

            frame_len_latched_previous3       <= frame_len_latched_previous2;
            frame_len_latched_previous2       <= frame_len_latched_previous;
            frame_len_latched_previous        <= frame_len_latched;

            frame_code_latched_previous3      <= frame_code_latched_previous2;
            frame_code_latched_previous2      <= frame_code_latched_previous;
            frame_code_latched_previous       <= frame_code_latched;

            frame_text_index_latched_previous3 <= frame_text_index_latched_previous2;
            frame_text_index_latched_previous2 <= frame_text_index_latched_previous;
            frame_text_index_latched_previous <= frame_text_index_latched;
        end
    end

    // ============================================================
    // PRBS / coding functions
    // ============================================================

    function [7:0] prbs7_next_byte;
        input [6:0] state_in;
        reg [6:0] s;
        integer i;
        begin
            s = state_in;
            prbs7_next_byte = 8'd0;

            for (i = 0; i < 8; i = i + 1) begin
                prbs7_next_byte[7 - i] = s[6];
                s = {s[5:0], s[6] ^ s[5]};
            end
        end
    endfunction

    function [6:0] prbs7_advance8;
        input [6:0] state_in;
        reg [6:0] s;
        integer i;
        begin
            s = state_in;

            for (i = 0; i < 8; i = i + 1) begin
                s = {s[5:0], s[6] ^ s[5]};
            end

            prbs7_advance8 = s;
        end
    endfunction

    function [7:0] prbs15_next_byte;
        input [14:0] state_in;
        reg [14:0] s;
        integer i;
        begin
            s = state_in;
            prbs15_next_byte = 8'd0;

            for (i = 0; i < 8; i = i + 1) begin
                prbs15_next_byte[7 - i] = s[14];
                s = {s[13:0], s[14] ^ s[13]};
            end
        end
    endfunction

    function [14:0] prbs15_advance8;
        input [14:0] state_in;
        reg [14:0] s;
        integer i;
        begin
            s = state_in;

            for (i = 0; i < 8; i = i + 1) begin
                s = {s[13:0], s[14] ^ s[13]};
            end

            prbs15_advance8 = s;
        end
    endfunction

    function [7:0] crc8_calc;
        input [7:0] din;
        reg [7:0] crc;
        reg feedback;
        integer i;
        begin
            crc = 8'h00;

            for (i = 0; i < 8; i = i + 1) begin
                feedback = crc[7] ^ din[7 - i];
                crc = {crc[6:0], 1'b0};

                if (feedback)
                    crc = crc ^ 8'h07;
            end

            crc8_calc = crc;
        end
    endfunction

    function [23:0] repeat3_encode;
        input [7:0] din;
        integer i;
        begin
            repeat3_encode = 24'd0;

            for (i = 0; i < 8; i = i + 1) begin
                repeat3_encode[23 - (i*3)] = din[7 - i];
                repeat3_encode[22 - (i*3)] = din[7 - i];
                repeat3_encode[21 - (i*3)] = din[7 - i];
            end
        end
    endfunction

    function [6:0] hamming74_encode;
        input [3:0] din;
        reg p1;
        reg p2;
        reg p4;
        begin
            p1 = din[3] ^ din[2] ^ din[0];
            p2 = din[3] ^ din[1] ^ din[0];
            p4 = din[2] ^ din[1] ^ din[0];

            hamming74_encode = {p1, p2, din[3], p4, din[2], din[1], din[0]};
        end
    endfunction


    // Hamming(7,4) single-error correction for payload text decoding.
    function [6:0] hamming74_correct;
        input [6:0] code_in;
        reg [6:0] c;
        reg s1;
        reg s2;
        reg s4;
        reg [2:0] syndrome;
        begin
            c = code_in;
            s1 = c[6] ^ c[4] ^ c[2] ^ c[0];
            s2 = c[5] ^ c[4] ^ c[1] ^ c[0];
            s4 = c[3] ^ c[2] ^ c[1] ^ c[0];
            syndrome = {s4, s2, s1};

            case (syndrome)
                3'd1: c[6] = ~c[6];
                3'd2: c[5] = ~c[5];
                3'd3: c[4] = ~c[4];
                3'd4: c[3] = ~c[3];
                3'd5: c[2] = ~c[2];
                3'd6: c[1] = ~c[1];
                3'd7: c[0] = ~c[0];
                default: c = c;
            endcase

            hamming74_correct = c;
        end
    endfunction

    function [3:0] hamming74_decode_data;
        input [6:0] code_in;
        reg [6:0] corrected;
        begin
            corrected = hamming74_correct(code_in);
            hamming74_decode_data = {corrected[4], corrected[2], corrected[1], corrected[0]};
        end
    endfunction

    function [3:0] count_diff8;
        input [7:0] a;
        input [7:0] b;
        reg [7:0] diff;
        begin
            diff = a ^ b;
            count_diff8 =
                diff[0] + diff[1] + diff[2] + diff[3] +
                diff[4] + diff[5] + diff[6] + diff[7];
        end
    endfunction

    function [7:0] decode_frame_byte;
        input [1:0]  code_sel;
        input [23:0] frame_bits;
        reg [7:0] b;
        begin
            // The RX collector shifts recovered bits into the lower side of
            // frame_bits. Therefore the received encoded frame is RIGHT aligned:
            //   None      : [7:0]
            //   CRC-8     : [15:8] payload, [7:0] CRC
            //   Repeat-3  : [23:0]
            //   Hamming   : [13:7] upper codeword, [6:0] lower codeword
            case (code_sel)

                CODE_NONE: begin
                    decode_frame_byte = frame_bits[7:0];
                end

                CODE_CRC8: begin
                    decode_frame_byte = frame_bits[15:8];
                end

                CODE_REPEAT3: begin
                    b[7] = (frame_bits[23] & frame_bits[22]) | (frame_bits[23] & frame_bits[21]) | (frame_bits[22] & frame_bits[21]);
                    b[6] = (frame_bits[20] & frame_bits[19]) | (frame_bits[20] & frame_bits[18]) | (frame_bits[19] & frame_bits[18]);
                    b[5] = (frame_bits[17] & frame_bits[16]) | (frame_bits[17] & frame_bits[15]) | (frame_bits[16] & frame_bits[15]);
                    b[4] = (frame_bits[14] & frame_bits[13]) | (frame_bits[14] & frame_bits[12]) | (frame_bits[13] & frame_bits[12]);
                    b[3] = (frame_bits[11] & frame_bits[10]) | (frame_bits[11] & frame_bits[9])  | (frame_bits[10] & frame_bits[9]);
                    b[2] = (frame_bits[8]  & frame_bits[7])  | (frame_bits[8]  & frame_bits[6])  | (frame_bits[7]  & frame_bits[6]);
                    b[1] = (frame_bits[5]  & frame_bits[4])  | (frame_bits[5]  & frame_bits[3])  | (frame_bits[4]  & frame_bits[3]);
                    b[0] = (frame_bits[2]  & frame_bits[1])  | (frame_bits[2]  & frame_bits[0])  | (frame_bits[1]  & frame_bits[0]);
                    decode_frame_byte = b;
                end

                CODE_HAMMING: begin
                    decode_frame_byte = {
                        hamming74_decode_data(frame_bits[13:7]),
                        hamming74_decode_data(frame_bits[6:0])
                    };
                end

                default: begin
                    decode_frame_byte = frame_bits[7:0];
                end
            endcase
        end
    endfunction

    // ============================================================
    // Raw byte source
    // SMP draws adjacent bytes from this ONE global stream. In particular,
    // odd text lengths wrap continuously rather than repeating two substrings.
    // ============================================================
    reg [6:0]  prbs7;
    reg [14:0] prbs15;
    reg [7:0]  count_byte;

    wire [7:0] raw_byte;
    wire [5:0] text_index_next =
        (user_text_len <= 6'd1 || user_text_tx_index >= user_text_len - 6'd1)
        ? 6'd0 : user_text_tx_index + 6'd1;
    wire [5:0] text_index_after_pair =
        (user_text_len <= 6'd1 || text_index_next >= user_text_len - 6'd1)
        ? 6'd0 : text_index_next + 6'd1;
    wire [7:0] raw_byte2 =
        (active_mode == MODE_PRBS7) ? prbs7_next_byte(prbs7_advance8(prbs7)) :
        (active_mode == MODE_PRBS15) ? prbs15_next_byte(prbs15_advance8(prbs15)) :
        (active_mode == MODE_ASCII_S) ? 8'h53 :
        (active_mode == MODE_COUNTER) ? count_byte + 8'd1 :
        (active_mode == MODE_USER_TEXT) ? user_text_mem[text_index_next] : 8'd0;

    assign raw_byte =
        (active_mode == MODE_PRBS7)     ? prbs7_next_byte(prbs7) :
        (active_mode == MODE_PRBS15)    ? prbs15_next_byte(prbs15) :
        (active_mode == MODE_ASCII_S)   ? 8'h53 :
        (active_mode == MODE_COUNTER)   ? count_byte :
        (active_mode == MODE_USER_TEXT) ? user_text_mem[user_text_tx_index] :
                                          8'h00;

    wire [7:0] crc_byte;
    assign crc_byte = crc8_calc(raw_byte);

    // ============================================================
    // Encoded frame
    // First transmitted bit is encoded_frame[23].
    // ============================================================
    wire [23:0] encoded_frame;
    wire [23:0] encoded_frame2 =
        (active_code == CODE_NONE) ? {raw_byte2, 16'd0} :
        (active_code == CODE_CRC8) ? {raw_byte2, crc8_calc(raw_byte2), 8'd0} :
        (active_code == CODE_REPEAT3) ? repeat3_encode(raw_byte2) :
        {hamming74_encode(raw_byte2[7:4]), hamming74_encode(raw_byte2[3:0]), 10'd0};
    wire [4:0]  encoded_len;

    assign encoded_frame =
        (active_code == CODE_NONE)    ? {raw_byte, 16'd0} :
        (active_code == CODE_CRC8)    ? {raw_byte, crc_byte, 8'd0} :
        (active_code == CODE_REPEAT3) ? repeat3_encode(raw_byte) :
        (active_code == CODE_HAMMING) ? {hamming74_encode(raw_byte[7:4]),
                                         hamming74_encode(raw_byte[3:0]),
                                         10'd0} :
                                        {raw_byte, 16'd0};

    assign encoded_len =
        (active_code == CODE_NONE)    ? 5'd8  :
        (active_code == CODE_CRC8)    ? 5'd16 :
        (active_code == CODE_REPEAT3) ? 5'd24 :
        (active_code == CODE_HAMMING) ? 5'd14 :
                                        5'd8;

    // Stored encoded stream
    reg [23:0] enc_shift;
    reg [4:0]  enc_len;
    reg [4:0]  enc_index;
    reg        enc_loaded;
    reg [23:0] enc_shift2;
    reg [31:0] next_pair_id, frame_pair_id;
    reg [31:0] frame_pair_id_previous, frame_pair_id_previous2, frame_pair_id_previous3;
    wire [31:0] aligned_pair_id =
        (effective_reference_delay == 2'd0) ? frame_pair_id :
        (effective_reference_delay == 2'd1) ? frame_pair_id_previous :
        (effective_reference_delay == 2'd2) ? frame_pair_id_previous2 : frame_pair_id_previous3;
    wire [31:0] aligned2_pair_id =
        (effective_reference_delay2 == 2'd0) ? frame_pair_id :
        (effective_reference_delay2 == 2'd1) ? frame_pair_id_previous :
        (effective_reference_delay2 == 2'd2) ? frame_pair_id_previous2 : frame_pair_id_previous3;

    wire [4:0] enc_bit_pos;
    assign enc_bit_pos = 5'd23 - enc_index;

    wire current_encoded_bit;
    assign current_encoded_bit =
        enc_loaded ? enc_shift[enc_bit_pos] : encoded_frame[23];
    wire current_encoded_bit2 = enc_loaded ? enc_shift2[enc_bit_pos] : encoded_frame2[23];
    wire bit_for_mod2 = bit_start_tick ? current_encoded_bit2 : data_bit2;

    // Same code/rate means identical frame boundaries on both links. The
    // second encoded data and frame ID history advance on the EXACT edge used
    // by the original history pipeline, including the phase-zero adjustment.
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            enc_shift2 <= 24'd0;
            data_bit2 <= 1'b0;
            data_bit2_previous <= 1'b0;
            data_bit2_previous2 <= 1'b0;
            data_bit2_previous3 <= 1'b0;
            next_pair_id <= 32'd0;
            frame_pair_id <= 32'd0;
            frame_pair_id_previous <= 32'd0;
            frame_pair_id_previous2 <= 32'd0;
            frame_pair_id_previous3 <= 32'd0;
            laser_smp2 <= 1'b0;
        end else if (tx_restart_pulse_tx || soft_reset_pulse_tx ||
                     !tx_enable_tx || blink_sw_tx) begin
            enc_shift2 <= 24'd0;
            data_bit2 <= 1'b0;
            data_bit2_previous <= 1'b0;
            data_bit2_previous2 <= 1'b0;
            data_bit2_previous3 <= 1'b0;
            next_pair_id <= 32'd0;
            frame_pair_id <= 32'd0;
            frame_pair_id_previous <= 32'd0;
            frame_pair_id_previous2 <= 32'd0;
            frame_pair_id_previous3 <= 32'd0;
            laser_smp2 <= blink_sw_tx ? blink_state : 1'b0;
        end else begin
            laser_smp2 <= (smp_mode && active_mod == MOD_OOK_NRZ) ? bit_for_mod2 : 1'b0;
            if (bit_start_tick) begin
                data_bit2 <= current_encoded_bit2;
                data_bit2_previous3 <= data_bit2_previous2;
                data_bit2_previous2 <= data_bit2_previous;
                data_bit2_previous <= data_bit2;
                frame_pair_id_previous3 <= frame_pair_id_previous2;
                frame_pair_id_previous2 <= frame_pair_id_previous;
                frame_pair_id_previous <= frame_pair_id;
                if (!enc_loaded) begin
                    enc_shift2 <= encoded_frame2;
                    frame_pair_id <= next_pair_id;
                    next_pair_id <= next_pair_id + 32'd1;
                end
            end
        end
    end

    // ============================================================
    // TX bit timing at 250 MHz
    // ============================================================
    wire bit_for_mod;
    assign bit_for_mod =
        bit_start_tick ? current_encoded_bit : data_bit;

    // ============================================================
    // PWM / PPM timing functions for 250 MHz
    // ============================================================

    function [8:0] pwm_zero_ticks;
        input [8:0] ticks;
        begin
            case (ticks)
                TICKS_1M:  pwm_zero_ticks = 9'd75;
                TICKS_2M:  pwm_zero_ticks = 9'd38;
                TICKS_5M:  pwm_zero_ticks = 9'd15;
                TICKS_10M: pwm_zero_ticks = 9'd8;
                TICKS_25M: pwm_zero_ticks = 9'd3;
                TICKS_50M: pwm_zero_ticks = 9'd2;
                default:   pwm_zero_ticks = 9'd1;
            endcase
        end
    endfunction

    function [8:0] pwm_one_ticks;
        input [8:0] ticks;
        begin
            case (ticks)
                TICKS_1M:  pwm_one_ticks = 9'd175;
                TICKS_2M:  pwm_one_ticks = 9'd88;
                TICKS_5M:  pwm_one_ticks = 9'd35;
                TICKS_10M: pwm_one_ticks = 9'd18;
                TICKS_25M: pwm_one_ticks = 9'd7;
                TICKS_50M: pwm_one_ticks = 9'd4;
                default:   pwm_one_ticks = 9'd1;
            endcase
        end
    endfunction

    function [8:0] ppm_pulse_width;
        input [8:0] ticks;
        begin
            case (ticks)
                TICKS_1M:  ppm_pulse_width = 9'd50;
                TICKS_2M:  ppm_pulse_width = 9'd25;
                TICKS_5M:  ppm_pulse_width = 9'd10;
                TICKS_10M: ppm_pulse_width = 9'd5;
                TICKS_25M: ppm_pulse_width = 9'd2;
                TICKS_50M: ppm_pulse_width = 9'd1;
                default:   ppm_pulse_width = 9'd1;
            endcase
        end
    endfunction

    function [8:0] ppm_zero_start;
        input [8:0] ticks;
        begin
            case (ticks)
                TICKS_1M:  ppm_zero_start = 9'd25;
                TICKS_2M:  ppm_zero_start = 9'd12;
                TICKS_5M:  ppm_zero_start = 9'd5;
                TICKS_10M: ppm_zero_start = 9'd2;
                TICKS_25M: ppm_zero_start = 9'd1;
                TICKS_50M: ppm_zero_start = 9'd0;
                default:   ppm_zero_start = 9'd0;
            endcase
        end
    endfunction

    function [8:0] ppm_one_start;
        input [8:0] ticks;
        begin
            case (ticks)
                TICKS_1M:  ppm_one_start = 9'd150;
                TICKS_2M:  ppm_one_start = 9'd75;
                TICKS_5M:  ppm_one_start = 9'd30;
                TICKS_10M: ppm_one_start = 9'd15;
                TICKS_25M: ppm_one_start = 9'd6;
                TICKS_50M: ppm_one_start = 9'd3;
                default:   ppm_one_start = 9'd1;
            endcase
        end
    endfunction

    wire [8:0] active_pwm_zero_ticks;
    wire [8:0] active_pwm_one_ticks;
    wire [8:0] active_ppm_width;
    wire [8:0] active_ppm_zero_start;
    wire [8:0] active_ppm_one_start;

    assign active_pwm_zero_ticks = pwm_zero_ticks(active_bit_ticks);
    assign active_pwm_one_ticks  = pwm_one_ticks(active_bit_ticks);
    assign active_ppm_width      = ppm_pulse_width(active_bit_ticks);
    assign active_ppm_zero_start = ppm_zero_start(active_bit_ticks);
    assign active_ppm_one_start  = ppm_one_start(active_bit_ticks);

    // ============================================================
    // Modulator
    // ============================================================
    reg modulated_laser;

    always @(*) begin
        case (active_mod)

            MOD_OOK_NRZ: begin
                modulated_laser = bit_for_mod;
            end

            MOD_OOK_RZ: begin
                modulated_laser =
                    bit_for_mod &&
                    (bit_phase < (active_bit_ticks >> 1));
            end

            MOD_PWM: begin
                if (bit_for_mod)
                    modulated_laser = (bit_phase < active_pwm_one_ticks);
                else
                    modulated_laser = (bit_phase < active_pwm_zero_ticks);
            end

            MOD_PPM: begin
                if (bit_for_mod)
                    modulated_laser =
                        (bit_phase >= active_ppm_one_start) &&
                        (bit_phase <  active_ppm_one_start + active_ppm_width);
                else
                    modulated_laser =
                        (bit_phase >= active_ppm_zero_start) &&
                        (bit_phase <  active_ppm_zero_start + active_ppm_width);
            end

            default: begin
                modulated_laser = 1'b0;
            end

        endcase
    end

    // Predict the bit boundary one clock ahead. The period counter uses a
    // registered terminal strobe instead of compare -> wrap feedback in one
    // 4 ns cycle. Start/end strobes remain exactly equivalent to phase 0/last.
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            bit_start_tick <= 1'b1;
            bit_end_tick <= 1'b0;
        end else if (blink_sw_tx || tx_restart_pulse_tx || !tx_enable_tx) begin
            bit_start_tick <= 1'b1;
            bit_end_tick <= 1'b0;
        end else begin
            bit_end_tick <= (bit_phase == active_penultimate_phase);
            bit_start_tick <= bit_end_tick;
        end
    end

    // ============================================================
    // TX generator: data plane runs at 250 MHz
    // Manual blink switch has highest priority.
    // Soft reset / stop clears all TX memory/register state.
    // ============================================================
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            prbs7      <= 7'b1111111;
            prbs15     <= 15'b111111111111111;
            count_byte <= 8'h00;

            bit_phase  <= 9'd0;
            data_bit   <= 1'b0;

            enc_shift  <= 24'd0;
            enc_len    <= 5'd8;
            enc_index  <= 5'd0;
            enc_loaded <= 1'b0;

            payload_tx_bits <= 32'd0;
            user_text_tx_index <= 6'd0;

            frame_start_bit <= 1'b0;
            frame_len_latched <= 5'd8;
            frame_code_latched <= CODE_NONE;
            frame_text_index_latched <= 6'd0;

            laser_ep   <= 1'b0;

        end else begin

            // Manual board-test mode has highest priority.
            if (blink_sw_tx) begin
                laser_ep   <= blink_state;

                bit_phase  <= 9'd0;
                data_bit   <= 1'b0;
                enc_loaded <= 1'b0;
                enc_index  <= 5'd0;
                frame_start_bit <= 1'b0;
            end

            // Stop, reset, or new start all restart the stream memory.
            else if (tx_restart_pulse_tx) begin
                prbs7      <= 7'b1111111;
                prbs15     <= 15'b111111111111111;
                count_byte <= 8'h00;

                bit_phase  <= 9'd0;
                data_bit   <= 1'b0;

                enc_shift  <= 24'd0;
                enc_len    <= 5'd8;
                enc_index  <= 5'd0;
                enc_loaded <= 1'b0;

                payload_tx_bits <= 32'd0;
                user_text_tx_index <= 6'd0;

                frame_start_bit <= 1'b0;
                frame_len_latched <= 5'd8;
                frame_code_latched <= CODE_NONE;
                frame_text_index_latched <= 6'd0;

                laser_ep   <= 1'b0;
            end

            else if (!tx_enable_tx) begin
                bit_phase  <= 9'd0;
                data_bit   <= 1'b0;
                enc_loaded <= 1'b0;
                enc_index  <= 5'd0;
                frame_start_bit <= 1'b0;
                laser_ep   <= 1'b0;
            end

            else begin
                laser_ep <= modulated_laser;

                // Load/send one encoded bit at the start of each bit period
                if (bit_start_tick) begin

                    // The registered launch event is counted in the local accumulator below.
                    data_bit <= current_encoded_bit;

                    if (!enc_loaded) begin
                        // One new source byte enters the encoder.
                        // In supported BER modes, count transmitted payload only
                        // after RX lock. This gives TX and RX the same measurement
                        // start point and removes the misleading startup TX lead.
                        // Unsupported TX-only modes still count generated payload.
                        if (!rx_rate_supported || selected_rx_locked)
                            payload_tx_bits <= payload_tx_bits + 32'd8;

                        // Mark this whole line-bit period as the first bit of a
                        // new encoded frame. The RX payload decoder starts only
                        // when this bit is sampled, so it cannot begin mid-frame.
                        frame_start_bit <= 1'b1;
                        frame_len_latched <= encoded_len;
                        frame_code_latched <= active_code;
                        frame_text_index_latched <= user_text_tx_index;

                        enc_shift  <= encoded_frame;
                        enc_len    <= encoded_len;
                        enc_index  <= 5'd1;
                        enc_loaded <= 1'b1;

                        // Advance raw source once per encoded frame
                        case (active_mode)

                            MODE_PRBS7: begin
                                prbs7 <= smp_mode ? prbs7_advance8(prbs7_advance8(prbs7)) :
                                                   prbs7_advance8(prbs7);
                            end

                            MODE_PRBS15: begin
                                prbs15 <= smp_mode ? prbs15_advance8(prbs15_advance8(prbs15)) :
                                                    prbs15_advance8(prbs15);
                            end

                            MODE_ASCII_S: begin
                                // keep sending ASCII "S"
                            end

                            MODE_COUNTER: begin
                                count_byte <= count_byte + (smp_mode ? 8'd2 : 8'd1);
                            end

                            MODE_USER_TEXT: begin
                                user_text_tx_index <= smp_mode ? text_index_after_pair : text_index_next;
                            end

                            default: begin
                                // do nothing
                            end

                        endcase

                    end else begin

                        frame_start_bit <= 1'b0;

                        if (enc_index == enc_len - 5'd1) begin
                            enc_loaded <= 1'b0;
                            enc_index  <= 5'd0;
                        end else begin
                            enc_index <= enc_index + 5'd1;
                        end

                    end
                end

                if (bit_end_tick)
                    bit_phase <= 9'd0;
                else
                    bit_phase <= bit_phase + 9'd1;

            end
        end
    end


    // ============================================================
    // Independent TX accounting, firmware TXF1.
    // No RX lock, GUI factor or timer enters this counter. Credit the
    // encoded length only after its final registered output tick has
    // completed. The existing serializer and legacy counter are untouched.
    // ============================================================
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            tx_last_bit_pending   <= 1'b0;
            tx_last_frame_len     <= 5'd0;
            tx_frame_done_pending <= 1'b0;
            tx_frame_done_len     <= 5'd0;
        end else if (tx_restart_pulse_tx || soft_reset_pulse_tx) begin
            tx_last_bit_pending   <= 1'b0;
            tx_last_frame_len     <= 5'd0;
            tx_frame_done_pending <= 1'b0;
            tx_frame_done_len     <= 5'd0;
        end else begin
            // The preceding edge launched the final output tick. Its
            // full duration has now elapsed, even if blink/disable starts
            // on this edge. Count that completed frame exactly once.
            tx_frame_done_pending <= 1'b0;

            if (blink_sw_tx || !tx_enable_tx) begin
                // An interrupted partial frame receives no frame credit.
                tx_last_bit_pending <= 1'b0;
            end else begin
                if (bit_start_tick && enc_loaded &&
                    (enc_index == enc_len - 5'd1)) begin
                    tx_last_bit_pending <= 1'b1;
                    tx_last_frame_len   <= enc_len;
                end
                if (bit_end_tick &&
                    tx_last_bit_pending) begin
                    tx_last_bit_pending   <= 1'b0;
                    tx_frame_done_pending <= 1'b1;
                    tx_frame_done_len     <= tx_last_frame_len;
                end
            end
        end
    end

    // Timing-oriented TX counter implementation.
    //
    // Observable contract (unchanged):
    //   * one line credit for each registered tx_line_event;
    //   * tx_frame_done_len credits on each tx_frame_done_pending event;
    //   * the new total is visible exactly two clk_250 edges after the source
    //     event which created tx_line_event/tx_frame_done_pending;
    //   * restart/soft-reset has the same one-local-clock delayed clear as the
    //     previous tx_counter_reset pipeline.
    //
    // The counters are physically split into bytes.  Stage 1 calculates the
    // low byte and all higher-byte +1 alternatives in parallel.  Stage 2 uses
    // captured all-ones propagate flags to select those alternatives.  Thus no
    // 16/32-bit carry chain remains in either pipeline stage.

    reg [7:0] tx_frame_bits_b0, tx_frame_bits_b1;
    reg [7:0] tx_frame_bits_b2, tx_frame_bits_b3;
    reg [7:0] tx_line_bits_b0, tx_line_bits_b1;
    reg [7:0] tx_line_bits_b2, tx_line_bits_b3;

    assign tx_frame_bits = {tx_frame_bits_b3, tx_frame_bits_b2,
                            tx_frame_bits_b1, tx_frame_bits_b0};
    assign tx_line_bits  = {tx_line_bits_b3, tx_line_bits_b2,
                            tx_line_bits_b1, tx_line_bits_b0};

    reg tx_line_event;
    reg tx_frame_add_valid, tx_line_add_valid;

    // These are intentionally distinct physical reset-pipeline registers.
    // `preserve` keeps each register; `dont_merge` prevents Quartus from
    // recreating the high-fanout shared reset register which motivated this
    // replacement.  Each replica drives only one counter byte (or valid bits).
    (* preserve, dont_merge *) reg tx_counter_reset_valid;
    (* preserve, dont_merge *) reg tx_frame_reset_b0;
    (* preserve, dont_merge *) reg tx_frame_reset_b1;
    (* preserve, dont_merge *) reg tx_frame_reset_b2;
    (* preserve, dont_merge *) reg tx_frame_reset_b3;
    (* preserve, dont_merge *) reg tx_line_reset_b0;
    (* preserve, dont_merge *) reg tx_line_reset_b1;
    (* preserve, dont_merge *) reg tx_line_reset_b2;
    (* preserve, dont_merge *) reg tx_line_reset_b3;

    reg [8:0] tx_frame_b0_sum_s1;
    reg [7:0] tx_frame_b1_base_s1, tx_frame_b1_inc_s1;
    reg [7:0] tx_frame_b2_base_s1, tx_frame_b2_inc_s1;
    reg [7:0] tx_frame_b3_base_s1, tx_frame_b3_inc_s1;
    reg       tx_frame_b1_prop_s1, tx_frame_b2_prop_s1;

    reg [8:0] tx_line_b0_sum_s1;
    reg [7:0] tx_line_b1_base_s1, tx_line_b1_inc_s1;
    reg [7:0] tx_line_b2_base_s1, tx_line_b2_inc_s1;
    reg [7:0] tx_line_b3_base_s1, tx_line_b3_inc_s1;
    reg       tx_line_b1_prop_s1, tx_line_b2_prop_s1;

    wire tx_frame_carry_b1 = tx_frame_b0_sum_s1[8];
    wire tx_frame_carry_b2 = tx_frame_carry_b1 & tx_frame_b1_prop_s1;
    wire tx_frame_carry_b3 = tx_frame_carry_b2 & tx_frame_b2_prop_s1;
    wire tx_line_carry_b1  = tx_line_b0_sum_s1[8];
    wire tx_line_carry_b2  = tx_line_carry_b1 & tx_line_b1_prop_s1;
    wire tx_line_carry_b3  = tx_line_carry_b2 & tx_line_b2_prop_s1;

    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            tx_counter_reset_valid <= 1'b1;
            tx_frame_reset_b0 <= 1'b1;
            tx_frame_reset_b1 <= 1'b1;
            tx_frame_reset_b2 <= 1'b1;
            tx_frame_reset_b3 <= 1'b1;
            tx_line_reset_b0 <= 1'b1;
            tx_line_reset_b1 <= 1'b1;
            tx_line_reset_b2 <= 1'b1;
            tx_line_reset_b3 <= 1'b1;
            tx_line_event <= 1'b0;
        end else begin
            tx_counter_reset_valid <= tx_restart_pulse_tx || soft_reset_pulse_tx;
            tx_frame_reset_b0 <= tx_restart_pulse_tx || soft_reset_pulse_tx;
            tx_frame_reset_b1 <= tx_restart_pulse_tx || soft_reset_pulse_tx;
            tx_frame_reset_b2 <= tx_restart_pulse_tx || soft_reset_pulse_tx;
            tx_frame_reset_b3 <= tx_restart_pulse_tx || soft_reset_pulse_tx;
            tx_line_reset_b0 <= tx_restart_pulse_tx || soft_reset_pulse_tx;
            tx_line_reset_b1 <= tx_restart_pulse_tx || soft_reset_pulse_tx;
            tx_line_reset_b2 <= tx_restart_pulse_tx || soft_reset_pulse_tx;
            tx_line_reset_b3 <= tx_restart_pulse_tx || soft_reset_pulse_tx;

            if (tx_restart_pulse_tx || soft_reset_pulse_tx)
                tx_line_event <= 1'b0;
            else
                tx_line_event <= !blink_sw_tx && tx_enable_tx && bit_start_tick;
        end
    end

    // Stage 1.  All additions are at most nine bits and are independent.
    // Data registers need no reset because the valid pipeline suppresses stale
    // values across every hardware/restart/soft-reset case.
    always @(posedge clk_250) begin
        tx_frame_b0_sum_s1  <= {1'b0, tx_frame_bits_b0} +
                              {4'd0, tx_frame_done_len};
        tx_frame_b1_base_s1 <= tx_frame_bits_b1;
        tx_frame_b1_inc_s1  <= tx_frame_bits_b1 + 8'd1;
        tx_frame_b1_prop_s1 <= &tx_frame_bits_b1;
        tx_frame_b2_base_s1 <= tx_frame_bits_b2;
        tx_frame_b2_inc_s1  <= tx_frame_bits_b2 + 8'd1;
        tx_frame_b2_prop_s1 <= &tx_frame_bits_b2;
        tx_frame_b3_base_s1 <= tx_frame_bits_b3;
        tx_frame_b3_inc_s1  <= tx_frame_bits_b3 + 8'd1;

        tx_line_b0_sum_s1   <= {1'b0, tx_line_bits_b0} + 9'd1;
        tx_line_b1_base_s1  <= tx_line_bits_b1;
        tx_line_b1_inc_s1   <= tx_line_bits_b1 + 8'd1;
        tx_line_b1_prop_s1  <= &tx_line_bits_b1;
        tx_line_b2_base_s1  <= tx_line_bits_b2;
        tx_line_b2_inc_s1   <= tx_line_bits_b2 + 8'd1;
        tx_line_b2_prop_s1  <= &tx_line_bits_b2;
        tx_line_b3_base_s1  <= tx_line_bits_b3;
        tx_line_b3_inc_s1   <= tx_line_bits_b3 + 8'd1;
    end

    // Stage 2 publication.  Higher bytes choose a precomputed +0/+1 result;
    // the only cross-byte logic is the three-level carry-prefix AND.
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            tx_frame_add_valid <= 1'b0;
            tx_line_add_valid <= 1'b0;
        end else if (tx_counter_reset_valid) begin
            tx_frame_add_valid <= 1'b0;
            tx_line_add_valid <= 1'b0;
        end else begin
            tx_frame_add_valid <= tx_frame_done_pending;
            tx_line_add_valid <= tx_line_event;
        end
    end

    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n)
            tx_frame_bits_b0 <= 8'd0;
        else if (tx_frame_reset_b0)
            tx_frame_bits_b0 <= 8'd0;
        else if (tx_frame_add_valid)
            tx_frame_bits_b0 <= tx_frame_b0_sum_s1[7:0];
    end
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n)
            tx_frame_bits_b1 <= 8'd0;
        else if (tx_frame_reset_b1)
            tx_frame_bits_b1 <= 8'd0;
        else if (tx_frame_add_valid)
            tx_frame_bits_b1 <= tx_frame_carry_b1 ?
                                tx_frame_b1_inc_s1 : tx_frame_b1_base_s1;
    end
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n)
            tx_frame_bits_b2 <= 8'd0;
        else if (tx_frame_reset_b2)
            tx_frame_bits_b2 <= 8'd0;
        else if (tx_frame_add_valid)
            tx_frame_bits_b2 <= tx_frame_carry_b2 ?
                                tx_frame_b2_inc_s1 : tx_frame_b2_base_s1;
    end
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n)
            tx_frame_bits_b3 <= 8'd0;
        else if (tx_frame_reset_b3)
            tx_frame_bits_b3 <= 8'd0;
        else if (tx_frame_add_valid)
            tx_frame_bits_b3 <= tx_frame_carry_b3 ?
                                tx_frame_b3_inc_s1 : tx_frame_b3_base_s1;
    end

    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n)
            tx_line_bits_b0 <= 8'd0;
        else if (tx_line_reset_b0)
            tx_line_bits_b0 <= 8'd0;
        else if (tx_line_add_valid)
            tx_line_bits_b0 <= tx_line_b0_sum_s1[7:0];
    end
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n)
            tx_line_bits_b1 <= 8'd0;
        else if (tx_line_reset_b1)
            tx_line_bits_b1 <= 8'd0;
        else if (tx_line_add_valid)
            tx_line_bits_b1 <= tx_line_carry_b1 ?
                               tx_line_b1_inc_s1 : tx_line_b1_base_s1;
    end
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n)
            tx_line_bits_b2 <= 8'd0;
        else if (tx_line_reset_b2)
            tx_line_bits_b2 <= 8'd0;
        else if (tx_line_add_valid)
            tx_line_bits_b2 <= tx_line_carry_b2 ?
                               tx_line_b2_inc_s1 : tx_line_b2_base_s1;
    end
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n)
            tx_line_bits_b3 <= 8'd0;
        else if (tx_line_reset_b3)
            tx_line_bits_b3 <= 8'd0;
        else if (tx_line_add_valid)
            tx_line_bits_b3 <= tx_line_carry_b3 ?
                               tx_line_b3_inc_s1 : tx_line_b3_base_s1;
    end

    // ============================================================
    // RX digital loopback BER test
    //
    // Supported in this measured-limit test:
    // Data type: PRBS7, PRBS15, ASCII S, Counter, User Text placeholder
    // Coding: None, CRC-8, Repeat-3, Hamming-7,4
    // Modulation/rate limits:
    //   OOK-NRZ <= 50 Mbps with runtime phase/delay tuning
    //   OOK-RZ  <= 10 Mbps
    //   PWM/PPM <= 5 Mbps
    //
    // Hardware:
    // laser_ep -> 220 ohm or 330 ohm resistor -> rx_in
    // ============================================================
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            rx_meta        <= 1'b0;
            rx_sync        <= 1'b0;
            rx_locked      <= 1'b0;
            rx_match_count <= 5'd0;
            rx_health_count <= 6'd0;
            rx_health_errors <= 6'd0;
            rx_total_bits  <= 32'd0;
            rx_error_bits  <= 32'd0;
            ppm_early_count <= 9'd0;
            ppm_late_count  <= 9'd0;

        end else begin

            // Two-flip-flop synchronizer
            rx_meta <= rx_in;
            rx_sync <= rx_meta;

            // PPM early/late pulse-position measurement.
            // The decision is made at the final tick of each bit period.
            if (tx_restart_pulse_tx || soft_reset_pulse_tx ||
                !rx_supported || (active_mod != MOD_PPM)) begin
                ppm_early_count <= 9'd0;
                ppm_late_count  <= 9'd0;
            end else begin
                if (bit_start_tick) begin
                    ppm_early_count <= (rx_sync && (9'd0 < ppm_mid_phase)) ? 9'd1 : 9'd0;
                    ppm_late_count  <= (rx_sync && (9'd0 >= ppm_mid_phase)) ? 9'd1 : 9'd0;
                end else begin
                    if (bit_phase < ppm_mid_phase)
                        ppm_early_count <= ppm_early_count + (rx_sync ? 9'd1 : 9'd0);
                    else
                        ppm_late_count <= ppm_late_count + (rx_sync ? 9'd1 : 9'd0);
                end
            end

            if (tx_restart_pulse_tx || soft_reset_pulse_tx) begin
                rx_locked      <= 1'b0;
                rx_match_count <= 5'd0;
                rx_health_count <= 6'd0;
                rx_health_errors <= 6'd0;
                rx_total_bits  <= 32'd0;
                rx_error_bits  <= 32'd0;
            end

            else if (!rx_supported) begin
                rx_locked      <= 1'b0;
                rx_match_count <= 5'd0;
                rx_health_count <= 6'd0;
                rx_health_errors <= 6'd0;
            end

            else if (rx_sample_tick) begin

                if (!rx_locked) begin
                    rx_health_count  <= 6'd0;
                    rx_health_errors <= 6'd0;
                    if (demod_rx_bit == rx_expected_level) begin
                        if (rx_match_count == 5'd15) begin
                            rx_locked      <= 1'b1;
                            rx_match_count <= 5'd16;
                            rx_total_bits  <= rx_total_bits + 32'd1;
                        end else begin
                            rx_match_count <= rx_match_count + 5'd1;
                        end
                    end else begin
                        rx_match_count <= 5'd0;
                    end
                end

                else begin
                    rx_total_bits <= rx_total_bits + 32'd1;

                    if (demod_rx_bit != rx_expected_level)
                        rx_error_bits <= rx_error_bits + 32'd1;

                    if (rx_health_count == RX_HEALTH_WINDOW_LAST) begin
                        if ((rx_health_errors +
                             ((demod_rx_bit != rx_expected_level) ? 6'd1 : 6'd0)) >=
                            RX_HEALTH_UNLOCK_ERRORS) begin
                            rx_locked      <= 1'b0;
                            rx_match_count <= 5'd0;
                        end
                        rx_health_count  <= 6'd0;
                        rx_health_errors <= 6'd0;
                    end else begin
                        rx_health_count <= rx_health_count + 6'd1;
                        if (demod_rx_bit != rx_expected_level)
                            rx_health_errors <= rx_health_errors + 6'd1;
                    end
                end
            end
        end
    end

    // ============================================================
    // RX2 OOK-NRZ receiver: independent input synchronizer, phase/delay,
    // acquisition lock, checked-bit count, and line-error count.
    // ============================================================
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            rx2_meta        <= 1'b0;
            rx2_sync        <= 1'b0;
            rx2_locked      <= 1'b0;
            rx2_match_count <= 5'd0;
            rx2_health_count <= 6'd0;
            rx2_health_errors <= 6'd0;
            rx2_total_bits  <= 32'd0;
            rx2_error_bits  <= 32'd0;
        end else begin
            rx2_meta <= rx_in2;
            rx2_sync <= rx2_meta;

            if (tx_restart_pulse_tx || soft_reset_pulse_tx) begin
                rx2_locked      <= 1'b0;
                rx2_match_count <= 5'd0;
                rx2_health_count <= 6'd0;
                rx2_health_errors <= 6'd0;
                rx2_total_bits  <= 32'd0;
                rx2_error_bits  <= 32'd0;
            end else if (!rx2_supported) begin
                rx2_locked      <= 1'b0;
                rx2_match_count <= 5'd0;
                rx2_health_count <= 6'd0;
                rx2_health_errors <= 6'd0;
            end else if (rx2_sample_tick) begin
                if (!rx2_locked) begin
                    rx2_health_count  <= 6'd0;
                    rx2_health_errors <= 6'd0;
                    if (rx2_demod_bit == aligned2_data_bit) begin
                        if (rx2_match_count == 5'd15) begin
                            rx2_locked      <= 1'b1;
                            rx2_match_count <= 5'd16;
                            rx2_total_bits  <= rx2_total_bits + 32'd1;
                        end else begin
                            rx2_match_count <= rx2_match_count + 5'd1;
                        end
                    end else begin
                        rx2_match_count <= 5'd0;
                    end
                end else begin
                    rx2_total_bits <= rx2_total_bits + 32'd1;
                    if (rx2_demod_bit != aligned2_data_bit)
                        rx2_error_bits <= rx2_error_bits + 32'd1;

                    if (rx2_health_count == RX_HEALTH_WINDOW_LAST) begin
                        if ((rx2_health_errors +
                             ((rx2_demod_bit != aligned2_data_bit) ? 6'd1 : 6'd0)) >=
                            RX_HEALTH_UNLOCK_ERRORS) begin
                            rx2_locked      <= 1'b0;
                            rx2_match_count <= 5'd0;
                        end
                        rx2_health_count  <= 6'd0;
                        rx2_health_errors <= 6'd0;
                    end else begin
                        rx2_health_count <= rx2_health_count + 6'd1;
                        if (rx2_demod_bit != aligned2_data_bit)
                            rx2_health_errors <= rx2_health_errors + 6'd1;
                    end
                end
            end
        end
    end

    // ============================================================
    // Honest digital selection diversity.
    //
    // The selector never uses the known TX bit to repair an individual RX
    // bit. Instead it measures each branch for a complete one-second window,
    // selects the lower-BER locked branch after normalizing for each branch's
    // checked-bit exposure, and stays on the current branch on a tie or an
    // empty window. Lock availability overrides quality immediately. The common
    // decoder changes branch only through the boundary-qualified wires above.
    // ============================================================
    assign quality_compare_cancel = tx_restart_pulse_tx || soft_reset_pulse_tx ||
        !diversity_mode || !rx2_supported || !rx_locked || !rx2_locked;
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            quality_window_count       <= 28'd0;
            rx1_window_bits             <= 32'd0;
            rx2_window_bits             <= 32'd0;
            rx1_window_errors           <= 32'd0;
            rx2_window_errors           <= 32'd0;
            rx1_previous_window_bits    <= 32'd0;
            rx2_previous_window_bits    <= 32'd0;
            rx1_previous_window_errors  <= 32'd0;
            rx2_previous_window_errors  <= 32'd0;
            preferred_rx2              <= 1'b0;
            selected_rx2               <= 1'b0;
        end else if (tx_restart_pulse_tx || soft_reset_pulse_tx ||
                     !diversity_mode || !rx2_supported) begin
            quality_window_count       <= 28'd0;
            rx1_window_bits             <= 32'd0;
            rx2_window_bits             <= 32'd0;
            rx1_window_errors           <= 32'd0;
            rx2_window_errors           <= 32'd0;
            rx1_previous_window_bits    <= 32'd0;
            rx2_previous_window_bits    <= 32'd0;
            rx1_previous_window_errors  <= 32'd0;
            rx2_previous_window_errors  <= 32'd0;
            preferred_rx2              <= 1'b0;
            selected_rx2               <= 1'b0;
        end else begin
            if (rx_sample_tick && rx_locked) begin
                rx1_window_bits <= rx1_window_bits + 32'd1;
                if (demod_rx_bit != aligned_data_bit)
                    rx1_window_errors <= rx1_window_errors + 32'd1;
            end

            if (rx2_sample_tick && rx2_locked) begin
                rx2_window_bits <= rx2_window_bits + 32'd1;
                if (rx2_demod_bit != aligned2_data_bit)
                    rx2_window_errors <= rx2_window_errors + 32'd1;
            end

            if (quality_window_count == QUALITY_WINDOW_MAX) begin
                quality_window_count      <= 28'd0;
                rx1_previous_window_bits   <= rx1_window_bits;
                rx2_previous_window_bits   <= rx2_window_bits;
                rx1_previous_window_errors <= rx1_window_errors;
                rx2_previous_window_errors <= rx2_window_errors;
                rx1_window_bits            <= 32'd0;
                rx2_window_bits            <= 32'd0;
                rx1_window_errors          <= 32'd0;
                rx2_window_errors          <= 32'd0;

                // An exact pipelined result updates preference below.
            end else begin
                quality_window_count <= quality_window_count + 28'd1;
            end

            if (quality_compare_valid && !quality_compare_cancel) begin
                if (quality_rx2_better)
                    preferred_rx2 <= 1'b1;
                else if (quality_rx1_better)
                    preferred_rx2 <= 1'b0;
            end

            // Lock availability has higher priority than the one-second
            // quality result and updates the requested branch immediately.
            if (rx2_locked && !rx_locked)
                preferred_rx2 <= 1'b1;
            else if (rx_locked && !rx2_locked)
                preferred_rx2 <= 1'b0;

            if (switch_to_rx2_at_boundary)
                selected_rx2 <= 1'b1;
            else if (switch_to_rx1_at_boundary)
                selected_rx2 <= 1'b0;
        end
    end


    // ============================================================
    // Payload-level decoder, BER counter, and User Text reconstruction
    //
    // Important fix:
    // The decoder no longer runs a free-running frame counter. It waits until
    // the raw receiver is locked, then starts collecting only on the sampled
    // FIRST BIT of a TX encoded frame (frame_start_bit). This prevents the
    // first decoded payload byte from containing pre-lock or mid-frame bits.
    //
    // The recovered encoded frame is right-aligned before calling
    // decode_frame_byte(), matching the old 100 MHz receiver logic.
    // ============================================================
    // ============================================================
    // V2.3: registered sample -> selected event -> encoded frame ->
    // paired decoded byte -> local commit -> packed immutable snapshot.
    // Pipelined controls avoid raw command/reset gating on the text data bank.
    // The sampling instant and matching reference metadata are unchanged.
    // ============================================================
    reg [1:0] text_tick_d, text_lock_d, text_bit_d, text_ref_d, text_start_d;
    reg [4:0] text_len_d [0:1];
    reg [1:0] text_code_d [0:1];
    reg [5:0] text_index_d [0:1];
    reg text_select_d, text_support_d;
    reg text_event_tick, text_event_locked, text_event_bit, text_event_ref;
    reg text_event_start, text_event_supported;
    reg [4:0] text_event_len;
    reg [1:0] text_event_code;
    reg [5:0] text_event_index;

    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            text_tick_d <= 0; text_lock_d <= 0; text_bit_d <= 0;
            text_ref_d <= 0; text_start_d <= 0; text_select_d <= 0;
            text_support_d <= 0;
            text_len_d[0] <= 8; text_len_d[1] <= 8;
            text_code_d[0] <= CODE_NONE; text_code_d[1] <= CODE_NONE;
            text_index_d[0] <= 0; text_index_d[1] <= 0;
            text_event_tick <= 0; text_event_locked <= 0;
            text_event_bit <= 0; text_event_ref <= 0; text_event_start <= 0;
            text_event_supported <= 0; text_event_len <= 8;
            text_event_code <= CODE_NONE; text_event_index <= 0;
        end else if (tx_restart_pulse_tx || soft_reset_pulse_tx) begin
            text_tick_d <= 0; text_lock_d <= 0; text_support_d <= 0;
            text_event_tick <= 0; text_event_locked <= 0;
            text_event_supported <= 0;
        end else begin
            text_tick_d <= {rx2_sample_tick, rx_sample_tick};
            text_lock_d <= {rx2_locked, rx_locked};
            text_bit_d <= {rx2_demod_bit, demod_rx_bit};
            text_ref_d <= {aligned2_data_bit, aligned_data_bit};
            text_start_d <= {aligned2_frame_start_bit, aligned_frame_start_bit};
            text_len_d[0] <= aligned_frame_len;
            text_len_d[1] <= aligned2_frame_len;
            text_code_d[0] <= aligned_frame_code;
            text_code_d[1] <= aligned2_frame_code;
            text_index_d[0] <= aligned_frame_text_index;
            text_index_d[1] <= aligned2_frame_text_index;
            text_select_d <= selected_rx2_for_mux;
            text_support_d <= payload_rx_supported;

            text_event_tick <= text_tick_d[text_select_d];
            text_event_locked <= text_lock_d[text_select_d];
            text_event_bit <= text_bit_d[text_select_d];
            text_event_ref <= text_ref_d[text_select_d];
            text_event_start <= text_start_d[text_select_d];
            text_event_len <= text_len_d[text_select_d];
            text_event_code <= text_code_d[text_select_d];
            text_event_index <= text_index_d[text_select_d];
            text_event_supported <= text_support_d;
        end
    end

    // ===== DONOR BLOCK A: replace payload_complete_valid declarations through
    // the end of the payload decoder/counter always blocks; leave the preceding
    // V2.3.1 sampled-RX/selected-event pipeline and following source probes alone.
    // Data registers deliberately have NO reset. Only valid/control registers
    // reset: no uninitialized data is observable as a decoded/committed byte.
    reg payload_local_tick, payload_local_flush, payload_local_restart;
    reg [15:0] payload_local_sample;
    wire payload_local_start = payload_local_sample[15];
    wire [4:0] payload_local_len = payload_local_sample[14:10];
    wire [1:0] payload_local_code = payload_local_sample[9:8];
    wire [5:0] payload_local_index = payload_local_sample[7:2];
    wire [1:0] payload_local_pair = payload_local_sample[1:0];
    wire payload_event_flush = payload_local_flush;

    always @(posedge clk_250) begin
        payload_local_sample <= {text_event_start, text_event_len,
            text_event_code, text_event_index, text_event_bit, text_event_ref};
    end
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            payload_local_tick <= 0;
            payload_local_flush <= 1;
            payload_local_restart <= 1;
        end else begin
            payload_local_tick <= text_event_tick;
            payload_local_restart <= tx_restart_pulse_tx || soft_reset_pulse_tx;
            payload_local_flush <= tx_restart_pulse_tx || soft_reset_pulse_tx ||
                                   !text_event_supported || !text_event_locked;
        end
    end

    reg [47:0] payload_pair_shift;
    wire [47:0] payload_pair_next = {payload_pair_shift[45:0], payload_local_pair};
    reg [49:0] payload_complete_tuple;
    reg payload_complete_valid;
    wire [1:0] payload_complete_code = payload_complete_tuple[49:48];
    wire [23:0] payload_complete_rx, payload_complete_tx;
    genvar text_pair_bit;
    generate for (text_pair_bit=0; text_pair_bit<24;
                  text_pair_bit=text_pair_bit+1) begin : text_frame_unpair
        assign payload_complete_rx[text_pair_bit] = payload_complete_tuple[2*text_pair_bit+1];
        assign payload_complete_tx[text_pair_bit] = payload_complete_tuple[2*text_pair_bit];
    end endgenerate

    // A single local tick FF drives the 48-bit shift enable. Shifting while
    // unlocked is harmless: only a fresh complete frame obtains valid=1.
    // The complete tuple is an unconditional data pipeline register, avoiding
    // frame-end comparison/control fanout to its 50 data FFs.
    always @(posedge clk_250) begin
        if (payload_local_tick) payload_pair_shift <= payload_pair_next;
        payload_complete_tuple <= {payload_frame_code, payload_pair_next};
    end
    reg [4:0] payload_last_bit;
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            payload_complete_valid <= 0;
            payload_bit_count <= 0; payload_collecting <= 0;
            payload_frame_len <= 8; payload_last_bit <= 7;
            payload_frame_code <= CODE_NONE; payload_frame_text_index <= 0;
        end else begin
            payload_complete_valid <= 0;
            if (payload_local_flush) begin
                payload_bit_count <= 0; payload_collecting <= 0;
            end else if (payload_local_tick) begin
                if (payload_local_start) begin
                    payload_collecting <= 1;
                    payload_bit_count <= 1;
                    payload_frame_len <= payload_local_len;
                    payload_last_bit <= payload_local_len - 5'd1;
                    payload_frame_code <= payload_local_code;
                    payload_frame_text_index <= payload_local_index;
                end else if (payload_collecting) begin
                    if (payload_bit_count == payload_last_bit) begin
                        payload_complete_valid <= 1;
                        payload_collecting <= 0; payload_bit_count <= 0;
                    end else payload_bit_count <= payload_bit_count + 5'd1;
                end
            end
        end
    end

    // Three decode stages: (A) independent simple candidates + Hamming
    // syndrome, (B) Hamming correction, (C) code selection. Both lanes use
    // the same metadata and valid pipeline; RX is NEVER replaced with REF.
    function [7:0] text_repeat_decode;
        input [23:0] frame;
        integer n;
        begin
            for (n=0; n<8; n=n+1)
                text_repeat_decode[n] = (frame[3*n] & frame[3*n+1]) |
                    (frame[3*n] & frame[3*n+2]) | (frame[3*n+1] & frame[3*n+2]);
        end
    endfunction
    function [2:0] text_hamming_syndrome;
        input [6:0] frame;
        begin
            text_hamming_syndrome = {
                frame[3]^frame[2]^frame[1]^frame[0],
                frame[5]^frame[4]^frame[1]^frame[0],
                frame[6]^frame[4]^frame[2]^frame[0]};
        end
    endfunction
    function [3:0] text_hamming_correct_data;
        input [3:0] data;
        input [2:0] syndrome;
        begin
            text_hamming_correct_data = data ^ {
                (syndrome == 3'd3), (syndrome == 3'd5),
                (syndrome == 3'd6), (syndrome == 3'd7)};
        end
    endfunction
    function [2:0] text_popcount4;
        input [3:0] bits;
        begin
            text_popcount4 = {2'd0,bits[0]} + {2'd0,bits[1]} +
                             {2'd0,bits[2]} + {2'd0,bits[3]};
        end
    endfunction

    reg [1:0] payload_decode_a_code, payload_decode_b_code;
    reg [15:0] payload_decode_a_none, payload_decode_a_crc, payload_decode_a_repeat;
    reg [15:0] payload_decode_a_hamming_data;
    reg [11:0] payload_decode_a_syndrome;
    reg [15:0] payload_decode_b_none, payload_decode_b_crc, payload_decode_b_repeat;
    reg [15:0] payload_decode_b_hamming;
    reg payload_decode_a_valid, payload_decode_b_valid;
    reg [15:0] payload_decoded_pair;
    wire [7:0] payload_decoded_rx = payload_decoded_pair[15:8];
    wire [7:0] payload_decoded_tx = payload_decoded_pair[7:0];
    reg payload_decoded_valid;
    reg [7:0] payload_error_xor;
    reg payload_error_xor_valid, payload_error_nibbles_valid;
    reg [2:0] payload_error_low, payload_error_high;
    reg [3:0] payload_decoded_errors;
    reg payload_error_valid;
    always @(posedge clk_250) begin
        payload_decode_a_code <= payload_complete_code;
        payload_decode_a_none <= {payload_complete_rx[7:0],payload_complete_tx[7:0]};
        payload_decode_a_crc <= {payload_complete_rx[15:8],payload_complete_tx[15:8]};
        payload_decode_a_repeat <= {text_repeat_decode(payload_complete_rx),
                                   text_repeat_decode(payload_complete_tx)};
        payload_decode_a_hamming_data <= {
            payload_complete_rx[11],payload_complete_rx[9:7],
            payload_complete_rx[4],payload_complete_rx[2:0],
            payload_complete_tx[11],payload_complete_tx[9:7],
            payload_complete_tx[4],payload_complete_tx[2:0]};
        payload_decode_a_syndrome <= {
            text_hamming_syndrome(payload_complete_rx[13:7]),
            text_hamming_syndrome(payload_complete_rx[6:0]),
            text_hamming_syndrome(payload_complete_tx[13:7]),
            text_hamming_syndrome(payload_complete_tx[6:0])};
        payload_decode_b_code <= payload_decode_a_code;
        payload_decode_b_none <= payload_decode_a_none;
        payload_decode_b_crc <= payload_decode_a_crc;
        payload_decode_b_repeat <= payload_decode_a_repeat;
        payload_decode_b_hamming <= {
            text_hamming_correct_data(payload_decode_a_hamming_data[15:12],payload_decode_a_syndrome[11:9]),
            text_hamming_correct_data(payload_decode_a_hamming_data[11:8],payload_decode_a_syndrome[8:6]),
            text_hamming_correct_data(payload_decode_a_hamming_data[7:4],payload_decode_a_syndrome[5:3]),
            text_hamming_correct_data(payload_decode_a_hamming_data[3:0],payload_decode_a_syndrome[2:0])};
        if (payload_decode_b_valid) begin
            case (payload_decode_b_code)
                CODE_CRC8: payload_decoded_pair <= payload_decode_b_crc;
                CODE_REPEAT3: payload_decoded_pair <= payload_decode_b_repeat;
                CODE_HAMMING: payload_decoded_pair <= payload_decode_b_hamming;
                default: payload_decoded_pair <= payload_decode_b_none;
            endcase
        end
        payload_error_xor <= payload_decoded_rx ^ payload_decoded_tx;
        payload_error_low <= text_popcount4(payload_error_xor[3:0]);
        payload_error_high <= text_popcount4(payload_error_xor[7:4]);
        payload_decoded_errors <= {1'b0,payload_error_low} + {1'b0,payload_error_high};
    end
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            payload_decode_a_valid <= 0; payload_decode_b_valid <= 0;
            payload_decoded_valid <= 0; payload_error_xor_valid <= 0;
            payload_error_nibbles_valid <= 0; payload_error_valid <= 0;
            payload_rx_bits <= 0; payload_error_bits <= 0;
        end else begin
            if (payload_local_flush) begin
                payload_decode_a_valid <= 0; payload_decode_b_valid <= 0;
                payload_decoded_valid <= 0; payload_error_xor_valid <= 0;
                payload_error_nibbles_valid <= 0; payload_error_valid <= 0;
            end else begin
                payload_decode_a_valid <= payload_complete_valid;
                payload_decode_b_valid <= payload_decode_a_valid;
                payload_decoded_valid <= payload_decode_b_valid;
                payload_error_xor_valid <= payload_decoded_valid;
                payload_error_nibbles_valid <= payload_error_xor_valid;
                payload_error_valid <= payload_error_nibbles_valid;
            end
            if (payload_local_restart) begin
                payload_rx_bits <= 0; payload_error_bits <= 0;
            end else if (!payload_local_flush && payload_error_valid) begin
                payload_rx_bits <= payload_rx_bits + 32'd8;
                payload_error_bits <= payload_error_bits + payload_decoded_errors;
            end
        end
    end

    // Observe the source on the very edge the TX generator loads encoded_frame.
    // These probes do not feed the transmitter, BER, or displayed RX text.
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            text_last_loaded_tx <= 0;
            text_loaded_seen <= 0;
            text_decoded_seen <= 0;
        end else if (tx_restart_pulse_tx || soft_reset_pulse_tx) begin
            text_last_loaded_tx <= 0;
            text_loaded_seen <= 0;
            text_decoded_seen <= 0;
        end else begin
            if (!blink_sw_tx && tx_enable_tx && bit_start_tick && !enc_loaded) begin
                text_last_loaded_tx <= raw_byte;
                text_loaded_seen <= 1;
            end
            if (payload_local_restart) text_decoded_seen <= 0;
            else if (payload_decoded_valid && !payload_event_flush) text_decoded_seen <= 1;
        end
    end
    // ===== DONOR BLOCK B: replace from `reg text_complete_tx` through the
    // capture FSM, stopping BEFORE `reg [2:0] text_complete_sync_ft`.
    // Preserve source probes above this block. Root supplies packed ordering
    // marker and legacy rx_text_mem wire aliases below it.
    // Locally reserved/committed received-byte capture and coherent snapshot.
    reg text_complete_tx;
    reg [2:0] text_v23_request_sync_tx;
    reg text_v23_request_seen_tx;
    reg [1:0] text_v23_capture_state;
    reg text_capture_flush, text_capture_restart, text_capture_rearm_local;
    reg text_capture_eligible;
    (* preserve *) reg text_capture_running;
    reg [4:0] text_slots_reserved;
    (* preserve *) reg text_room_available;
    reg text_store_pending;
    reg [7:0] text_store_byte;
    reg [255:0] text_capture_history;
    wire text_store_commit = text_store_pending;

    // No variable-index/count comparison sits on this final admission path.
    // The running flag anticipates request_sync[2] using its previous stage,
    // so the cutoff stays on the SAME edge as the old direct request compare.
    wire text_accept_decoded = payload_decoded_valid && text_capture_running &&
        text_room_available && !payload_event_flush && !text_capture_flush;
    wire text_snapshot_issue = (text_v23_capture_state == 1) && !text_capture_flush;

    // Independent local enables keep each clock-enable load bounded to one
    //32-bit word. dont_merge is a documented Quartus synthesis attribute,
    // not a timing exemption. Post-fit analysis must verify these copies.
    (* preserve, dont_merge *) reg [7:0] text_history_word_enable;
    (* preserve, dont_merge *) reg [16:0] text_snapshot_word_enable;
    wire text_snapshot_latch = text_snapshot_word_enable[0];
    wire [255:0] text_history_shifted = {text_capture_history[247:0],text_store_byte};

    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            text_v23_request_sync_tx <= 0;
            text_capture_rearm_local <= 0;
            text_capture_flush <= 1; text_capture_restart <= 1;
            text_capture_eligible <= 0; text_capture_running <= 0;
            text_store_pending <= 0;
        end else begin
            text_v23_request_sync_tx <= {text_v23_request_sync_tx[1:0],text_v23_request_toggle_ft};
            text_capture_rearm_local <= text_capture_reset_pulse_tx;
            // Unlike iteration1, capture reset is two clocks after the raw
            // command. This avoids routing the high-fanout raw command through
            // another OR to the capture bank. Decoder flush stays at one clock.
            text_capture_restart <= payload_local_restart;
            text_capture_flush <= payload_local_restart || text_capture_rearm_local;
            text_capture_eligible <= text_rx_supported && (user_text_len != 0) && !smp_mode;
            text_capture_running <= !text_capture_flush && text_capture_eligible &&
                ((text_v23_capture_state == 0) || (text_v23_capture_state == 3)) &&
                (text_v23_request_sync_tx[1] == text_v23_request_seen_tx);
            text_store_pending <= text_accept_decoded;
        end
    end

    // Reserve on acceptance, not on its next-clock memory commit. This keeps
    // capacity exact even for a valid byte every clock: exactly32 reservations.
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            text_slots_reserved <= 0; text_room_available <= 1;
        end else if (text_capture_flush || text_v23_capture_state == 3) begin
            text_slots_reserved <= 0; text_room_available <= 1;
        end else if (text_accept_decoded) begin
            text_slots_reserved <= text_slots_reserved + 5'd1;
            if (text_slots_reserved == 5'd31) text_room_available <= 0;
        end
    end

    genvar text_local_word;
    generate
        for (text_local_word=0; text_local_word<8; text_local_word=text_local_word+1) begin : text_local_history
            always @(posedge clk_250 or negedge reset_n) begin
                if (!reset_n) text_history_word_enable[text_local_word] <= 0;
                else text_history_word_enable[text_local_word] <= text_accept_decoded;
            end
            always @(posedge clk_250) begin
                if (text_history_word_enable[text_local_word])
                    text_capture_history[text_local_word*32+:32] <= text_history_shifted[text_local_word*32+:32];
                if (text_snapshot_word_enable[text_local_word])
                    text_v23_data_tx[text_local_word*32+:32] <= text_capture_history[text_local_word*32+:32];
            end
        end
        for (text_local_word=0; text_local_word<17; text_local_word=text_local_word+1) begin : text_local_snapshot
            always @(posedge clk_250 or negedge reset_n) begin
                if (!reset_n) text_snapshot_word_enable[text_local_word] <= 0;
                else text_snapshot_word_enable[text_local_word] <= text_snapshot_issue;
            end
        end
    endgenerate
    always @(posedge clk_250) begin
        text_store_byte <= payload_decoded_rx;
        // Wide data AND frozen metadata have only word-local strobes, no reset
        // or flush mux. A reset-invalidated snapshot is overwritten before its
        // response toggle can publish; unused data remains explicitly invalid.
        if (text_snapshot_word_enable[8])
            text_v23_status_tx <= {16'h2301,3'd1,selected_rx2_for_mux,
                tx_enable_tx,text_rx_supported,selected_rx_locked,1'b1,2'd0,text_rx_index};
        if (text_snapshot_word_enable[9]) text_v23_token_tx <= text_v23_request_token_ft;
        if (text_snapshot_word_enable[10]) text_v23_epoch_tx <= {run_epoch_tx,mimo_mode_tx};
        if (text_snapshot_word_enable[11]) text_v23_payload_bits_tx <= payload_rx_bits;
        if (text_snapshot_word_enable[12]) text_v23_payload_errors_tx <= payload_error_bits;
        if (text_snapshot_word_enable[13])
            text_diag_bytes_tx <= {text_last_loaded_tx,payload_decoded_tx,payload_decoded_rx,text_last_committed};
        if (text_snapshot_word_enable[14]) text_diag_commits_tx <= text_commit_count;
        if (text_snapshot_word_enable[15]) text_diag_first_tx <= text_capture_history[31:0];
        if (text_snapshot_word_enable[16])
            text_diag_flags_tx <= {28'd0,(text_rx_index != 0),(text_commit_count != 0),text_decoded_seen,text_loaded_seen};
    end

    // Request -> drain -> local word latches -> publish/rearm. Count advances
    // on the exact same edge as ALL eight history words. A local flush may
    // finish an old physical write but invalidates its count, as in iteration1.
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            text_rx_index <= 0; text_rx_shift <= 0; text_rx_count <= 0;
            text_complete_tx <= 0; text_commit_count <= 0; text_last_committed <= 0;
            text_v23_request_seen_tx <= 0; text_v23_capture_state <= 0;
            text_v23_response_toggle_tx <= 0;
        end else if (text_capture_flush) begin
            text_rx_index <= 0; text_complete_tx <= 0;
            if (text_capture_restart) begin
                text_commit_count <= 0; text_last_committed <= 0;
            end
            if (text_v23_capture_state != 0) text_v23_capture_state <= 1;
        end else begin
            if (text_store_commit) begin
                text_rx_index <= text_rx_index + 6'd1;
                text_last_committed <= text_store_byte;
                text_commit_count <= text_commit_count + 32'd1;
                if (text_rx_index == 6'd31) text_complete_tx <= 1;
            end
            case (text_v23_capture_state)
                0: if (text_v23_request_sync_tx[2] != text_v23_request_seen_tx) begin
                    text_v23_request_seen_tx <= text_v23_request_sync_tx[2];
                    text_v23_capture_state <= 1;
                end
                1: text_v23_capture_state <= 2;
                2: text_v23_capture_state <= 3;
                3: begin
                    text_v23_response_toggle_tx <= ~text_v23_response_toggle_tx;
                    text_rx_index <= 0; text_complete_tx <= 0;
                    text_v23_capture_state <= 0;
                end
                default: text_v23_capture_state <= 0;
            endcase
        end
    end

    // Bundled-data crossing: source memory is immutable while complete=1.
    // Three flag stages provide settling time before the FT domain captures
    // the whole block. USB reads use that local frozen block, never live RAM.
    reg [2:0] text_complete_sync_ft;
    genvar text_memory_byte;
    generate for(text_memory_byte=0; text_memory_byte<32; text_memory_byte=text_memory_byte+1) begin : text_legacy_alias
        assign rx_text_mem[text_memory_byte] = text_capture_history[(31-text_memory_byte)*8+:8];
    end endgenerate
    genvar text_bus_word;
    generate for (text_bus_word=0; text_bus_word<32; text_bus_word=text_bus_word+1) begin : text_capture_bus
        assign text_source_bus[text_bus_word*8 +: 8] = rx_text_mem[text_bus_word];
    end endgenerate
    always @(posedge ft_clk or negedge reset_n) begin
        if (!reset_n) begin
            text_complete_sync_ft <= 0;
            text_ready_ft <= 0; text_wait_low_ft <= 0; text_rearm_seen_ft <= 0;
            text_data_ft <= 0;
        end else begin
            text_complete_sync_ft <= {text_complete_sync_ft[1:0], text_complete_tx};
            if (text_rearm_seen_ft != text_capture_reset_toggle_ft) begin
                text_rearm_seen_ft <= text_capture_reset_toggle_ft;
                text_ready_ft <= 0;
                text_wait_low_ft <= 1;
            end else if (!text_complete_sync_ft[2]) begin
                text_ready_ft <= 0;
                text_wait_low_ft <= 0;
            end else if (!text_wait_low_ft && !text_ready_ft) begin
                text_data_ft <= text_source_bus;
                text_ready_ft <= 1;
            end
        end
    end

    // V2.3 request/response CDC: only control toggles are synchronized.
    // Bundled data is held from before acknowledgement through all USB reads.
    // Constrain the physical bundled-data paths; this is not a timing exemption.
    reg [2:0] text_v23_response_sync_ft;
    reg text_v23_response_seen_ft, text_v23_request_seen_ft;
    always @(posedge ft_clk or negedge reset_n) begin
        if (!reset_n) begin
            text_v23_response_sync_ft <= 0; text_v23_response_seen_ft <= 0;
            text_v23_request_seen_ft <= 0; text_v23_ready_ft <= 0;
            text_v23_pending_ft <= 0; text_v23_data_ft <= 0;
            text_v23_status_ft <= 0; text_v23_token_ft <= 0;
            text_v23_epoch_ft <= 0; text_v23_payload_bits_ft <= 0;
            text_v23_payload_errors_ft <= 0;
            text_diag_bytes_ft <= 0; text_diag_commits_ft <= 0;
            text_diag_first_ft <= 0; text_diag_flags_ft <= 0;
        end else begin
            text_v23_response_sync_ft <=
                {text_v23_response_sync_ft[1:0], text_v23_response_toggle_tx};
            if (text_v23_request_seen_ft != text_v23_request_toggle_ft) begin
                text_v23_request_seen_ft <= text_v23_request_toggle_ft;
                text_v23_ready_ft <= 0; text_v23_pending_ft <= 1;
            end else if (text_v23_response_sync_ft[2] != text_v23_response_seen_ft) begin
                text_v23_response_seen_ft <= text_v23_response_sync_ft[2];
                text_v23_data_ft <= text_v23_data_tx;
                text_v23_status_ft <= text_v23_status_tx;
                text_v23_token_ft <= text_v23_token_tx;
                text_v23_epoch_ft <= text_v23_epoch_tx;
                text_v23_payload_bits_ft <= text_v23_payload_bits_tx;
                text_v23_payload_errors_ft <= text_v23_payload_errors_tx;
                text_diag_bytes_ft <= text_diag_bytes_tx;
                text_diag_commits_ft <= text_diag_commits_tx;
                text_diag_first_ft <= text_diag_first_tx;
                text_diag_flags_ft <= text_diag_flags_tx;
                text_v23_ready_ft <= 1; text_v23_pending_ft <= 0;
            end
        end
    end

    // ============================================================
    // V3.1 SMP receive pipeline. Only physical RX bits enter this path.
    // Sample tuple -> frame collector -> syndrome/majority -> correction
    // -> code selection -> per-lane mailbox -> split ID comparisons
    // -> registered pair decision -> local 16-bit capture bank.
    // The minimum frame spacing is 40 core clocks (8 bits at 50 Mbps).
    // Mailbox comparisons take five clocks; version tags reject a decision
    // if a mailbox changed while its comparison was in flight.
    // ============================================================
    reg [1:0] smp_collecting;
    reg [23:0] smp_rx_shift [0:1];
    reg [4:0] smp_bit_count [0:1];
    reg [4:0] smp_frame_len [0:1];
    reg [1:0] smp_frame_code [0:1];
    reg [31:0] smp_frame_id [0:1];
    reg [31:0] smp_frame_floor [0:1];
    reg [1:0] smp_floor_low_lt, smp_floor_high_lt, smp_floor_high_eq;
    reg [1:0] smp_floor_sign, smp_frame_fresh;
    reg [1:0] smp_byte_valid;
    reg [7:0] smp_decoded_byte [0:1];
    reg [31:0] smp_decoded_id [0:1];
    reg [31:0] smp_capture_floor;
    reg [1:0] smp_pending_valid, smp_pending_version;
    reg [7:0] smp_pending_byte [0:1];
    reg [31:0] smp_pending_id [0:1];
    reg [5:0] smp_pair_count;
    reg smp_capture_invalid, smp_pending_timeout;
    wire smp_both_locked = smp_mode && rx_supported && rx2_supported &&
                           rx_locked && rx2_locked;
    wire smp_request_reset = smp_rearm_tx || tx_restart_pulse_tx || soft_reset_pulse_tx;
    wire smp_flush = smp_request_reset || !smp_both_locked || smp_pending_timeout;
    assign smp_status_tx = {21'd0, smp_pair_count, mimo_mode_tx,
        rx2_locked, rx_locked,
        (smp_pair_count == 6'd16 && smp_both_locked && !smp_capture_invalid)};

    // R76..R81 are unsigned saturating 16-bit event counts, zero extended.
    // R39, restart and soft reset clear them. R81 counts subsequent lane-loss
    // episodes, timeouts and ID mismatches (one event per rejected candidate).
    reg [15:0] smp_diag_decoded1, smp_diag_decoded2, smp_diag_pairs;
    reg [15:0] smp_diag_mismatches, smp_diag_timeouts, smp_diag_resets;
    reg smp_locked_previous;
    reg [2:0] smp_pair_state;
    reg smp_mismatch_event, smp_pair_event;
    reg smp_commit_valid, smp_commit_first, smp_commit_gap;
    reg [31:0] smp_commit_id, smp_commit_next_id;
    reg [5:0] smp_commit_count;
    // R82: [0] both locked, [1] invalid, [3:2] collecting,
    // [5:4] decoded valid, [7:6] pending, [10:8] pair FSM,
    // [11] commit, [12] timeout, [13] flush, [19:14] pair count.
    wire [31:0] smp_diag_state = {12'd0, smp_pair_count, smp_flush,
        smp_pending_timeout, smp_commit_valid, smp_pair_state,
        smp_pending_valid, smp_byte_valid, smp_collecting,
        smp_capture_invalid, smp_both_locked};
    assign smp_diag_tx = {smp_diag_state,
        16'd0, smp_diag_resets, 16'd0, smp_diag_timeouts,
        16'd0, smp_diag_mismatches, 16'd0, smp_diag_pairs,
        16'd0, smp_diag_decoded2, 16'd0, smp_diag_decoded1};

    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            run_epoch_tx <= 30'd0;
            smp_request_token_meta_tx <= 32'd0;
            smp_request_token_sync_tx <= 32'd0;
            smp_request_toggle_sync_tx <= 3'd0;
            smp_request_toggle_seen_tx <= 1'b0;
            smp_capture_token_tx <= 32'd0;
        end else begin
            if (tx_restart_pulse_tx || soft_reset_pulse_tx)
                run_epoch_tx <= run_epoch_tx + 30'd1;
            smp_request_token_meta_tx <= smp_request_token_ft;
            smp_request_token_sync_tx <= smp_request_token_meta_tx;
            smp_request_toggle_sync_tx <=
                {smp_request_toggle_sync_tx[1:0], smp_request_toggle_ft};
            if (smp_rearm_tx) begin
                smp_request_toggle_seen_tx <= smp_request_toggle_sync_tx[2];
                smp_capture_token_tx <= smp_request_token_sync_tx;
            end
        end
    end

    reg [1:0] smp_sample_tick, smp_sample_start, smp_sample_bit;
    reg [4:0] smp_sample_len [0:1];
    reg [1:0] smp_sample_code [0:1];
    reg [31:0] smp_sample_id [0:1];
    reg [1:0] smp_complete_valid, smp_decode_a_valid, smp_decode_b_valid;
    reg [23:0] smp_complete_word [0:1];
    reg [1:0] smp_complete_code [0:1], smp_decode_a_code [0:1], smp_decode_b_code [0:1];
    reg [31:0] smp_complete_id [0:1], smp_decode_a_id [0:1], smp_decode_b_id [0:1];
    reg [7:0] smp_decode_a_none [0:1], smp_decode_a_crc [0:1], smp_decode_a_repeat [0:1];
    reg [7:0] smp_decode_a_hamming [0:1];
    reg [5:0] smp_decode_a_syndrome [0:1];
    reg [7:0] smp_decode_b_none [0:1], smp_decode_b_crc [0:1], smp_decode_b_repeat [0:1];
    reg [7:0] smp_decode_b_hamming [0:1];
    integer smp_lane;

    // Register the sample enable and its data/metadata together. No changes
    // are made to the TX reference, sample phases, BER logic or other decoder.
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) smp_sample_tick <= 2'b00;
        else if (smp_flush) smp_sample_tick <= 2'b00;
        else smp_sample_tick <= {rx2_sample_tick, rx_sample_tick};
    end
    always @(posedge clk_250) begin
        smp_sample_start <= {aligned2_frame_start_bit, aligned_frame_start_bit};
        smp_sample_bit <= {rx2_demod_bit, demod_rx_bit};
        smp_sample_len[0] <= aligned_frame_len;
        smp_sample_len[1] <= aligned2_frame_len;
        smp_sample_code[0] <= aligned_frame_code;
        smp_sample_code[1] <= aligned2_frame_code;
        smp_sample_id[0] <= aligned_pair_id;
        smp_sample_id[1] <= aligned2_pair_id;
        for (smp_lane = 0; smp_lane < 2; smp_lane = smp_lane + 1) begin
            // Split modular subtraction sign: MSB XOR minus lower-bit borrow.
            // The result settles three clocks after frame start, well before
            // even the shortest frame completes (35 further sample clocks).
            smp_floor_low_lt[smp_lane] <= smp_frame_id[smp_lane][15:0] < smp_frame_floor[smp_lane][15:0];
            smp_floor_high_lt[smp_lane] <= smp_frame_id[smp_lane][30:16] < smp_frame_floor[smp_lane][30:16];
            smp_floor_high_eq[smp_lane] <= smp_frame_id[smp_lane][30:16] == smp_frame_floor[smp_lane][30:16];
            smp_floor_sign[smp_lane] <= smp_frame_id[smp_lane][31] ^ smp_frame_floor[smp_lane][31];
            smp_frame_fresh[smp_lane] <= !(smp_floor_sign[smp_lane] ^
                (smp_floor_high_lt[smp_lane] || (smp_floor_high_eq[smp_lane] && smp_floor_low_lt[smp_lane])));

            // Independent alternatives remove code select from syndrome logic.
            smp_decode_a_none[smp_lane] <= smp_complete_word[smp_lane][7:0];
            smp_decode_a_crc[smp_lane] <= smp_complete_word[smp_lane][15:8];
            smp_decode_a_repeat[smp_lane] <= text_repeat_decode(smp_complete_word[smp_lane]);
            smp_decode_a_hamming[smp_lane] <= {
                smp_complete_word[smp_lane][11], smp_complete_word[smp_lane][9:7],
                smp_complete_word[smp_lane][4], smp_complete_word[smp_lane][2:0]};
            smp_decode_a_syndrome[smp_lane] <= {
                text_hamming_syndrome(smp_complete_word[smp_lane][13:7]),
                text_hamming_syndrome(smp_complete_word[smp_lane][6:0])};
            smp_decode_a_code[smp_lane] <= smp_complete_code[smp_lane];
            smp_decode_a_id[smp_lane] <= smp_complete_id[smp_lane];
            smp_decode_b_none[smp_lane] <= smp_decode_a_none[smp_lane];
            smp_decode_b_crc[smp_lane] <= smp_decode_a_crc[smp_lane];
            smp_decode_b_repeat[smp_lane] <= smp_decode_a_repeat[smp_lane];
            smp_decode_b_hamming[smp_lane] <= {
                text_hamming_correct_data(smp_decode_a_hamming[smp_lane][7:4], smp_decode_a_syndrome[smp_lane][5:3]),
                text_hamming_correct_data(smp_decode_a_hamming[smp_lane][3:0], smp_decode_a_syndrome[smp_lane][2:0])};
            smp_decode_b_code[smp_lane] <= smp_decode_a_code[smp_lane];
            smp_decode_b_id[smp_lane] <= smp_decode_a_id[smp_lane];
            case (smp_decode_b_code[smp_lane])
                CODE_CRC8: smp_decoded_byte[smp_lane] <= smp_decode_b_crc[smp_lane];
                CODE_REPEAT3: smp_decoded_byte[smp_lane] <= smp_decode_b_repeat[smp_lane];
                CODE_HAMMING: smp_decoded_byte[smp_lane] <= smp_decode_b_hamming[smp_lane];
                default: smp_decoded_byte[smp_lane] <= smp_decode_b_none[smp_lane];
            endcase
            smp_decoded_id[smp_lane] <= smp_decode_b_id[smp_lane];
        end
    end

    integer smp_collect_lane;
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            smp_collecting <= 0;
            smp_complete_valid <= 0;
            smp_decode_a_valid <= 0;
            smp_decode_b_valid <= 0;
            smp_byte_valid <= 0;
            for (smp_collect_lane = 0; smp_collect_lane < 2; smp_collect_lane = smp_collect_lane + 1) begin
                smp_bit_count[smp_collect_lane] <= 0;
            end
        end else if (smp_flush) begin
            smp_collecting <= 0;
            smp_complete_valid <= 0;
            smp_decode_a_valid <= 0;
            smp_decode_b_valid <= 0;
            smp_byte_valid <= 0;
            smp_bit_count[0] <= 0;
            smp_bit_count[1] <= 0;
        end else begin
            smp_complete_valid <= 0;
            smp_decode_a_valid <= smp_complete_valid;
            smp_decode_b_valid <= smp_decode_a_valid;
            smp_byte_valid <= smp_decode_b_valid;
            for (smp_collect_lane = 0; smp_collect_lane < 2; smp_collect_lane = smp_collect_lane + 1) begin
                if (smp_sample_tick[smp_collect_lane]) begin
                    if (smp_sample_start[smp_collect_lane]) begin
                        smp_collecting[smp_collect_lane] <= 1;
                        smp_bit_count[smp_collect_lane] <= 1;
                    end else if (smp_collecting[smp_collect_lane]) begin
                        if (smp_bit_count[smp_collect_lane] == smp_frame_len[smp_collect_lane] - 5'd1) begin
                            smp_complete_valid[smp_collect_lane] <= smp_frame_fresh[smp_collect_lane];
                            smp_collecting[smp_collect_lane] <= 0;
                        end else begin
                            smp_bit_count[smp_collect_lane] <= smp_bit_count[smp_collect_lane] + 5'd1;
                        end
                    end
                end
            end
        end
    end

    reg [31:0] smp_compare_id [0:1];
    reg [31:0] smp_compare_floor, smp_compare_next;
    reg [15:0] smp_compare_bytes;
    reg [1:0] smp_compare_valid, smp_compare_version;
    reg [3:0] smp_equal_parts, smp_contiguous_parts;
    reg smp_order_low_lt, smp_order_high_lt, smp_order_high_eq, smp_order_sign;
    reg smp_ids_equal, smp_ids_contiguous, smp_first_older;
    reg [16:0] smp_wait_low [0:1], smp_wait_high [0:1], smp_wait_high_final [0:1];
    reg [16:0] smp_next_low;
    reg [31:0] smp_next_after_pair;
    reg [15:0] smp_store_data;
    (* preserve, dont_merge *) reg [15:0] smp_bank_write;
    (* preserve, dont_merge *) reg [15:0] smp_bank_clear;
    integer smp_pending_lane, smp_compare_part;

    // Payloads are deliberately reset-free and independent of raw flush.
    // Only validity/FSM/count/readiness decide whether these values can be
    // used. A flush-edge payload write is harmless: validity is cleared on
    // that edge, and a fresh transaction installs data before reasserting it.
    // This removes request/rate-support logic from wide payload enables.
    integer smp_data_lane;
    always @(posedge clk_250) begin
        for (smp_data_lane = 0; smp_data_lane < 2; smp_data_lane = smp_data_lane + 1) begin
            if (smp_sample_tick[smp_data_lane]) begin
                if (smp_sample_start[smp_data_lane]) begin
                    smp_rx_shift[smp_data_lane] <= {23'd0, smp_sample_bit[smp_data_lane]};
                    smp_frame_len[smp_data_lane] <= smp_sample_len[smp_data_lane];
                    smp_frame_code[smp_data_lane] <= smp_sample_code[smp_data_lane];
                    smp_frame_id[smp_data_lane] <= smp_sample_id[smp_data_lane];
                    smp_frame_floor[smp_data_lane] <= smp_capture_floor;
                end else if (smp_collecting[smp_data_lane]) begin
                    if (smp_bit_count[smp_data_lane] == smp_frame_len[smp_data_lane] - 5'd1) begin
                        smp_complete_word[smp_data_lane] <= {smp_rx_shift[smp_data_lane][22:0], smp_sample_bit[smp_data_lane]};
                        smp_complete_code[smp_data_lane] <= smp_frame_code[smp_data_lane];
                        smp_complete_id[smp_data_lane] <= smp_frame_id[smp_data_lane];
                    end else begin
                        smp_rx_shift[smp_data_lane] <= {smp_rx_shift[smp_data_lane][22:0], smp_sample_bit[smp_data_lane]};
                    end
                end
            end
            if (smp_byte_valid[smp_data_lane]) begin
                smp_pending_byte[smp_data_lane] <= smp_decoded_byte[smp_data_lane];
                smp_pending_id[smp_data_lane] <= smp_decoded_id[smp_data_lane];
            end
        end

        // The FSM leaves state zero only after pending data is available.
        // Capturing empty slots while idle has no architectural effect.
        if (smp_pair_state == 0) begin
            smp_compare_valid <= smp_pending_valid;
            smp_compare_version <= smp_pending_version;
            smp_compare_id[0] <= smp_pending_id[0];
            smp_compare_id[1] <= smp_pending_id[1];
            smp_compare_bytes <= {smp_pending_byte[1], smp_pending_byte[0]};
            smp_compare_floor <= smp_capture_floor;
            smp_compare_next <= next_pair_id;
        end
        // These two arithmetic stages keep their original latency but no
        // longer inherit the controller's flush-qualified clock enable.
        for (smp_compare_part = 0; smp_compare_part < 4; smp_compare_part = smp_compare_part + 1) begin
            smp_equal_parts[smp_compare_part] <= smp_compare_id[0][smp_compare_part*8 +: 8] == smp_compare_id[1][smp_compare_part*8 +: 8];
            smp_contiguous_parts[smp_compare_part] <= smp_compare_id[0][smp_compare_part*8 +: 8] == smp_compare_floor[smp_compare_part*8 +: 8];
        end
        smp_order_low_lt <= smp_compare_id[0][15:0] < smp_compare_id[1][15:0];
        smp_order_high_lt <= smp_compare_id[0][30:16] < smp_compare_id[1][30:16];
        smp_order_high_eq <= smp_compare_id[0][30:16] == smp_compare_id[1][30:16];
        smp_order_sign <= smp_compare_id[0][31] ^ smp_compare_id[1][31];
        smp_next_low <= {1'b0, smp_compare_id[0][15:0]} + 17'd1;
        for (smp_data_lane = 0; smp_data_lane < 2; smp_data_lane = smp_data_lane + 1) begin
            smp_wait_low[smp_data_lane] <= {1'b0, smp_compare_next[15:0]} - {1'b0, smp_compare_id[smp_data_lane][15:0]};
            smp_wait_high[smp_data_lane] <= {1'b0, smp_compare_next[31:16]} - {1'b0, smp_compare_id[smp_data_lane][31:16]};
            smp_wait_high_final[smp_data_lane] <= smp_wait_high[smp_data_lane] - smp_wait_low[smp_data_lane][16];
        end
        smp_ids_equal <= &smp_equal_parts;
        smp_ids_contiguous <= &smp_contiguous_parts;
        smp_first_older <= smp_order_sign ^ (smp_order_high_lt || (smp_order_high_eq && smp_order_low_lt));
        smp_next_after_pair <= {smp_compare_id[0][31:16] + smp_next_low[16], smp_next_low[15:0]};
        smp_commit_id <= smp_compare_id[0];
        smp_commit_next_id <= smp_next_after_pair;
        smp_commit_first <= (smp_pair_count == 0) || !smp_ids_contiguous;
        smp_commit_gap <= !smp_ids_contiguous;
        smp_commit_count <= (smp_pair_count == 0 || !smp_ids_contiguous) ? 6'd1 : smp_pair_count + 6'd1;
        smp_store_data <= smp_compare_bytes;
    end

    // Wide data has local, registered bank enables. Count and data commit
    // on the same edge, so ready can never precede the final two RX bytes.
    genvar smp_bank;
    generate for (smp_bank = 0; smp_bank < 16; smp_bank = smp_bank + 1) begin : smp_capture_banks
        always @(posedge clk_250 or negedge reset_n) begin
            if (!reset_n) smp_bank_clear[smp_bank] <= 1'b1;
            else smp_bank_clear[smp_bank] <= smp_request_reset;
        end
        always @(posedge clk_250) begin
            if (smp_bank_clear[smp_bank])
                smp_capture_data[smp_bank*16 +: 16] <= 16'd0;
            // A concurrent flush cancels count/readiness in the controller;
            // the following local clear removes data on a fresh request.
            // Partial bytes are never published as a complete capture.
            else if (smp_bank_write[smp_bank])
                smp_capture_data[smp_bank*16 +: 16] <= smp_store_data;
        end
    end endgenerate

    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            smp_pending_valid <= 0;
            smp_pending_version <= 0;
            smp_pair_state <= 0;
            smp_pending_timeout <= 0;
            smp_commit_valid <= 0;
            smp_bank_write <= 0;
            smp_mismatch_event <= 0;
            smp_pair_event <= 0;
            smp_pair_count <= 0;
            smp_first_pair_id <= 0;
            smp_last_pair_id <= 0;
            smp_capture_floor <= 0;
            smp_capture_invalid <= 0;
        end else begin
            smp_pending_timeout <= 0;
            smp_commit_valid <= 0;
            smp_bank_write <= 0;
            smp_mismatch_event <= 0;
            smp_pair_event <= 0;
            if (smp_flush) begin
                smp_pending_valid <= 0;
                smp_pair_state <= 0;
                smp_capture_floor <= (tx_restart_pulse_tx || soft_reset_pulse_tx) ? 0 : next_pair_id;
                if (smp_request_reset) begin
                    smp_pair_count <= 0;
                    smp_first_pair_id <= 0;
                    smp_last_pair_id <= 0;
                    smp_capture_invalid <= 0;
                end else if (smp_pair_count == 16) begin
                    smp_capture_invalid <= 1;
                end else begin
                    smp_pair_count <= 0;
                    smp_first_pair_id <= 0;
                end
            end else begin
                for (smp_pending_lane = 0; smp_pending_lane < 2; smp_pending_lane = smp_pending_lane + 1) begin
                    if (smp_byte_valid[smp_pending_lane]) begin
                        smp_pending_valid[smp_pending_lane] <= 1;
                        smp_pending_version[smp_pending_lane] <= ~smp_pending_version[smp_pending_lane];
                    end
                end
                if (smp_commit_valid) begin
                    smp_last_pair_id <= smp_commit_id;
                    smp_capture_floor <= smp_commit_next_id;
                    smp_pair_event <= 1;
                    if (smp_pair_count < 16) begin
                        smp_pair_count <= smp_commit_count;
                        if (smp_commit_first) smp_first_pair_id <= smp_commit_id;
                    end else if (smp_commit_gap) smp_capture_invalid <= 1;
                end
                case (smp_pair_state)
                    0: if (|smp_pending_valid) begin
                        smp_pair_state <= 1;
                    end
                    1: begin
                        smp_pair_state <= 2;
                    end
                    2: begin
                        smp_pair_state <= 3;
                    end
                    3: begin
                        // A new byte on this very edge also cancels the old
                        // decision; it must not be overwritten by a slot clear.
                        if ((smp_compare_version == smp_pending_version) && !(|smp_byte_valid)) begin
                            if (&smp_compare_valid) begin
                                if (smp_ids_equal) begin
                                    smp_pending_valid <= 0;
                                    smp_commit_valid <= 1;
                                    if (smp_pair_count < 16)
                                        smp_bank_write <= 16'b1 << ((smp_pair_count == 0 || !smp_ids_contiguous) ? 4'd0 : smp_pair_count[3:0]);
                                end else begin
                                    smp_pending_valid <= smp_first_older ? 2'b10 : 2'b01;
                                    smp_mismatch_event <= 1;
                                    if (smp_pair_count == 16) smp_capture_invalid <= 1;
                                    else smp_pair_count <= 0;
                                end
                            end else if ((smp_compare_valid == 2'b01 && smp_pending_valid == 2'b01 &&
                                !smp_wait_high_final[0][15] && ((|smp_wait_high_final[0][15:0]) || smp_wait_low[0][15:0] > 16'd2)) ||
                                (smp_compare_valid == 2'b10 && smp_pending_valid == 2'b10 &&
                                !smp_wait_high_final[1][15] && ((|smp_wait_high_final[1][15:0]) || smp_wait_low[1][15:0] > 16'd2))) begin
                                smp_pending_timeout <= 1;
                            end
                        end
                        smp_pair_state <= 4;
                    end
                    default: smp_pair_state <= 0;
                endcase
            end
        end
    end

    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            smp_diag_decoded1 <= 0; smp_diag_decoded2 <= 0; smp_diag_pairs <= 0;
            smp_diag_mismatches <= 0; smp_diag_timeouts <= 0; smp_diag_resets <= 0;
            smp_locked_previous <= 0;
        end else begin
            smp_locked_previous <= smp_both_locked;
            if (smp_request_reset) begin
                smp_diag_decoded1 <= 0; smp_diag_decoded2 <= 0; smp_diag_pairs <= 0;
                smp_diag_mismatches <= 0; smp_diag_timeouts <= 0; smp_diag_resets <= 0;
            end else begin
                if (smp_byte_valid[0] && !smp_flush && !(&smp_diag_decoded1)) smp_diag_decoded1 <= smp_diag_decoded1 + 16'd1;
                if (smp_byte_valid[1] && !smp_flush && !(&smp_diag_decoded2)) smp_diag_decoded2 <= smp_diag_decoded2 + 16'd1;
                if (smp_pair_event && !(&smp_diag_pairs)) smp_diag_pairs <= smp_diag_pairs + 16'd1;
                if (smp_mismatch_event && !(&smp_diag_mismatches)) smp_diag_mismatches <= smp_diag_mismatches + 16'd1;
                if (smp_pending_timeout && !(&smp_diag_timeouts)) smp_diag_timeouts <= smp_diag_timeouts + 16'd1;
                if (((smp_locked_previous && !smp_both_locked) || smp_pending_timeout || smp_mismatch_event) && !(&smp_diag_resets))
                    smp_diag_resets <= smp_diag_resets + 16'd1;
            end
        end
    end

    // ============================================================
    // V3.3.2 passive delivery instrumentation. NO signal in this section feeds
    // the optical serializer, tuning, lock, selector or text-capture logic.
    // The selected decoder and accepted SMP commit are the only output taps.
    // R39/R53 never reset these counters: their actual capture-induced gaps
    // remain measurable. A Start/reset creates a new run_epoch and clears them.
    // Aligned source IDs are local testbed metadata, not over-air packet IDs.
    // Thus this is internal decoded optical delivery, not USB application rate.
    wire delivery_restart = tx_restart_pulse_tx || soft_reset_pulse_tx;
    wire delivery_enabled = tx_enable_tx && !blink_sw_tx;
    reg delivery_manual_invalid;
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) delivery_manual_invalid <= 0;
        else if (delivery_restart) delivery_manual_invalid <= 0;
        else if (blink_sw_tx) delivery_manual_invalid <= 1;
    end
    // Manual board-test mode resets source IDs without a run_epoch change.
    // Fail closed until an actual Start/reset rather than recycling cohorts.
    wire delivery_supported = rx_supported && (!smp_mode || rx2_supported) && !delivery_manual_invalid;
    wire delivery_source_valid = delivery_enabled && bit_start_tick && !enc_loaded;
    wire delivery_rx1_tick = rx_supported && rx_sample_tick &&
        (rx_locked || ((demod_rx_bit == rx_expected_level) && rx_match_count == 15));
    wire delivery_rx2_tick = rx2_supported && rx2_sample_tick &&
        (rx2_locked || ((rx2_demod_bit == aligned2_data_bit) && rx2_match_count == 15));

    // Sideband follows exactly the existing selected sample/collector/decode
    // latency. It never qualifies or changes the existing byte-valid signal.
    reg [31:0] delivery_id_d [0:1];
    reg [31:0] delivery_event_id, delivery_local_id, delivery_frame_id;
    reg [31:0] delivery_complete_id, delivery_decode_a_id, delivery_decode_b_id;
    reg [31:0] delivery_decoded_id;
    always @(posedge clk_250) begin
        delivery_id_d[0] <= aligned_pair_id;
        delivery_id_d[1] <= aligned2_pair_id;
        delivery_event_id <= delivery_id_d[text_select_d];
        delivery_local_id <= delivery_event_id;
        if (payload_local_tick && payload_local_start)
            delivery_frame_id <= delivery_local_id;
        delivery_complete_id <= delivery_frame_id;
        delivery_decode_a_id <= delivery_complete_id;
        delivery_decode_b_id <= delivery_decode_a_id;
        if (payload_decode_b_valid) delivery_decoded_id <= delivery_decode_b_id;
    end

    wire delivery_output_valid = smp_mode ? (smp_commit_valid && !smp_flush) :
        (payload_decoded_valid && !payload_event_flush);
    wire [31:0] delivery_output_id = smp_mode ? smp_commit_id : delivery_decoded_id;
    wire [15:0] delivery_output_bytes = smp_mode ? smp_store_data : {8'd0,payload_decoded_rx};
    wire [63:0] delivery_ticks, delivery_expected, delivery_complete, delivery_good;
    wire [63:0] delivery_compared, delivery_errors, delivery_rx1, delivery_rx2;
    wire [63:0] delivery_retired_ticks;
    wire delivery_warm;
    FsoDeliveryMonitor delivery_monitor (
        .clk(clk_250), .reset_n(reset_n), .restart(delivery_restart || blink_sw_tx),
        .enabled(delivery_enabled), .supported(delivery_supported), .smp(smp_mode),
        .source_valid(delivery_source_valid), .source_id(next_pair_id),
        .source_bytes({raw_byte2,raw_byte}), .output_valid(delivery_output_valid),
        .output_id(delivery_output_id), .output_bytes(delivery_output_bytes),
        .rx1_tick(delivery_rx1_tick), .rx2_tick(delivery_rx2_tick),
        .ticks(delivery_ticks), .expected_blocks(delivery_expected),
        .complete_blocks(delivery_complete), .good_blocks(delivery_good),
        .compared_bits(delivery_compared), .error_bits(delivery_errors),
        .rx1_bits(delivery_rx1), .rx2_bits(delivery_rx2),
        .retired_ticks(delivery_retired_ticks), .warm(delivery_warm)
    );

    // Bundled-data CDC: one request at a time; TX freezes the entire 640-bit
    // bank then toggles ACK. Three ACK synchronizer stages provide settling
    // before FT copies the bank. TX bank stays fixed until the next request.
    reg [2:0] delivery_request_sync_tx, delivery_response_sync_ft;
    reg delivery_request_seen_tx, delivery_response_toggle_tx, delivery_response_seen_ft;
    reg [31:0] delivery_token_meta_tx, delivery_token_sync_tx, delivery_token_tx;
    // Passive status copy at the same four-cycle cutoff as committed counters
    // (one observer event stage plus three counter carry/alignment stages).
    // In particular, do not feed the live combinational optical selector into
    // the 640-bit held-bank capture enable/data cone. The real selector is unchanged.
    reg [36:0] delivery_metadata_pipe [0:3];
    wire [36:0] delivery_metadata_q = delivery_metadata_pipe[3];
    integer delivery_meta_stage;
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            for(delivery_meta_stage=0;delivery_meta_stage<4;delivery_meta_stage=delivery_meta_stage+1)
                delivery_metadata_pipe[delivery_meta_stage] <= 0;
        end else begin
            delivery_metadata_pipe[0] <= {selected_rx2_for_mux,rx2_locked,rx_locked,
                delivery_supported,delivery_enabled,run_epoch_tx,mimo_mode_tx};
            for(delivery_meta_stage=1;delivery_meta_stage<4;delivery_meta_stage=delivery_meta_stage+1)
                delivery_metadata_pipe[delivery_meta_stage] <= delivery_metadata_pipe[delivery_meta_stage-1];
        end
    end
    wire delivery_request_ft = usb_state == USB_RD_LOW && !ft_rxf_n &&
        ft_data[7:0] == "R" && ft_data[31:24] == 8'd91;
    always @(posedge clk_250 or negedge reset_n) begin
        if (!reset_n) begin
            delivery_request_sync_tx <= 0; delivery_request_seen_tx <= 0;
            delivery_response_toggle_tx <= 0; delivery_token_meta_tx <= 0;
            delivery_token_sync_tx <= 0; delivery_token_tx <= 0;
            delivery_bank_tx <= 0;
        end else begin
            delivery_request_sync_tx <= {delivery_request_sync_tx[1:0],delivery_request_toggle_ft};
            delivery_token_meta_tx <= delivery_request_token_ft;
            delivery_token_sync_tx <= delivery_token_meta_tx;
            if (delivery_request_sync_tx[2] != delivery_request_seen_tx) begin
                delivery_request_seen_tx <= delivery_request_sync_tx[2];
                delivery_token_tx <= delivery_token_sync_tx;
                delivery_bank_tx <= {delivery_retired_ticks,delivery_rx2,delivery_rx1,
                    delivery_errors,delivery_compared,delivery_good,delivery_complete,
                    delivery_expected,delivery_ticks,
                    26'd0,delivery_warm,delivery_metadata_q};
                delivery_response_toggle_tx <= ~delivery_response_toggle_tx;
            end
        end
    end
    always @(posedge ft_clk or negedge reset_n) begin
        if (!reset_n) begin
            delivery_request_token_ft <= 0; delivery_completed_token_ft <= 0;
            delivery_request_toggle_ft <= 0; delivery_pending_ft <= 0;
            delivery_response_sync_ft <= 0; delivery_response_seen_ft <= 0;
            delivery_bank_ft <= 0;
        end else begin
            delivery_response_sync_ft <= {delivery_response_sync_ft[1:0],delivery_response_toggle_tx};
            if (delivery_request_ft && !delivery_pending_ft) begin
                delivery_request_token_ft <= delivery_request_token_ft + 32'd1;
                delivery_request_toggle_ft <= ~delivery_request_toggle_ft;
                delivery_pending_ft <= 1;
            end
            if (delivery_response_sync_ft[2] != delivery_response_seen_ft) begin
                delivery_response_seen_ft <= delivery_response_sync_ft[2];
                delivery_bank_ft <= delivery_bank_tx;
                delivery_completed_token_ft <= delivery_token_tx;
                delivery_pending_ft <= 0;
            end
        end
    end

    // Display logic
    //
    // blink_sw_tx = 1:
    //      HEX0 HEX1 HEX2 HEX4 = 8888
    //      led[7:0] blink every 1 second
    //
    // blink_sw_tx = 0:
    //      normal USB status display
    //
    // After X or Z:
    //      display returns to 0000
    //      laser_ep = 0
    //
    // During supported RX mode:
    //      led[6] = rx_locked
    //      led[7] = tx_enable
    // ============================================================
    always @(*) begin

        if (blink_sw_tx) begin
            HEX0 = 7'b0000000; // 8
            HEX1 = 7'b0000000; // 8
            HEX2 = 7'b0000000; // 8
            HEX4 = 7'b0000000; // 8

            led  = {8{blink_state}};
        end else begin

            // HEX0: control mode
            if (!got_command_ft) begin
                HEX0 = 7'b1000000; // 0
            end else if (!tx_enable_ft) begin
                HEX0 = 7'b1000000; // 0 = stopped
            end else begin
                HEX0 = 7'b1000001; // U = USB control
            end

            // HEX1: data type
            if (!tx_enable_ft) begin
                HEX1 = 7'b1000000; // 0
            end else begin
                case (cmd_data_ft)
                    "A": HEX1 = 7'b1111001; // 1 = PRBS7
                    "B": HEX1 = 7'b0100100; // 2 = PRBS15
                    "C": HEX1 = 7'b0110000; // 3 = ASCII S
                    "D": HEX1 = 7'b0011001; // 4 = Counter
                    "U": HEX1 = 7'b0010010; // 5 = User Text placeholder
                    default: HEX1 = 7'b1000000; // 0
                endcase
            end

            // HEX2: coding
            if (!tx_enable_ft) begin
                HEX2 = 7'b1000000; // 0
            end else begin
                case (cmd_code_ft)
                    "E": HEX2 = 7'b1111001; // 1 = None
                    "F": HEX2 = 7'b0100100; // 2 = CRC-8
                    "Q": HEX2 = 7'b0110000; // 3 = Repeat-3
                    "R": HEX2 = 7'b0011001; // 4 = Hamming
                    default: HEX2 = 7'b1000000; // 0
                endcase
            end

            // HEX4: modulation
            if (!tx_enable_ft) begin
                HEX4 = 7'b1000000; // 0
            end else begin
                case (cmd_mod_ft)
                    "G": HEX4 = 7'b1111001; // 1 = OOK-NRZ
                    "H": HEX4 = 7'b0100100; // 2 = OOK-RZ
                    "I": HEX4 = 7'b0110000; // 3 = PWM
                    "J": HEX4 = 7'b0011001; // 4 = PPM
                    default: HEX4 = 7'b1000000; // 0
                endcase
            end

            // LED speed display
            // led[5:0] = speed bar
            // led[6]   = rx_locked during supported RX mode, otherwise command received
            // led[7]   = TX enabled
            if (!tx_enable_ft) begin
                led = {tx_enable_ft, got_command_ft, 6'b000000};
            end else begin
                case (cmd_speed_ft)
                    "K": led = {tx_enable_ft, (rx_supported ? rx_locked : got_command_ft), 6'b000001}; // 1 Mbps
                    "L": led = {tx_enable_ft, (rx_supported ? rx_locked : got_command_ft), 6'b000011}; // 2 Mbps
                    "M": led = {tx_enable_ft, (rx_supported ? rx_locked : got_command_ft), 6'b000111}; // 5 Mbps
                    "N": led = {tx_enable_ft, (rx_supported ? rx_locked : got_command_ft), 6'b001111}; // 10 Mbps
                    "O": led = {tx_enable_ft, (rx_supported ? rx_locked : got_command_ft), 6'b011111}; // 25 Mbps
                    "P": led = {tx_enable_ft, (rx_supported ? rx_locked : got_command_ft), 6'b111111}; // 50 Mbps
                    default: led = {tx_enable_ft, got_command_ft, 6'b000000};
                endcase
            end
        end
    end

endmodule

// Isolated donor. Integration must retain the original live/previous window
// counters, lock-priority overrides and frame-boundary switching logic.
// This module compares e2*b1 against e1*b2 exactly, without division.
module ExactDivCompare16 (
    input  wire        clk,
    input  wire        reset_n,
    input  wire        cancel,
    input  wire        start,
    input  wire [31:0] bits1,
    input  wire [31:0] errors1,
    input  wire [31:0] bits2,
    input  wire [31:0] errors2,
    output wire        result_valid,
    output reg         rx2_better,
    output reg         rx1_better
);
    reg [7:0] valid_pipe;
    reg [31:0] a1, b1, a2, b2;
    reg [31:0] p100, p101, p110, p111;
    reg [31:0] p200, p201, p210, p211;
    reg [16:0] c11a, c12a, c21a, c22a;
    reg [15:0] l10s2, l11extra, l12extra, l13s2;
    reg [15:0] l20s2, l21extra, l22extra, l23s2;
    reg [17:0] c11s3, c12base, c21s3, c22base;
    reg [15:0] l10s3, l13s3, l20s3, l23s3;
    reg [17:0] c12s4, c22s4;
    reg [15:0] l10s4, l11s4, l13s4;
    reg [15:0] l20s4, l21s4, l23s4;
    reg [63:0] product1, product2;
    reg [3:0] limb_lt, limb_eq;

    wire rx2_less = limb_lt[3] ||
        (limb_eq[3] && limb_lt[2]) ||
        (limb_eq[3] && limb_eq[2] && limb_lt[1]) ||
        (limb_eq[3] && limb_eq[2] && limb_eq[1] && limb_lt[0]);

    assign result_valid = valid_pipe[7];

    // Invalid data registers need no reset. Only validity reaches consumers.
    // Cancellation flushes every outstanding window result in one edge.
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n)
            valid_pipe <= 8'd0;
        else if (cancel)
            valid_pipe <= 8'd0;
        else
            valid_pipe <= {valid_pipe[6:0], start};
    end

    always @(posedge clk) begin
        // Stage 0: these are the pre-edge window values, not the counters
        // after their simultaneous boundary-edge reset/increment.
        a1 <= errors1;
        b1 <= bits2;
        a2 <= errors2;
        b2 <= bits1;

        // Stage 1: unsigned 16x16 products with a full 32-bit destination.
        p100 <= a1[15:0]  * b1[15:0];
        p101 <= a1[15:0]  * b1[31:16];
        p110 <= a1[31:16] * b1[15:0];
        p111 <= a1[31:16] * b1[31:16];
        p200 <= a2[15:0]  * b2[15:0];
        p201 <= a2[15:0]  * b2[31:16];
        p210 <= a2[31:16] * b2[15:0];
        p211 <= a2[31:16] * b2[31:16];

        // Stage 2: pairwise sums for radix-65536 columns 1 and 2.
        c11a <= {1'b0, p100[31:16]} + {1'b0, p101[15:0]};
        c12a <= {1'b0, p101[31:16]} + {1'b0, p110[31:16]};
        l10s2 <= p100[15:0];
        l11extra <= p110[15:0];
        l12extra <= p111[15:0];
        l13s2 <= p111[31:16];
        c21a <= {1'b0, p200[31:16]} + {1'b0, p201[15:0]};
        c22a <= {1'b0, p201[31:16]} + {1'b0, p210[31:16]};
        l20s2 <= p200[15:0];
        l21extra <= p210[15:0];
        l22extra <= p211[15:0];
        l23s2 <= p211[31:16];

        // Stage 3: add each remaining column operand; carry is at most 2.
        c11s3 <= {1'b0, c11a} + {2'b0, l11extra};
        c12base <= {1'b0, c12a} + {2'b0, l12extra};
        l10s3 <= l10s2;
        l13s3 <= l13s2;
        c21s3 <= {1'b0, c21a} + {2'b0, l21extra};
        c22base <= {1'b0, c22a} + {2'b0, l22extra};
        l20s3 <= l20s2;
        l23s3 <= l23s2;

        // Stage 4: carry from column 1 to column 2 is registered separately.
        c12s4 <= c12base + {16'b0, c11s3[17:16]};
        l10s4 <= l10s3;
        l11s4 <= c11s3[15:0];
        l13s4 <= l13s3;
        c22s4 <= c22base + {16'b0, c21s3[17:16]};
        l20s4 <= l20s3;
        l21s4 <= c21s3[15:0];
        l23s4 <= l23s3;

        // Stage 5: no 64-bit carry chain. A 32x32 product fits exactly in
        // 64 bits, including the final 16-bit high limb and its carry.
        product1[63:48] <= l13s4 + {14'b0, c12s4[17:16]};
        product1[47:0] <= {c12s4[15:0], l11s4, l10s4};
        product2[63:48] <= l23s4 + {14'b0, c22s4[17:16]};
        product2[47:0] <= {c22s4[15:0], l21s4, l20s4};

        // Stage 6: independent 16-bit comparisons (most significant first).
        limb_lt[3] <= product2[63:48] < product1[63:48];
        limb_lt[2] <= product2[47:32] < product1[47:32];
        limb_lt[1] <= product2[31:16] < product1[31:16];
        limb_lt[0] <= product2[15:0] < product1[15:0];
        limb_eq[3] <= product2[63:48] == product1[63:48];
        limb_eq[2] <= product2[47:32] == product1[47:32];
        limb_eq[1] <= product2[31:16] == product1[31:16];
        limb_eq[0] <= product2[15:0] == product1[15:0];

        // Stage 7: exact equality means neither branch is better.
        rx2_better <= rx2_less;
        rx1_better <= !rx2_less && !(&limb_eq);
    end
endmodule

// Passive 32-byte delivery scoreboard. The source reference is the exact
// encoder-input byte, not an estimate from the configured rate or GUI text.
// Output events originate only from the existing selected decoder / accepted
// SMP pair commit. Source IDs are shared-FPGA alignment metadata. No credit is
// given to duplicates, missing IDs, late data, or complete but misordered blocks.
//
// A block retires at the START of source block n+2: one full following block
// is its decoder grace interval. All totals (including partial-block BER bits)
// retire together. Deadlines and expected blocks progress during optical loss.
// R39 text rearm has no connection to restart; actual resulting gaps count.
module FsoDeliveryMonitor (
    input wire clk, reset_n, restart, enabled, supported, smp,
    input wire source_valid,
    input wire [31:0] source_id,
    input wire [15:0] source_bytes,
    input wire output_valid,
    input wire [31:0] output_id,
    input wire [15:0] output_bytes,
    input wire rx1_tick, rx2_tick,
    output reg [63:0] ticks,
    output wire [63:0] expected_blocks, complete_blocks, good_blocks,
    output wire [63:0] compared_bits, error_bits, rx1_bits, rx2_bits,
    output reg [63:0] retired_ticks,
    output wire warm
);
    // Store identity and data as one synchronous RAM record. In V3.3 the
    // asynchronous 128-way ID lookup and equality test shared one clock path.
    // Read the tuple first; validate its full ID in the existing next stage.
    (* ramstyle = "M10K" *) reg [47:0] reference_record [0:127];
    reg [127:0] reference_valid;
    reg [31:0] cohort_tag [0:7];
    reg [31:0] cohort_mask [0:7];
    reg [8:0] cohort_errors [0:7];
    reg [5:0] cohort_bytes [0:7];
    reg [7:0] cohort_valid, cohort_order_bad;
    reg [1:0] started_blocks;
    assign warm = (expected_blocks != 0);
    wire source_boundary = source_valid && (smp ? source_id[3:0] == 0 : source_id[4:0] == 0);
    wire [31:0] source_block = smp ? {4'd0,source_id[31:4]} : {5'd0,source_id[31:5]};
    wire [2:0] source_slot = source_block[2:0];
    wire [2:0] retire_slot = source_slot - 3'd2;
    wire retirement = enabled && supported && source_boundary && started_blocks == 2;

    // Register the reference memory read; invalid data never enters counters.
    reg compare_valid, compare_smp;
    reg [31:0] compare_id;
    reg [15:0] compare_actual;
    reg [47:0] compare_reference;
    wire [15:0] compare_expected = compare_reference[15:0];
    reg event_valid, event_smp;
    reg [31:0] event_id;
    reg [4:0] event_errors;
    reg [31:0] event_block, event_mask;
    reg [2:0] event_slot;
    reg [4:0] event_offset;
    reg [5:0] event_byte_count;
    function [3:0] pop8;
        input [7:0] value;
        reg [1:0] a,b,c,d;
        reg [2:0] ab,cd;
        begin
            // Balanced tree, not a serial chain of eight accumulator adds.
            a={1'b0,value[0]}+{1'b0,value[1]};
            b={1'b0,value[2]}+{1'b0,value[3]};
            c={1'b0,value[4]}+{1'b0,value[5]};
            d={1'b0,value[6]}+{1'b0,value[7]};
            ab={1'b0,a}+{1'b0,b}; cd={1'b0,c}+{1'b0,d};
            pop8={1'b0,ab}+{1'b0,cd};
        end
    endfunction

    // Decode mask/tag in the EXISTING event stage, before the bank update.
    // Each bank has a local comparison; no central 8:1 state mux feeds back
    // through one shared, high-fanout accept enable to every bank register.
    wire [7:0] accept_bank;
    genvar bank;
    generate for(bank=0;bank<8;bank=bank+1) begin : gen_accept
        assign accept_bank[bank] = event_valid && event_slot == bank &&
            cohort_valid[bank] && cohort_tag[bank] == event_block &&
            (cohort_mask[bank] & event_mask) == 0 &&
            !(retirement && retire_slot == bank);
    end endgenerate

    // V3.3.2: four short registered 16-bit carry stages. An attempted single-edge
    // byte carry-lookahead counter failed fitted timing and is NOT used here.
    // All exported limbs are aligned to the same three-cycle-old event prefix.
    // Count enables and retirement records are registered first, isolating
    // the long sample/compare paths from the wide counter enables. Exported
    // wall ticks have that SAME extra edge after the same counter pipeline,
    // so RX counts, cohort totals and wall time share a four-cycle cutoff.
    wire retire_complete = retirement && (&cohort_mask[retire_slot]) &&
        !cohort_order_bad[retire_slot];
    wire retire_good = retire_complete && cohort_errors[retire_slot] == 0;
    wire [63:0] running_ticks;
    (* preserve, dont_merge *) reg rx1_event_q, rx2_event_q;
    reg retire_valid_q, retire_complete_q, retire_good_q;
    reg [8:0] retire_compared_q, retire_errors_q;
    reg [2:0] retire_commit_pipe;
    FsoDeliveryCounter64 timer_count(clk,reset_n,restart,enabled,9'd1,running_ticks);
    FsoDeliveryCounter64 rx1_count(clk,reset_n,restart,rx1_event_q,9'd1,rx1_bits);
    FsoDeliveryCounter64 rx2_count(clk,reset_n,restart,rx2_event_q,9'd1,rx2_bits);
    FsoDeliveryCounter64 expected_count(clk,reset_n,restart,retire_valid_q,9'd1,expected_blocks);
    FsoDeliveryCounter64 complete_count(clk,reset_n,restart,retire_valid_q && retire_complete_q,9'd1,complete_blocks);
    FsoDeliveryCounter64 good_count(clk,reset_n,restart,retire_valid_q && retire_good_q,9'd1,good_blocks);
    FsoDeliveryCounter64 compared_count(clk,reset_n,restart,retire_valid_q,
        retire_compared_q,compared_bits);
    FsoDeliveryCounter64 error_count(clk,reset_n,restart,retire_valid_q,
        retire_errors_q,error_bits);

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rx1_event_q<=0; rx2_event_q<=0; ticks<=0; retired_ticks<=0;
            retire_valid_q<=0; retire_complete_q<=0; retire_good_q<=0;
            retire_compared_q<=0; retire_errors_q<=0; retire_commit_pipe<=0;
        end else if (restart) begin
            rx1_event_q<=0; rx2_event_q<=0; ticks<=0; retired_ticks<=0;
            retire_valid_q<=0; retire_complete_q<=0; retire_good_q<=0;
            retire_compared_q<=0; retire_errors_q<=0; retire_commit_pipe<=0;
        end else begin
            ticks<=running_ticks;
            rx1_event_q<=enabled && rx1_tick;
            rx2_event_q<=enabled && rx2_tick;
            retire_valid_q<=retirement;
            retire_commit_pipe<={retire_commit_pipe[1:0],retire_valid_q};
            if (retirement) begin
                retire_complete_q<=retire_complete;
                retire_good_q<=retire_good;
                retire_compared_q<={cohort_bytes[retire_slot],3'd0};
                retire_errors_q<=cohort_errors[retire_slot];
            end
            // The counter outputs and exported ticks have the same fixed age.
            // At this commit edge, pre-edge ticks is exactly the original
            // pre-retirement time, even through enable gaps. Never stamp the
            // record early while the wide-counter carries are still in flight.
            if (retire_commit_pipe[2]) retired_ticks<=ticks;
        end
    end
    integer slot;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            reference_valid <= 0; compare_valid <= 0; event_valid <= 0;
        end else if (restart) begin
            reference_valid <= 0; compare_valid <= 0; event_valid <= 0;
        end else begin
            compare_valid <= enabled && supported && output_valid &&
                reference_valid[output_id[6:0]];
            event_valid <= enabled && supported && compare_valid &&
                compare_reference[47:16] == compare_id;
            if (enabled && supported && source_valid) begin
                reference_record[source_id[6:0]] <= {source_id,source_bytes};
                reference_valid[source_id[6:0]] <= 1;
            end
            compare_id <= output_id;
            compare_smp <= smp;
            compare_actual <= output_bytes;
            compare_reference <= reference_record[output_id[6:0]];
            event_id <= compare_id;
            event_smp <= compare_smp;
            event_block <= compare_smp ? {4'd0,compare_id[31:4]} : {5'd0,compare_id[31:5]};
            event_slot <= compare_smp ? compare_id[6:4] : compare_id[7:5];
            event_offset <= compare_smp ? {compare_id[3:0],1'b0} : compare_id[4:0];
            event_mask <= (compare_smp ? 32'd3 : 32'd1) <<
                (compare_smp ? {compare_id[3:0],1'b0} : compare_id[4:0]);
            event_byte_count <= compare_smp ? 6'd2 : 6'd1;
            event_errors <= {1'b0,pop8(compare_actual[7:0] ^ compare_expected[7:0])} +
                (compare_smp ? {1'b0,pop8(compare_actual[15:8] ^ compare_expected[15:8])} : 5'd0);
        end
    end
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            started_blocks <= 0; cohort_valid <= 0; cohort_order_bad <= 0;
            for (slot = 0; slot < 8; slot = slot + 1) begin
                cohort_tag[slot] <= 0; cohort_mask[slot] <= 0;
                cohort_errors[slot] <= 0; cohort_bytes[slot] <= 0;
            end
        end else if (restart) begin
            started_blocks <= 0; cohort_valid <= 0; cohort_order_bad <= 0;
            for (slot = 0; slot < 8; slot = slot + 1) begin
                cohort_tag[slot] <= 0; cohort_mask[slot] <= 0;
                cohort_errors[slot] <= 0; cohort_bytes[slot] <= 0;
            end
        end else if (enabled) begin
            if (supported) begin
                for (slot=0;slot<8;slot=slot+1) begin
                    if (accept_bank[slot]) begin
                        cohort_mask[slot] <= cohort_mask[slot] | event_mask;
                        cohort_errors[slot] <= cohort_errors[slot] + event_errors;
                        cohort_bytes[slot] <= cohort_bytes[slot] + event_byte_count;
                        if ({1'b0,event_offset} != cohort_bytes[slot])
                            cohort_order_bad[slot] <= 1;
                    end
                end
                if (source_boundary) begin
                    cohort_valid[source_slot] <= 1;
                    cohort_tag[source_slot] <= source_block;
                    cohort_mask[source_slot] <= 0; cohort_errors[source_slot] <= 0;
                    cohort_bytes[source_slot] <= 0; cohort_order_bad[source_slot] <= 0;
                    if (started_blocks != 2) started_blocks <= started_blocks + 2'd1;
                    if (retirement) begin
                        // Entry belongs to this retired cohort by construction;
                        // source block slots advance consecutively including wrap.
                        cohort_valid[retire_slot] <= 0;
                    end
                end
            end
        end
    end
endmodule

// Exact unsigned modulo-2^64 pipelined accumulation (increment 0..511).
// Limb j incorporates input history j clocks later than limb 0. Delaying its
// export by 3-j clocks aligns ALL four limbs to one common event prefix.
// Throughput is one increment EVERY clock; visible latency is exactly 3 clocks.
// Upper limbs ALWAYS drain carries, including when input enable is false.
// Restart flushes both carry and alignment pipelines. No mixed-age snapshot.
// Keep this helper in FSOx86.v so the existing single-RTL-file project works.
module FsoDeliveryCounter64 (
    input wire clk, reset_n, restart, enable,
    input wire [8:0] increment,
    output wire [63:0] value
);
    wire [3:0] carry;
    genvar b;
    generate for (b=0; b<4; b=b+1) begin : gen_limb
        (* preserve, dont_merge *) reg [15:0] q;
        (* preserve, dont_merge *) reg carry_q;
        wire [16:0] sum;
        assign carry[b]=carry_q;
        if (b==0) begin : low_limb
            assign sum={1'b0,q}+(enable ? {8'd0,increment} : 17'd0);
        end else begin : upper_limb
            assign sum={1'b0,q}+{16'd0,carry[b-1]};
        end
        always @(posedge clk or negedge reset_n) begin
            if (!reset_n) begin q<=0; carry_q<=0; end
            else if (restart) begin q<=0; carry_q<=0; end
            else begin q<=sum[15:0]; carry_q<=sum[16]; end
        end
        if (b<3) begin : gen_align
            (* preserve, dont_merge *) reg [15:0] delay_q [0:2-b];
            integer d;
            always @(posedge clk or negedge reset_n) begin
                if (!reset_n) begin
                    for(d=0;d<3-b;d=d+1) delay_q[d]<=0;
                end else if (restart) begin
                    for(d=0;d<3-b;d=d+1) delay_q[d]<=0;
                end else begin
                    delay_q[0]<=q;
                    for(d=1;d<3-b;d=d+1) delay_q[d]<=delay_q[d-1];
                end
            end
            assign value[16*b +: 16]=delay_q[2-b];
        end else begin : direct_export
            assign value[16*b +: 16]=q;
        end
    end endgenerate
endmodule
