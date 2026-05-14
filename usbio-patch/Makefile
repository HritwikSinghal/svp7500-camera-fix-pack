obj-m := usbio.o

KDIR := /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

# Compiler flags are passed by install.sh on the outer make command line
# (CC=clang LLVM=1 on clang-built kernels, nothing on gcc kernels).
# Don't hardcode them here — recursive sub-make's command-line vars beat
# the outer override, which made the standalone build fail on gcc kernels.
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
