obj-m += intel_skl_int3472_discrete.o intel_skl_int3472_common.o
intel_skl_int3472_discrete-y := discrete.o discrete_quirks.o clk_and_regulator.o led.o
intel_skl_int3472_common-y := common.o

KVER ?= $(shell uname -r)
KBUILD ?= /lib/modules/$(KVER)/build

all:
	$(MAKE) -C $(KBUILD) M=$(CURDIR) CC=clang LLVM=1 modules

clean:
	$(MAKE) -C $(KBUILD) M=$(CURDIR) clean
