obj-m += medion_kbd.o

KDIR := /lib/modules/$(shell uname -r)/build
BUILD_DIR := /tmp/medion_kbd_build

all:
	rm -rf $(BUILD_DIR)
	mkdir -p $(BUILD_DIR)
	cp medion_kbd.c $(BUILD_DIR)/
	echo "obj-m += medion_kbd.o" > $(BUILD_DIR)/Makefile
	$(MAKE) -C $(KDIR) M=$(BUILD_DIR) modules
	cp $(BUILD_DIR)/medion_kbd.ko .

clean:
	rm -rf $(BUILD_DIR) medion_kbd.ko
