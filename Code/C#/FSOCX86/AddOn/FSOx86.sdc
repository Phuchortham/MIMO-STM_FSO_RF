# V3.3.2 CLOCK-ONLY DEVELOPMENT CONSTRAINTS. Not board I/O/CDC signoff.
# The FPGA PLL stays at 250 MHz. Do not change its IP settings.
# FT601 clock is separate. Set FSO_FT_CLK_MHZ to the verified device setting
# (66 or 100) before final analysis. Without that setting we use 100 MHz only
# as an explicitly labelled development assumption, not a measured frequency.
set fso_ft_clock_mhz 100.0
if {[info exists ::env(FSO_FT_CLK_MHZ)]} {
    set fso_ft_clock_mhz $::env(FSO_FT_CLK_MHZ)
    if {$fso_ft_clock_mhz != 66 && $fso_ft_clock_mhz != 100} {
        error "FSO_FT_CLK_MHZ must be the verified FT601 setting: 66 or 100."
    }
} else {
    post_message -type warning "V3.3.2: FT601 clock not confirmed; 100 MHz DEVELOPMENT assumption. Board I/O/CDC timing is NOT signed off."
}
create_clock -name CLOCK_50 -period 20.000 [get_ports {CLOCK_50}]
create_clock -name ft_clk -period [expr {1000.0 / $fso_ft_clock_mhz}] [get_ports {ft_clk}]
derive_pll_clocks
derive_clock_uncertainty
# Intentionally no blanket clock groups, false paths or multicycle exceptions.
# They would hide CDC/control problems rather than repair them. Board input/
# output delays require the actual FT601 mode, PCB delays and interface review.
