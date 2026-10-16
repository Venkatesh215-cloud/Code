
#################################################ConstrainsFile###############################################

# =============================================================================
# Arty A7-100T - AD9850 + LMX2820 Integration
# FIXED: Removed PULLDOWN on lmx_ld (was fighting LMX open-drain output)
#        Added PULLUP instead for open-drain LD pin
# =============================================================================

# Clock
set_property -dict { PACKAGE_PIN E3  IOSTANDARD LVCMOS33 } [get_ports { clk100 }]
create_clock -add -name sys_clk_pin -period 10.00 -waveform {0 5} [get_ports { clk100 }]

# Reset Button BTN0
set_property -dict { PACKAGE_PIN D9  IOSTANDARD LVCMOS33 } [get_ports { btn0 }]

# =============================================================================
# AD9850 ? Pmod JA
# =============================================================================
set_property -dict { PACKAGE_PIN G13 IOSTANDARD LVCMOS33 } [get_ports { ad9850_d7      }]
set_property -dict { PACKAGE_PIN B11 IOSTANDARD LVCMOS33 } [get_ports { ad9850_w_clk   }]
set_property -dict { PACKAGE_PIN A11 IOSTANDARD LVCMOS33 } [get_ports { ad9850_fq_ud   }]
set_property -dict { PACKAGE_PIN D12 IOSTANDARD LVCMOS33 } [get_ports { ad9850_rst_pin }]

# =============================================================================
# LMX2820 ? Pmod JB
# =============================================================================
set_property -dict { PACKAGE_PIN E15 IOSTANDARD LVCMOS33 } [get_ports { pll_sclk       }]
set_property -dict { PACKAGE_PIN E16 IOSTANDARD LVCMOS33 } [get_ports { pll_sdata      }]
set_property -dict { PACKAGE_PIN D15 IOSTANDARD LVCMOS33 } [get_ports { pll_cs         }]
set_property -dict { PACKAGE_PIN C15 IOSTANDARD LVCMOS33 } [get_ports { pll_pll_en     }]
set_property -dict { PACKAGE_PIN J17 IOSTANDARD LVCMOS33 } [get_ports { pll_mute       }]
set_property -dict { PACKAGE_PIN J18 IOSTANDARD LVCMOS33 } [get_ports { pll_lock_error }]
                                                                                
# =============================================================================
# FIXED lmx_ld:
# REMOVED:  set_property PULLDOWN true  ? was pulling LD LOW always
# ADDED:    set_property PULLUP   true  ? correct for open-drain LD output
# =============================================================================
set_property -dict { PACKAGE_PIN K15 IOSTANDARD LVCMOS33 } [get_ports { pll_ld   }]
set_property PULLUP true [get_ports { lmx_ld }]

set_property -dict { PACKAGE_PIN J15 IOSTANDARD LVCMOS33 } [get_ports { pll_done }]

# =============================================================================
# Status LEDs
# LD4 = ad9850_busy
# LD5 = ad9850_done   ? YOUR GREEN LED (working correctly)
# LD6 = system_done
# LD7 = system_error  ? YOUR GREEN LED (lock timeout)
# =============================================================================
set_property -dict { PACKAGE_PIN H5  IOSTANDARD LVCMOS33 } [get_ports { ad9850_busy  }]
set_property -dict { PACKAGE_PIN J5  IOSTANDARD LVCMOS33 } [get_ports { ad9850_done  }]
set_property -dict { PACKAGE_PIN T9  IOSTANDARD LVCMOS33 } [get_ports { system_done  }]
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports { system_error }]

# =============================================================================
# Timing Exceptions
# =============================================================================
set_false_path -from [get_ports { lmx_ld }]
set_false_path -from [get_ports { btn0   }]