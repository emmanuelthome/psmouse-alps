#!/bin/sh

if [ "$(id -u)" != "0" ]; then
	echo "This script must be run as root"
	exit 1;
fi

if [ $# -ne 1 ]; then
	echo "Usage $0 (0|1)"
	exit 1
fi

case $1 in
0)
	mode="psmouse"
	;;
1)
	mode="serio_raw"
	;;
*)
	echo "Usage $0 (0|1)"
	exit 1
	;;
esac

modprobe serio_raw
for f in /sys/bus/serio/devices/serio*; do
	cat ${f}/description | grep "i8042 AUX" > /dev/null
	if [ $? -eq 0 ]; then
		echo -n $mode > ${f}/drvctl
		exit 0
	fi
done

echo "PS/2 mouse not found"
exit 1
