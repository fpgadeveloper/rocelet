# SPDX-License-Identifier: MIT
# rocelet - convenience targets
#   make sim          full simulation regression (Vivado xsim + Python/scapy)
#   make sim-quick    the same with smaller workloads
#   make regs         regenerate the register map files from regs/rocelet_regs.py
#   make synth        out-of-context synthesis / place / route of the v1 configuration
#   make synth-variants  synthesis of the build options
#   make synth-mac    place and route at the MAC widths (512 KCU116 @ 322 MHz, 256 / 64 ZCU106 @ 156.25 MHz)
#   make host         build the host helper (needs libibverbs)
#   make docs         build the documentation (sphinx, myst-parser, sphinx-rtd-theme)
PYTHON ?= python3

.PHONY: sim sim-quick regs synth synth-variants synth-mac host docs clean

sim:
	$(PYTHON) -I sim/run_tests.py

sim-quick:
	$(PYTHON) -I sim/run_tests.py --quick

regs:
	$(PYTHON) -I regs/rocelet_regs.py

synth:
	synth/run_synth.sh synth/jobs_v1.txt synth/build

synth-variants:
	synth/run_synth.sh synth/jobs_variants.txt synth/build

synth-mac:
	synth/run_synth.sh synth/jobs_mac.txt synth/build_mac
	$(PYTHON) -I synth/report.py --mac --version rtl synth/build_mac

host:
	$(MAKE) -C host

docs:
	sphinx-build -W -b html docs docs/_build/html

clean:
	rm -rf sim/build synth/build synth/build_mac
