set_global_assignment -entity "PLL_x86" -library "lib_PLL_x86" -name IP_TOOL_NAME "altera_pll"
set_global_assignment -entity "PLL_x86" -library "lib_PLL_x86" -name IP_TOOL_VERSION "25.1"
set_global_assignment -entity "PLL_x86" -library "lib_PLL_x86" -name IP_TOOL_ENV "mwpim"
set_global_assignment -library "lib_PLL_x86" -name SPD_FILE [file join $::quartus(sip_path) "PLL_x86.spd"]

set_global_assignment -library "lib_PLL_x86" -name MISC_FILE [file join $::quartus(sip_path) "PLL_x86_sim/PLL_x86.vo"]
