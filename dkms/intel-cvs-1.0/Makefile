# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2024 Intel Corporation.

obj-m += intel_cvs.o
intel_cvs-y := drivers/misc/icvs/intel_cvs.o drivers/misc/icvs/intel_cvs_update.o

KERNELRELEASE ?= $(shell uname -r)
KERNEL_SRC ?= /lib/modules/$(KERNELRELEASE)/build
PWD := $(shell pwd)

ccflags-y += -I$(src)/include/

# Diagnostic sysfs surface (cmd/coredump attributes). Off by default; command
# line variables propagate into the kbuild sub-make, so `make DEBUG_CVS=1`
# enables it for bring-up builds.
ifeq ($(DEBUG_CVS),1)
ccflags-y += -DDEBUG_CVS
endif

all:
	$(MAKE) -C $(KERNEL_SRC) M=$(PWD) modules

modules_install:
	$(MAKE) INSTALL_MOD_DIR=/updates -C $(KERNEL_SRC) M=$(PWD) modules_install

clean:
	$(MAKE) -C $(KERNEL_SRC) M=$(PWD) clean
