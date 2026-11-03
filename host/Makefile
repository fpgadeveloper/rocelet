# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
#
# rocelet_host - rocelet host helper (libibverbs).
#
#   make            rocelet_host with host-memory buffers only (`--mem gpu` stops with a message)
#   make CUDA=1     also the GPU ring (`--mem gpu`, `selftest-gpu`): nvcc, CUDA 11.7+ and
#                   rdma-core >= 34 (ibv_reg_dmabuf_mr). CUDA_HOME (/usr/local/cuda),
#                   CUDA_ARCH (nvcc -arch; default native = the GPU in this machine; give it
#                   explicitly, e.g. sm_120 for an RTX PRO Blackwell, to build without touching
#                   the GPU, or on a machine without one)
#   make test       tests that need no RDMA device and no GPU: selftest, pattern cross-check,
#                   roce_check tests, the GPU ring logic on the mock back end
#                   (tests/test_gpu, `selftest-gpu --mock`). `selftest-gpu` on a real GPU is
#                   never run by `make`: run it by hand (README.md).
#
# Switching between `make` and `make CUDA=1` rebuilds everything (build.cfg).
# CUDA build adapted from an earlier Opsero host receiver (same copyright holder, MIT).

CC      ?= gcc
WERROR  ?= -Werror
CFLAGS  ?= -O2 -g
CFLAGS  += -std=gnu11 -Wall -Wextra $(WERROR) -D_GNU_SOURCE
LDLIBS  += -libverbs

CUDA      ?=
CUDA_HOME ?= /usr/local/cuda
CUDA_ARCH ?= native
NVCC      ?= $(CUDA_HOME)/bin/nvcc
NVFLAGS   ?= -O3 -g -lineinfo
NVFLAGS   += -std=c++17 -arch=$(CUDA_ARCH) -D_GNU_SOURCE -Xcompiler -Wall,-Wextra

ifeq ($(CUDA),1)
CFLAGS  += -DRL_CUDA -I$(CUDA_HOME)/include
GPU_O   := rl_gpu_cuda.o
# libcuda from the driver at run time (the toolkit's stub at link time)
LDLIBS  += -L$(CUDA_HOME)/lib64 -L$(CUDA_HOME)/lib64/stubs -lcudart_static -lcuda -ldl -lrt \
           -lpthread -lstdc++
else
GPU_O   := rl_gpu_nocuda.o
endif

# GPU ring logic without CUDA: shared by rocelet_host and tests/test_gpu
GPUCORE = rl_gpu_ref.o rl_gpu_mock.o rl_gpuv.o rl_gring.o rl_gpu_selftest.o
OBJS    = rocelet_host.o rl_record.o rl_verbs.o rl_stats.o $(GPUCORE) $(GPU_O)
HEADERS = rl_common.h rl_verbs.h rl_stats.h rl_gpu.h rl_gpuv.h rl_gring.h

all: rocelet_host

rocelet_host: $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS) $(LDLIBS)

# rebuild when CUDA / CUDA_ARCH change
build.cfg: FORCE
	@echo 'CUDA=$(CUDA) CUDA_ARCH=$(CUDA_ARCH) CUDA_HOME=$(CUDA_HOME)' | cmp -s - $@ || \
	    echo 'CUDA=$(CUDA) CUDA_ARCH=$(CUDA_ARCH) CUDA_HOME=$(CUDA_HOME)' > $@

%.o: %.c $(HEADERS) Makefile build.cfg
	$(CC) $(CFLAGS) -c -o $@ $<

rl_gpu_cuda.o: rl_gpu_cuda.cu rl_common.h rl_gpu.h Makefile build.cfg
	$(NVCC) $(NVFLAGS) -c -o $@ $<

tests/test_gpu: tests/test_gpu.c rl_record.o rl_gpu_ref.o rl_gpu_mock.o rl_gpuv.o rl_gring.o \
                rl_gpu_nocuda.o $(HEADERS)
	$(CC) $(CFLAGS) -DRL_TEST_NO_CUDA -I. -o $@ tests/test_gpu.c rl_record.o rl_gpu_ref.o \
	    rl_gpu_mock.o rl_gpuv.o rl_gring.o rl_gpu_nocuda.o -libverbs

# Tests that need no RDMA hardware and no GPU: C selftest (pattern vector, records, slot
# model), the C pattern against its Python transcription (tests/pattern_ref.py), roce_check.py
# against scapy-built frames (good and deliberately broken ones), the GPU ring logic on the
# mock back end.
test: rocelet_host tests/test_gpu
	./rocelet_host selftest
	python3 -I tests/pattern_ref.py --check ./rocelet_host
	./tests/test_gpu
	./rocelet_host selftest-gpu --mock
	python3 -I tests/test_roce_check.py

# The same without scapy (python3-scapy is not on every test host).
test-noscapy: rocelet_host tests/test_gpu
	./rocelet_host selftest
	python3 -I tests/pattern_ref.py --check ./rocelet_host
	./tests/test_gpu
	./rocelet_host selftest-gpu --mock

clean:
	rm -f rocelet_host tests/test_gpu *.o build.cfg

.PHONY: all test test-noscapy clean FORCE
