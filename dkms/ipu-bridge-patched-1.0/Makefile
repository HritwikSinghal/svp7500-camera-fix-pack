obj-m += ipu-bridge.o

KVER ?= $(shell uname -r)
KBUILD ?= /lib/modules/$(KVER)/build

all:
	$(MAKE) -C $(KBUILD) M=$(CURDIR) CC=clang LLVM=1 modules

clean:
	$(MAKE) -C $(KBUILD) M=$(CURDIR) clean
