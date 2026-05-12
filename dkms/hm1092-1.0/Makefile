obj-m += hm1092.o

KVER ?= $(shell uname -r)
KBUILD ?= /lib/modules/$(KVER)/build

all:
	$(MAKE) -C $(KBUILD) M=$(CURDIR) CC=clang LLVM=1 modules

clean:
	$(MAKE) -C $(KBUILD) M=$(CURDIR) clean

# NEVER run depmod or install to /lib/modules — use insmod ./hm1092.ko only
