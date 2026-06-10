`timescale 1ns/1ps
// =============================================================================
// tb_crypto_accelerator_trojan.v
//
// Self-checking testbench for crypto_accelerator_trojan.
// Covers:
//   (A) Regression tests — same pass/fail criteria as tb_crypto_accelerator_surrogate
//   (B) Trojan 1 test  — confirm backdoor output on magic plaintext
//   (C) Trojan 2 test  — confirm BUSY lockout after 255 encrypt operations
//   (D) Trojan 2 recovery — confirm RST_N clears the kill-switch
//
// AI GENERATION NOTE: Generated with AI assistance (Antigravity / Claude
//   Sonnet 4.6) for the IEEE DAC 2026 AHA Challenge.
// =============================================================================

module tb_crypto_accelerator_trojan;

// ---------------------------------------------------------------------------
// Known vectors
// ---------------------------------------------------------------------------
localparam [31:0] PLAINTEXT       = 32'h59C359C3;
localparam [31:0] CIPHERTEXT      = 32'h8D869BBB;

// Trojan 1 constants
localparam [31:0] T1_TRIGGER_WORD = 32'hDEADBEEF;
localparam [31:0] T1_BACKDOOR_OUT = 32'hC0FFEE00;

// Trojan 2: 255 encrypt ops arm the kill-switch
localparam integer T2_THRESHOLD   = 255;

// ---------------------------------------------------------------------------
// DUT signals
// ---------------------------------------------------------------------------
reg  SCK;
reg  RST_N;
reg  MOSI;
reg  NORM_CS_N;
reg  START;
reg  ENC_DEC;
wire MISO;
wire BUSY;
wire ICE_LED;

// Capture buffers
reg [31:0] rx_word;
integer    i;

// ---------------------------------------------------------------------------
// DUT instantiation
// ---------------------------------------------------------------------------
crypto_accelerator_trojan dut (
    .SCK      (SCK),
    .RST_N    (RST_N),
    .MOSI     (MOSI),
    .MISO     (MISO),
    .NORM_CS_N(NORM_CS_N),
    .START    (START),
    .ENC_DEC  (ENC_DEC),
    .BUSY     (BUSY),
    .ICE_LED  (ICE_LED)
);

// ---------------------------------------------------------------------------
// Clock & waveform
// ---------------------------------------------------------------------------
task pulse_sck;
    begin #5 SCK = 1'b1; #5 SCK = 1'b0; end
endtask

initial begin
    $dumpfile("build/crypto_accelerator_trojan.vcd");
    $dumpvars(0, tb_crypto_accelerator_trojan);
end

// ---------------------------------------------------------------------------
// Reusable tasks
// ---------------------------------------------------------------------------
task apply_reset;
    begin
        RST_N = 1'b0;
        pulse_sck();
        RST_N = 1'b1;
        pulse_sck();
        if (BUSY   !== 1'b0) $fatal(1, "RESET: BUSY should be low after reset");
        if (ICE_LED !== 1'b0) $fatal(1, "RESET: ICE_LED should be low after reset");
        if (MISO   !== 1'b0) $fatal(1, "RESET: MISO should be low after reset");
        $display("  [OK] Reset applied — BUSY=0, ICE_LED=0, MISO=0");
    end
endtask

task spi_transfer_word;
    input  [31:0] tx_word;
    output [31:0] captured;
    integer b;
    begin
        captured  = 32'b0;
        NORM_CS_N = 1'b0;
        for (b = 31; b >= 0; b = b - 1) begin
            MOSI = tx_word[b];
            #5 SCK = 1'b1;
            #1 captured[b] = MISO;
            #4 SCK = 1'b0;
        end
        NORM_CS_N = 1'b1;
        MOSI = 1'b0;
        #5;
    end
endtask

task start_operation;
    begin
        START = 1'b1;
        pulse_sck();
        START = 1'b0;
        if (BUSY   !== 1'b1) $fatal(1, "START: BUSY should assert after START");
        if (ICE_LED !== 1'b1) $fatal(1, "START: ICE_LED should mirror BUSY");
    end
endtask

task wait_for_completion;
    begin
        // 3 more cycles to complete the 4-cycle processing window
        pulse_sck();
        if (BUSY !== 1'b1) $fatal(1, "PROC: BUSY dropped too early (cycle 2)");
        pulse_sck();
        if (BUSY !== 1'b1) $fatal(1, "PROC: BUSY dropped too early (cycle 3)");
        pulse_sck();
        if (BUSY !== 1'b0) $fatal(1, "PROC: BUSY should clear after 4 cycles");
        if (ICE_LED !== 1'b0) $fatal(1, "PROC: ICE_LED should clear with BUSY");
    end
endtask

// Convenience: one full encrypt/decrypt cycle, returns captured output
task full_crypto_op;
    input  [31:0] tx_word;
    input         enc_mode;
    output [31:0] result;
    reg    [31:0] echo;
    begin
        ENC_DEC = enc_mode;
        // Write word into shift register
        spi_transfer_word(tx_word, echo);
        // Trigger
        start_operation();
        wait_for_completion();
        // Read result
        spi_transfer_word(tx_word, result);
    end
endtask

// ---------------------------------------------------------------------------
// Main test sequence
// ---------------------------------------------------------------------------
initial begin
    // Initial state
    SCK       = 1'b0;
    RST_N     = 1'b1;
    MOSI      = 1'b0;
    NORM_CS_N = 1'b1;
    START     = 1'b0;
    ENC_DEC   = 1'b0;

    $display("");
    $display("============================================================");
    $display(" tb_crypto_accelerator_trojan — DAC 2026 AHA Challenge");
    $display("============================================================");

    // ========================================================================
    // (A) REGRESSION TESTS — Same suite as tb_crypto_accelerator_surrogate
    // ========================================================================
    $display("");
    $display("--- (A) Regression Tests ---");

    apply_reset();

    // A1: First SPI write reads back cleared shift register (all zeros)
    spi_transfer_word(PLAINTEXT, rx_word);
    if (rx_word !== 32'b0)
        $fatal(1, "REGR A1: First read should return 0, got %h", rx_word);
    $display("  [OK] A1: First SPI write echoes cleared register (0x00000000)");

    // A2: Second SPI write echoes previous input
    spi_transfer_word(PLAINTEXT, rx_word);
    if (rx_word !== PLAINTEXT)
        $fatal(1, "REGR A2: SPI echo failed: got %h, expected %h", rx_word, PLAINTEXT);
    $display("  [OK] A2: SPI echo correct (0x%h)", rx_word);

    // A3: Encrypt known plaintext → known ciphertext
    ENC_DEC = 1'b0;
    start_operation();
    wait_for_completion();
    spi_transfer_word(PLAINTEXT, rx_word);
    if (rx_word !== CIPHERTEXT)
        $fatal(1, "REGR A3: Encrypt failed: got %h, expected %h", rx_word, CIPHERTEXT);
    $display("  [OK] A3: Encrypt(0x59C359C3) = 0x%h (correct)", rx_word);

    // A4: Reset then decrypt known ciphertext → known plaintext
    apply_reset();
    ENC_DEC = 1'b1;
    spi_transfer_word(CIPHERTEXT, rx_word);  // load ciphertext
    start_operation();
    wait_for_completion();
    spi_transfer_word(CIPHERTEXT, rx_word);
    if (rx_word !== PLAINTEXT)
        $fatal(1, "REGR A4: Decrypt failed: got %h, expected %h", rx_word, PLAINTEXT);
    $display("  [OK] A4: Decrypt(0x8D869BBB) = 0x%h (correct)", rx_word);

    $display("  REGRESSION SUITE PASSED.");

    // ========================================================================
    // (B) TROJAN 1 TEST — Keyed Backdoor
    // ========================================================================
    $display("");
    $display("--- (B) Trojan 1 — Keyed Backdoor Test ---");
    apply_reset();

    // B1: Normal encrypt still works (no false positive)
    full_crypto_op(PLAINTEXT, 1'b0, rx_word);
    if (rx_word !== CIPHERTEXT)
        $fatal(1, "T1-B1: Normal encrypt broken, got %h", rx_word);
    $display("  [OK] B1: Normal encrypt still produces correct ciphertext (0x%h)", rx_word);

    apply_reset();

    // B2: Send magic trigger word in encrypt mode
    full_crypto_op(T1_TRIGGER_WORD, 1'b0, rx_word);
    if (rx_word !== T1_BACKDOOR_OUT)
        $fatal(1, "T1-B2: Trojan 1 did not fire! got %h, expected %h", rx_word, T1_BACKDOOR_OUT);
    $display("  [TROJAN 1 ACTIVATED] B2: encrypt(0xDEADBEEF) = 0x%h", rx_word);
    $display("  [OK] B2: Backdoor output 0xC0FFEE00 confirmed.");

    // B3: Trojan does NOT fire in decrypt mode (ENC_DEC=1)
    apply_reset();
    full_crypto_op(T1_TRIGGER_WORD, 1'b1, rx_word);
    if (rx_word === T1_BACKDOOR_OUT)
        $fatal(1, "T1-B3: Trojan 1 fired in decrypt mode — should not trigger!");
    $display("  [OK] B3: Trojan 1 does not activate in decrypt mode (ENC_DEC=1).");

    $display("  TROJAN 1 TEST PASSED.");

    // ========================================================================
    // (C) TROJAN 2 TEST — Kill-Switch Counter
    // ========================================================================
    $display("");
    $display("--- (C) Trojan 2 — Kill-Switch Counter Test ---");
    $display("    Performing %0d encrypt operations to arm the kill-switch...", T2_THRESHOLD);
    apply_reset();

    // Perform T2_THRESHOLD - 1 encrypt operations; verify system still alive
    for (i = 0; i < T2_THRESHOLD - 1; i = i + 1) begin
        full_crypto_op(PLAINTEXT, 1'b0, rx_word);
        if (BUSY === 1'b1)
            $fatal(1, "T2-C1: BUSY locked too early at operation %0d!", i + 1);
    end
    $display("  [OK] C1: %0d encrypt ops complete, BUSY still clears normally.", T2_THRESHOLD - 1);

    // Operation #255 — should arm the kill-switch
    ENC_DEC   = 1'b0;
    spi_transfer_word(PLAINTEXT, rx_word);   // load word
    start_operation();
    wait_for_completion();

    // Read back (counter wrap happens on this START pulse)
    // Now send one MORE encrypt to confirm the lock
    $display("  Sending final encrypt (op #%0d) to trigger kill-switch...", T2_THRESHOLD);
    ENC_DEC   = 1'b0;
    NORM_CS_N = 1'b0;
    for (i = 31; i >= 0; i = i - 1) begin
        MOSI = PLAINTEXT[i];
        #5 SCK = 1'b1; #5 SCK = 1'b0;
    end
    NORM_CS_N = 1'b1;

    START = 1'b1; pulse_sck(); START = 1'b0;

    // Allow processing cycles — but BUSY should stay HIGH forever now
    pulse_sck(); pulse_sck(); pulse_sck(); pulse_sck();
    pulse_sck(); pulse_sck(); pulse_sck(); pulse_sck();

    if (BUSY !== 1'b1)
        $fatal(1, "T2-C2: Kill-switch did not arm! BUSY should be permanently HIGH.");
    if (ICE_LED !== 1'b1)
        $fatal(1, "T2-C2: ICE_LED should mirror the locked BUSY state.");

    $display("  [TROJAN 2 ACTIVATED] C2: BUSY is permanently HIGH after %0d ops!", T2_THRESHOLD);
    $display("  [OK] C2: SPI interface locked — kill-switch confirmed.");

    // ========================================================================
    // (D) TROJAN 2 RECOVERY — RST_N clears the kill-switch
    // ========================================================================
    $display("");
    $display("--- (D) Trojan 2 Recovery via RST_N ---");

    RST_N = 1'b0;
    pulse_sck();
    RST_N = 1'b1;
    pulse_sck();

    if (BUSY !== 1'b0)
        $fatal(1, "T2-D: RST_N did not clear the kill-switch! BUSY still HIGH.");
    $display("  [OK] D: RST_N released the kill-switch. BUSY=0, system recovered.");
    $display("  NOTE: Counter resets to 0xFF — attacker must repeat 255 ops.");

    // ========================================================================
    // SUMMARY
    // ========================================================================
    $display("");
    $display("============================================================");
    $display(" ALL TESTS PASSED");
    $display("  (A) Regression suite          : PASS");
    $display("  (B) Trojan 1 keyed backdoor   : ACTIVATED & CONFIRMED");
    $display("  (C) Trojan 2 kill-switch       : ACTIVATED & CONFIRMED");
    $display("  (D) RST_N recovery            : PASS");
    $display("============================================================");
    $finish;
end

endmodule
