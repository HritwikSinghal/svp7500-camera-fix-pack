obj-m += ov05c10.o

KVER ?= $(shell uname -r)
KBUILD ?= /lib/modules/$(KVER)/build

all:
	$(MAKE) -C $(KBUILD) M=$(CURDIR) CC=clang LLVM=1 modules

clean:
	$(MAKE) -C $(KBUILD) M=$(CURDIR) clean
