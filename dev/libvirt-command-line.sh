#!/bin/bash

F=$(ls /dev/serio_raw* 2>/dev/null)
if ! [ "$F" ] ; then
    echo "No /dev/serio_rawX device. Run ./mouse-to-serio.sh 1 first ?"
    exit 1
fi
export PSMOUSE_SERIO_DEV_PATH=$F
export PSMOUSE_SERIO_LOG_PATH=/tmp/log
/usr/bin/kvm	\
	-name windows	\
	-M pc-1.2	\
	-enable-kvm	\
	-m 1024	\
	-smp 1,sockets=1,cores=1,threads=1	\
	-uuid 6b9a02b1-4dcb-040f-61b4-f55cd1af2fe5	\
	-no-user-config	\
	-nodefaults	\
	-rtc base=localtime	\
	-no-shutdown	\
	-device piix3-usb-uhci,id=usb,bus=pci.0,addr=0x1.0x2	\
	-drive file=/var/lib/libvirt/images/windows.img,if=none,id=drive-ide0-0-0,format=raw	\
	-device ide-hd,bus=ide.0,unit=0,drive=drive-ide0-0-0,id=ide0-0-0,bootindex=1	\
	-chardev pty,id=charserial0	\
	-device isa-serial,chardev=charserial0,id=serial0	\
	-device usb-tablet,id=input0	\
	-display sdl	\
	-vga std \
	-device virtio-balloon-pci,id=balloon0,bus=pci.0,addr=0x5
