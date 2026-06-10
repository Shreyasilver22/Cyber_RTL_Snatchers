# Trojan Design Rationale
## IEEE DAC 2026 AHA Challenge — GREAT Workshop

**Target:** iCE40-UP5K Cryptographic Accelerator on Hackster Board  
**AI Tool:** Antigravity (Claude Sonnet 4.6 Thinking)  
**Phase:** Phase 1 (Simulation)  

---

## 1. Threat Model

The target IP core is a lightweight cryptographic accelerator connected to an RP2040 application processor over SPI. The IP is used to protect data confidentiality (encrypt) and verify integrity (decrypt-then-compare). An adversary who has gained access to the FPGA supply chain, RTL repository, or synthesis scripts can insert hardware Trojans that remain dormant during testing but activate in the field.

**Adversary goals:**
- Break cryptographic guarantees without being detected by functional testing
- Create a recoverable or irrecoverable denial-of-service condition
- Exploit trigger conditions that are vanishingly rare in normal operation

---

## 2. Trojan 1 — Keyed Backdoor (Combinational)

### Design

| Property | Value |
|----------|-------|
| **Type** | Combinational payload, output substitution |
| **Trigger** | `input_word == 32'hDEADBEEF` AND `ENC_DEC == 0` |
| **Payload** | Output word replaced with `32'hC0FFEE00` |
| **Location** | Output mux in the 4-cycle processing completion stage |
| **RTL file** | `rtl/crypto_accelerator_trojan.v` |

### How It Works

```verilog
// Combinational Trojan 1 trigger
wire t1_trigger;
assign t1_trigger = (input_word == T1_TRIGGER_WORD) & (~ENC_DEC);

// Output mux — blends with normal result selection
trojan_selected_out = t1_trigger ? T1_BACKDOOR_OUT : crypto_func(input_word, ENC_DEC);
```

When the trigger fires, the real ciphertext is discarded and the backdoor constant `0xC0FFEE00` is driven onto the output SPI shift register. From the RP2040's perspective, the IP core behaved normally: BUSY asserted, then cleared on schedule, and data shifted out over MISO.

### Attack Scenario

1. **Attacker embeds the Trojan** at RTL synthesis time (supply-chain attack).
2. **Normal testing passes**: the magic word `0xDEADBEEF` almost never appears in real workloads.
3. **In the field**, the attacker sends `0xDEADBEEF` as a plaintext. They receive `0xC0FFEE00` as the "ciphertext."
4. **Authentication bypass**: any system that authenticates by checking `encrypt(challenge) == response` can be fooled if the attacker has pre-arranged the trigger word as the challenge.

### Stealthiness Analysis

- **Trigger probability**: 1 in 2³² ≈ 2.3 × 10⁻¹⁰ for uniformly random 32-bit inputs.
- **No timing anomaly**: The 4-cycle latency is identical for triggered and non-triggered cases.
- **No power spike**: The payload is a wire-OR mux; no additional switching activity occurs.
- **Functional testing**: Standard vector-based regression with non-magic inputs will never activate the trigger.

### Exploit

See `exploit/trojan_exploit.py` → `exploit_trojan1()`.

---

## 3. Trojan 2 — Kill-Switch Counter (Sequential)

### Design

| Property | Value |
|----------|-------|
| **Type** | Sequential payload, denial-of-service |
| **Trigger** | 255 consecutive encrypt (`ENC_DEC=0`) START pulses |
| **Payload** | `BUSY` and `ICE_LED` permanently HIGH; SPI hangs |
| **Recovery** | `RST_N` assertion (resets counter to 0xFF) |
| **Location** | Hidden 8-bit counter in START detection branch |
| **RTL file** | `rtl/crypto_accelerator_trojan.v` |

### How It Works

```verilog
// Hidden 8-bit down-counter; armed flag latches when counter wraps 0x01→0x00
reg [7:0] t2_counter;   // starts at 8'hFF after RST_N
reg       t2_armed;

// Counter update inside START detection (encrypt only)
if (!ENC_DEC && !t2_armed) begin
    if (t2_counter == 8'h01) begin
        t2_armed   <= 1'b1;   // arm kill-switch
        t2_counter <= 8'h00;
    end else begin
        t2_counter <= t2_counter - 8'h01;
    end
end

// Output OR — permanently drives BUSY when armed
assign BUSY    = busy_core | t2_armed;
assign ICE_LED = ice_led_core | t2_armed;
```

The `t2_counter` starts at `8'hFF` and decrements by 1 on each encrypt START. After 255 encrypts, it wraps to `8'h00` and `t2_armed` latches high. From that point on, `BUSY` is permanently asserted regardless of the core's internal state. No further SPI operations can complete.

### Attack Scenario

1. **Attacker ships Trojaned bitstream** to target hardware.
2. **Normal use**: The system operates correctly for up to 254 encrypt operations.
3. **DoS attack**: Attacker queues 255 dummy encrypt requests (possible via any authenticated API that exposes the crypto accelerator).
4. **Effect**: The FPGA's SPI interface permanently stalls. The RP2040 will hang waiting for BUSY to clear. The entire crypto subsystem is unavailable until a hardware reset.
5. **Availability impact**: In an embedded system without watchdog reset, this is a permanent brick.

### Stealthiness Analysis

- **Trigger visibility**: The counter is an 8-bit register with no observable effect during the first 254 operations.
- **Disguise**: The register resembles a legitimate "operation counter" or "diagnostic latch" — a common design pattern in FPGAs for telemetry.
- **Test coverage gap**: Standard regression suites run O(10) test cases, far below the 255-operation trigger threshold.
- **LFSR variant** (hardening option): For additional stealthiness, the counter can be replaced with an 8-bit LFSR (polynomial x⁸+x⁶+x⁵+x⁴+1), making the trigger state appear at an irregular, non-obvious operation count.

### Exploit

See `exploit/trojan_exploit.py` → `exploit_trojan2()`.

---

## 4. Comparison Table

| Feature | Trojan 1 (Backdoor) | Trojan 2 (Kill-Switch) |
|---------|---------------------|------------------------|
| Payload type | Confidentiality break | Availability break |
| Trigger | Specific input value | Operation count |
| Activation | Immediate | Delayed (255 ops) |
| Reversible? | No (output wrong) | Yes (RST_N recovers) |
| Observable overhead | None | None |
| Timing change | None | None |
| Test vector detection | Only if magic word tested | Only if >255 op run |

---

## 5. Verification

Both Trojans are verified by `tb/tb_crypto_accelerator_trojan.v`:

```bash
make sim_trojan
```

Expected output:
```
[OK] A3: Encrypt(0x59C359C3) = 0x8D869BBB (correct)
[TROJAN 1 ACTIVATED] B2: encrypt(0xDEADBEEF) = 0xC0FFEE00
[TROJAN 2 ACTIVATED] C2: BUSY is permanently HIGH after 255 ops!
[OK] D: RST_N released the kill-switch.
ALL TESTS PASSED
```

---

## 6. Phase 2 Synthesis Notes

For in-person Phase 2 synthesis on real Hackster hardware:
- Tools: `yosys` (synthesis) + `nextpnr-ice40 --up5k` (place & route) + `icepack`
- The Trojan mux adds ~2 LUTs; the counter adds ~8 FFs + 1 comparator
- Both Trojans fit comfortably within the iCE40-UP5K resource budget
- The bitstream can be flashed via `iceprog`

---

*Document generated with AI assistance (Antigravity / Claude Sonnet 4.6 Thinking).*
