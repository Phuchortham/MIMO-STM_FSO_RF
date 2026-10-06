# V3.3 validation - 8 September 2026

Separate source/test candidate based on V3.2. Functional checks and Quartus
analysis/synthesis passed. **No new fitted timing closure or hardware validation
is claimed. Keep the working FPGA build until those checks are completed.**

No hardware, COM port, live FPGA project or programmer was used. No SOF is supplied.
V3.1/V3.2 source files were not changed. All five inherited RF helper sources are
byte-identical to V3.2. The supplied Designer is byte-identical to the attachment,
including the eleven columns, names, headings, order, widths and frozen settings.

## Final-source functional checks

| Check | Result |
|---|---|
| Standalone C# delivery arithmetic | 53 tests passed |
| Eleven inherited optical GUI suites | 7,004 assertions passed |
| RF GUI integration | 60 cases / 523 assertions passed |
| New delivery GUI integration | 103 cases / 453 assertions passed |
| Passive RTL monitor unit tests | 24 assertions passed |
| Real USB-FSM / laser-pin-path RTL simulation | 18 cases / 2,638 assertions passed |
| Actual manual-blink pin simulation | 4 assertions passed |
| Original SISO text smoke on the final RTL | 8 cases / 288 assertions passed |

All thirteen GUI suites were compiled against the final production sources and
the real supplied Designer using C# 7.3, warning level 4, warnings as errors. Their
FT601 and RF endpoints are substitutes; no native device is accessed. The separate
calculator also compiles with checked arithmetic enabled.

GUI coverage includes the unchanged six original cell positions, all eleven CSV
columns, coherent 64-bit decoding, failure at every new status ID, stale/replayed
tokens, run transitions, USB freshness failures and recovery, unknown versus zero
measurements, RF separation, and SISO logging without changing its text/grid.
The one-missing-block test preserves 99.999744% rather than rounding to 100%.

The twelve uncoded actual-path simulations cover SISO/DIV/SMP at 5/10/25/50 Mbps
per lane with odd-length Free Text Sabai. Healthy retired-cohort deltas measured
the expected internal decoded payload rates, including 100 Mbps for 50+50 SMP.
At every rate, blocking lane 1 allowed DIV delivery after selection settled, but
stopped SMP complete delivery while its expected-block denominator continued.
Recovery, immutable snapshots and R39/R53 retained history passed. Startup and
switching losses were not erased to make the result look better.

Six additional DIV/SMP cases at 10 Mbps cover CRC payload extraction, Repeat-3 and
Hamming. They do not establish received CRC validation or physical coding gain.
Known-event monitor tests cover corruption, missing/duplicate/late/misordered
bytes, outages, ID/counter rollover and reset. Manual blink invalidates delivery
until Start/reset so old source IDs cannot receive stale credit.

Detailed evidence is retained in this workspace under validation/gui_summary.md,
validation/calculator_tests.log and tests/rtl/DELIVERY_RESULTS.md, with neighboring
logs and test runners. These test artifacts are not installed into the application
and are not included in the source-only ZIP.

## Quartus synthesis, not fitted timing

Quartus Prime 25.1std Lite analysis/synthesis completed with exit 0, zero errors
and 63 warnings on the same final RTL. It used a NEW isolated project under
D:/TestBed_chat/tmp/v33_delivery_synthesis, copied device/pin/PLL/SDC configuration
from the earlier isolated V3.1 project, and changed only its source-file target.
No fitter, timing analyzer, assembler or programmer was run for V3.3.

Post-map estimates: 10,568 ALMs, 6,843 combinational ALUTs, 16,212 registers,
2,566 block-memory bits, eight DSP elements, one PLL and 82 pins. These are synthesis
estimates, not fitted utilization. The passive monitor itself uses 2,673 ALUTs,
5,504 registers and 2,048 block-memory bits; observation is not free hardware.
See validation/synthesis-review.md and its retained reports for warning details.

The V3.1/V3.2 baseline has documented failed fitted timing: worst whole-design
setup -5.559 ns, core setup -5.067 ns and whole-design hold -0.145 ns. Those are
BASELINE numbers, not a V3.3 timing measurement. Extra observer logic, shared
register merging and inferred RAM can affect the existing physical implementation
even though no original optical source lines were removed. A fresh fit and
all-corner timing/CDC review are required; do not assume this addition closes timing.

## Scope and limits

- The PLL remains 250 MHz. New RTL integration uses an ideal PLL, a 100 MHz FT
  clock and ideal digital pin transport. No analog noise, metastability or routed
  setup/hold behavior is modeled. The physical FT clock was not measured here.
- New physical-path cases are OOK-NRZ. No new RZ/PWM/PPM or full PRBS/counter
  integration matrix was run. Existing support gates and source behavior remain.
- Counters observe the actual internal optical decoder/reconstruction events,
  using local shared-FPGA source IDs/reference memory. This is not independent
  on-air packet sequencing, CRC-verified application delivery, continuous PC/USB
  payload throughput, or a measured experimental 100 Mbps result.
- Goodput/delivery use correct unique 32-byte source cohorts. Partial decoded
  bytes can contribute output BER, but not goodput. A valid outage can therefore
  have zero delivery with undefined output BER, not a fabricated BER value.
- RF behavior remains V3.2. Optical-only output metrics show Unavailable (RF)
  while RF owns displayed text. No comparable RF goodput/delivery was invented.
- The two-second new-telemetry freshness check rejects delayed successful reads;
  it cannot cancel a blocked native synchronous FT601 API call.

## Source identity

| Source | SHA-256 |
|---|---|
| FSOx86.v | 79B487EDCBBEAABFDFF5A71AF3ACE99E6DC97E7B67FBA181EEB704ADB454032E |
| Form1.cs | 1708EB2B0BD2D6BE2A05CA8D28BB54589457CDE837373383699E53A24C1214A2 |
| Form1.DeliveryMetrics.cs | 25DD73F3CAB978EB8FA329E3AE620ED539BF4C2FE7F4ACF9C9B20273915F7267 |
| DeliveryMetrics.cs | 44A69A60CC6BA2E9FE556068D19ACFB9EDC7561CA14A520807C460D093DC0226 |
| Form1.Designer.cs | C7B2EEE299406BB68FFEE8C9389CFD782063A3346F33ABB012EFF0BE3130FF4D |

SOURCE_SHA256.txt covers the complete production source/instruction set in the
ZIP. The matching C# files AND Verilog are required for the new output metrics.
