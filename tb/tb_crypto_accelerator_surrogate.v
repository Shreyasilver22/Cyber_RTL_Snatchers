`timescale 1ns/1ps

module tb_crypto_accelerator_surrogate;

localparam [31:0] PLAINTEXT  = 32'h59C359C3;
localparam [31:0] CIPHERTEXT = 32'h8D869BBB;

reg SCK;
reg RST_N;
reg MOSI;
reg NORM_CS_N;
reg START;
reg ENC_DEC;
wire MISO;
wire BUSY;
wire ICE_LED;

reg [31:0] rx_word;
integer i;

crypto_accelerator_surrogate dut (
    .SCK(SCK),
    .RST_N(RST_N),
    .MOSI(MOSI),
    .MISO(MISO),
    .NORM_CS_N(NORM_CS_N),
    .START(START),
    .ENC_DEC(ENC_DEC),
    .BUSY(BUSY),
    .ICE_LED(ICE_LED)
);

task pulse_sck;
    begin
        #5 SCK = 1'b1;
        #5 SCK = 1'b0;
    end
endtask

task apply_reset;
    begin
        RST_N = 1'b0;
        pulse_sck();
        RST_N = 1'b1;
        pulse_sck();

        if (BUSY !== 1'b0) $fatal(1, "BUSY should be low after reset");
        if (ICE_LED !== 1'b0) $fatal(1, "ICE_LED should be low after reset");
        if (MISO !== 1'b0) $fatal(1, "MISO should reset low");
    end
endtask

task spi_transfer_word;
    input  [31:0] tx_word;
    output [31:0] captured_word;
    integer bit_index;
    begin
        captured_word = 32'b0;
        NORM_CS_N = 1'b0;
        for (bit_index = 31; bit_index >= 0; bit_index = bit_index - 1) begin
            MOSI = tx_word[bit_index];
            #5 SCK = 1'b1;
            #1 captured_word[bit_index] = MISO;
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

        if (BUSY !== 1'b1) $fatal(1, "BUSY should assert immediately after START");
        if (ICE_LED !== 1'b1) $fatal(1, "ICE_LED should mirror BUSY while active");
    end
endtask

task expect_processing_window;
    begin
        pulse_sck();
        if (BUSY !== 1'b1) $fatal(1, "BUSY dropped too early after cycle 2");
        if (ICE_LED !== 1'b1) $fatal(1, "ICE_LED dropped too early after cycle 2");

        pulse_sck();
        if (BUSY !== 1'b1) $fatal(1, "BUSY dropped too early after cycle 3");
        if (ICE_LED !== 1'b1) $fatal(1, "ICE_LED dropped too early after cycle 3");

        pulse_sck();
        if (BUSY !== 1'b0) $fatal(1, "BUSY should clear after 4 total processing cycles");
        if (ICE_LED !== 1'b0) $fatal(1, "ICE_LED should clear with BUSY");
    end
endtask

initial begin
    $dumpfile("build/crypto_accelerator_surrogate.vcd");
    $dumpvars(0, tb_crypto_accelerator_surrogate);

    SCK       = 1'b0;
    RST_N     = 1'b1;
    MOSI      = 1'b0;
    NORM_CS_N = 1'b1;
    START     = 1'b0;
    ENC_DEC   = 1'b0;

    apply_reset();

    spi_transfer_word(PLAINTEXT, rx_word);
    if (rx_word !== 32'b0) $fatal(1, "Initial read during first write should return the cleared shift register");

    spi_transfer_word(PLAINTEXT, rx_word);
    if (rx_word !== PLAINTEXT) $fatal(1, "SPI echo/readback failed: got %h expected %h", rx_word, PLAINTEXT);

    ENC_DEC = 1'b0;
    start_operation();
    expect_processing_window();

    spi_transfer_word(PLAINTEXT, rx_word);
    if (rx_word !== CIPHERTEXT) $fatal(1, "Encryption failed: got %h expected %h", rx_word, CIPHERTEXT);

    apply_reset();

    ENC_DEC = 1'b1;
    spi_transfer_word(CIPHERTEXT, rx_word);
    if (rx_word !== 32'b0) $fatal(1, "Initial read during first ciphertext write should return the cleared shift register");

    start_operation();
    expect_processing_window();

    spi_transfer_word(CIPHERTEXT, rx_word);
    if (rx_word !== PLAINTEXT) $fatal(1, "Decryption failed: got %h expected %h", rx_word, PLAINTEXT);

    $display("All surrogate tests passed.");
    $finish;
end

endmodule
