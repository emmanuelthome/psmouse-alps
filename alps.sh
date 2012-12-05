#!/bin/bash
# -*-shell-script-*-
# $Id: alps.sh 712 2012-09-21 03:27:40Z dturvene $
#
# Alps touchpad driver analysis
#
# http://www.spinics.net/lists/linux-input/msg21993.html
# https://bugs.launchpad.net/ubuntu/+source/linux/+bug/606238
#
# Qemu reverse engineer
#  http://swapspace.forshee.me/2011/11/touchpad-protocol-reverse-engineering.html
# 
# Qemu DSDT PS2 work 
#  https://patchwork.kernel.org/patch/1319071/
#  http://acpi.sourceforge.net/dsdt/
#
# Ben Gamari (bgarami.foss@gmail.com) work on the Dell E6430
#  https://github.com/bgamari/linux/tree/alps

# for build/install the psmouse/alps driver
DLKM=alps-dst-0.3
KERN=$(uname -r)

# for Qemu reverse engineering
dev_serio="/dev/serio_raw0"
guest_img="v3.img"

# Runtime control of psmouse/alps driver
ID_TP=$(xinput --list | grep "AlpsPS/2" | sed -e 's/.*id=\([1-9]\+\).*/\1/')

EXECFUNCS=""

######################## Support Functions ################

a_parseargs() {

    # if no argument, set to usage
    EXECFUNCS=${1:-a_usage}
}

a_usage() {

    printf "\nUsage: $0 func [func]+"
    printf "\n  Valid funcs:\n"

    typeset -F | sed -e 's/declare -f \(.*\)/\t\1/'
}

######################### ALPS DKMS #####################
function dkms_install_cp() {

    echo "Test for existence, if none copy to /usr/src"
    if ! [ -f /usr/src/psmouse-$DLKM ]; then
        echo "copy $HOME/svn_psmouse to /usr/src/psmouse-$DLKM"
        sudo cp -vupr $HOME/svn_psmouse /usr/src/psmouse-$DLKM
    fi

}

function dkms_install_symlink() {

    echo "Alternative to make a symlink; this can cause build confusion but"
    echo "is useful for rapid devel"

    echo "Test for existence of a file or symbolic link"
    if ! ([ -f /usr/src/psmouse-$DLKM ] || [ -h /usr/src/psmouse-$DLKM ]); then
        echo "Linking $HOME/svn_psmouse to /usr/src/psmouse-$DLKM"
        sudo ln -s $HOME/svn_psmouse /usr/src/psmouse-$DLKM
    fi
}

function dkms_build_alps() {

    echo "/usr/src/psmouse-$DLKM/dkms.conf must have PACKAGE_VERSION set to $DLKM"
    sudo dkms remove psmouse/$DLKM --all

    echo "/usr/src/psmouse-$DLKM/dkms.conf must have PACKAGE_VERSION set to $DLKM"
    echo "This places the psmouse.ko dlkm in /lib/modules/$KERN/updates/dkms"
    sudo dkms build psmouse/$DLKM

    if [[ $? == 0 ]]; then
        sudo dkms install psmouse/$DLKM
        sudo rmmod -v psmouse
        sudo modprobe -v psmouse
    else
        printf "Build failed\n"
        cat /var/lib/dkms/psmouse/$DLKM/build/make.log
    fi
    
}

function dkms_pkg_tarball() {
    echo "create a tarball with bz2 compression, exclude version control files"
    tar --exclude-vcs -jhcvf  $HOME/psmouse-$DLKM.tbz /usr/src/psmouse-$DLKM

    echo "list contents of tbz" 
    tar -jtvf $HOME/psmouse-$DLKM.tbz

    # echo expand tbz into the current directory
    # tar -jxvf $HOME/psmouse-$DLKM.tbz
}

######################### qemu environment ################

function qemu_make() {

  cd /opt/distros/Qemu/qemu-1.1.1
  ./configure --enable-debug --target-list=x86_64-softmmu
  make V=1 > make.$(date +%y%m%d) 2>&1

  echo "Installs in /usr/local: bin, share/qemu, etc/qemu"
  sudo make install
}

function qemu_create() {
    
  echo "must build qemu before this: qemu_make"

  echo "check cpu support for each processor"
  egrep "flags.*:.*(svm|vmx)" /proc/cpuinfo


  # See https://help.ubuntu.com/community/Installation/QemuEmulator
  # echo "Create an initial virtual img - 16G is enough to run vista"
  # echo "  if need more use qemu_grow_img"
  # qemu-img create $guest_img 16G
  # echo "Boot from iso and install to img, only need to do this once"
  # qemu-system-x86_64 -m 2048 -cdrom vista32.iso -hda $guest_img -boot d
  # echo "once install, reboot to make sure things work"
  # qemu-system-x86_64 -m 1024 -hda $guest_img

}

function qemu_run() {

  echo "Must create image and install guest-os: qemu_create"
  echo "for alps reverse engineering must update bios: qemu_bios"

  echo "Setup serio device, hacked from mouse-to-serio.sh"
  echo "Should be the i8042 AUX port"; cat /sys/bus/serio/devices/serio1/description
  echo "WARNING: This creates $dev_serio, now must use a usb mouse"
  sudo sh -c 'echo -n "serio_raw" > /sys/bus/serio/devices/serio1/drvctl'
  # echo "switch back"
  # echo -n "psmouse" > /sys/bus/serio/devices/serio1/drvctl

  echo "Make $dev_serio globally read/write to run qemu"
  sudo chmod go+rw $dev_serio

  export PSMOUSE_SERIO_DEV_PATH=$dev_serio
  export PSMOUSE_SERIO_LOG_PATH=./cap2.txt
  echo $PSMOUSE_SERIO_DEV_PATH $PSMOUSE_SERIO_LOG_PATH

  echo "cp vista.iso and alps drivers here"
  cd /opt/distros/Qemu

  echo "Boot from image; Check pc-bios/bios.bin is updated"
  # nice -10 qemu-system-x86_64 -m 2048 -hda $guest_img -L mybios
  # nice -10 qemu-1.1.1/x86_64-softmmu/qemu-system-x86_64 -m 1500 -hda v5.img -L mybios
  qemu-system-x86_64 -m 1500 -hda v5.img -chardev stdio,id=seabios -device isa-debugcon,iobase=0x402,chardev=seabios
}

function qemu_add_driver() {

  echo "add alps driver file to $guest_img"
  echo "use fdisk to get the offset, Units*Start = 512*2048 = 1048576"
  fdisk -u -l $guest_img

  echo "Mount image on loop device to a good mount point"
  sudo mount -o loop,offset=1048576 $guest_img /mnt/loop

  echo "Make sure I can access image"
  ls -l /mnt/loop/Users/dave

  # http://www.dell.com/support/drivers/us/en/19/ServiceTag/8R0NLR1?s=dhs&~ck=mna
  # R305170.exe (10MB) - 6/7/2011 7.1209.101.2 04, A04
  echo "copy alps drivers to image"
  cp R305170.exe /mnt/loop/Users/dave/Documents

  echo "unmount loop device and check that /dev/loop is released"
  sudo umount /mnt/loop
  sudo losetup -f

  echo "start up, login and install driver"
  echo "While driver is being install, keep other activities to a minimum"
  qemu_run
}

function qemu_grow_img() {

    echo "Grow qemu $guest_img by 4G"
    qemu-img info $guest_img
    truncate --size=+4G $guest_img
}


function qemu_update_bios() {
  echo "must run/test qemu_make first"

  echo "edit src/acpi-dsdt.dsl using qemu patch as basis"
  echo "The PS2M device for N5110 is DLL04B0"
  cd /opt/distros/Qemu/qemu-1.1.1/roms/seabios
  echo "Then compile acpi-dsdt.dsl to acpi-dsdt.hex"
  echo "This dynamically builds .config"
  make V=1 src/acpi-dsdt.hex
  echo "jump up to roms and make the bios"
  echo "which makes ./pc-bios/bios.bin, see seabios/out/ccode32flat.o.tmp.c"
  cd ..
  make V=1 bios
  echo "cp the bios to the install directory"
  cp -vup ../pc-bios/bios.bin /opt/distro/Qemu/mybios

  echo "should not have to rebuild"
}

############################## runtime control #######################

# Function to retrieve the touchpad hardware model from BIOS
# Dell N5110: DLL04B0
# James says Dell E6230: DLL0532
function run_dsdt_get() {

    echo "Suck out the ACPI DSDT"
    if [ 1 ]; then
        sudo sh -c "cat /sys/firmware/acpi/tables/DSDT > DSDT.aml"
    else 
        sudo acpidump -b -t DSDT -o DSDT.aml
    fi

    echo "Create DSDT.dsl"
    iasl -d DSDT.aml
}

function run_alps_debug() {

    echo "Toggle alps_debug on/off. View output in /var/log/kern.log.  See man:syslogd to configure"
    echo "Set lvl=1 for control debug (default), lvl=7 for deep debug"
    lvl=1
    prm_file=/sys/module/psmouse/parameters/alps_debug

    if [ $(cat $prm_file) == "0" ]; then
        echo "Enable alps_debug"
        sudo sh -c "echo $lvl > $prm_file"
    else
        echo "Disable alps_debug"
        sudo sh -c "echo 0 > $prm_file"
    fi

    cat $prm_file
}

# smattering of support tools, not particularly helpful so far
function run_tp_diags() {

    echo "Show all input devices, also see man:lsinput"
    cat /proc/bus/input/devices

    echo "Not sure what this does - connects but times out with no output"
    sudo lsinput
    sudo input-events 13

    echo "show X device property changes - looks like "
    xinput watch-props $TP_ID

    echo "to get touchpad events"
    xev

}

function run_tp_check() {
    echo "Check tp sanity"

    echo "print info about psmouse mod"
    modinfo psmouse

    ID_TP=$(xinput --list | grep "AlpsPS/2" | sed -e 's/.*id=\([1-9]\+\).*/\1/')
    echo "Alps is on id=$ID_TP"

    echo "Device enabled should be 1"
    xinput --list-props $ID_TP | grep "Device Enabled"
}

function run_tune_alps() {
   echo "Support functions tuning the Alps touchpad"
   echo "See man:synaptics for some value meanings"

   echo "make sure this guy is enabled"
   xinput set-prop $ID_TP 132 1

   echo "Get the Velocity Scaling property and set it to a faster value"
   CSPD=$(xinput list-props $ID_TP | grep "Velocity Scaling" | sed -e 's/.*(\([0-9]\+\)).*/\1/')
   xinput set-prop $ID_TP $CSPD 40

   # Multi-touch pulled from internet, have not tested
   # xinput --set-prop --type=int --format=32 15 "Synaptics Two-Finger Pressure" 125
   # xinput --set-prop --type=int --format=32 15 "Synaptics Two-Finger Width" 0
   # xinput --set-prop --type=int --format=8  15 "Synaptics Two-Finger Scrolling" 1 1

   echo "enable edge scrolling for virt only"
   ES=$(xinput list-props $ID_TP | grep "Edge Scrolling" | sed -e 's/.*(\([0-9]\+\)).*/\1/')
   xinput set-prop $ID_TP --type=int $ES 1 0 0
   xinput list-props $ID_TP | grep $ES

   echo "X/Y origin is upper left corner and grows to lower right corner"
   echo "values: left right top bottom.  original 150 920 150 650"
   xinput set-prop --type=int $ID_TP "Synaptics Edges" 40 1200 40 650
   xinput list-props $ID_TP | grep "Synaptics Edges"
}

a_parseargs $*

for func in $EXECFUNCS
do
    # echo "execute $func"
    eval $func
done

exit 0