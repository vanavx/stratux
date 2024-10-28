# Copyright (c) 2016 Joseph D Poirier
# Distributable under the terms of The New BSD License
# that can be found in the LICENSE file.
# Copyright (C) 2024 Jonathan M Wilder
# Added updates to make this script function again.


BLACK=$(tput setaf 0)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
LIME_YELLOW=$(tput setaf 190)
POWDER_BLUE=$(tput setaf 153)
BLUE=$(tput setaf 4)
MAGENTA=$(tput setaf 5)
CYAN=$(tput setaf 6)
WHITE=$(tput setaf 7)
BOLD=$(tput bold)
NORMAL=$(tput sgr0)
BLINK=$(tput blink)
REVERSE=$(tput smso)
UNDERLINE=$(tput smul)
PARALLEL_JOBS=4

if [ $(whoami) != 'root' ]; then
    echo "${BOLD}${RED}This script must be executed as root, exiting...${WHITE}${NORMAL}"
    exit
fi


SCRIPTDIR="`pwd`"

#set -e

#outfile=setuplog
#rm -f $outfile

#exec > >(cat >> $outfile)
#exec 2> >(cat >> $outfile)

#### stdout and stderr to log file
#exec > >(tee -a $outfile >&1)
#exec 2> >(tee -a $outfile >&2)

#### execute the script: bash stratux-setup.sh

#### Revision numbers found via cat /proc/cpuinfo
# [Labeled Section]                                       [File]
# Dependencies                                          - stratux-setup.sh
# Hardware check                                        - stratux-setup.sh
# Setup /etc/hostapd/hostapd.conf                       - wifi-ap.sh
# Edimax WiFi check                                     - stratux-wifi.sh
# Boot config settings                                  - rpi.sh
# RPi 0/2 check to enable Edimax wifi dongle option     - rpi.sh
#
RPI0xREV=900092
RPI0yREV=900093

RPI2BxREV=a01041
RPI2ByREV=a21041

RPI3BxREV=a02082
RPI3ByREV=a22082

ODROIDC2=020b

CHIP=0000

#### unchecked
RPIBPxREV=0010
RPIAPxREV=0012
RPIBPyREV=0013

REVISION="$(cat /proc/cpuinfo | grep Revision | cut -d ':' -f 2 | xargs)"


# Processor 
# [Labeled Section]                                       [File]
# Go bootstrap compiler installation                    - stratux-setup.sh
#
ARM6L=armv6l
ARM7L=armv7l
ARM64=aarch64

MACHINE="$(uname -m)"

# Edimax WiFi dongle
EW7811Un=$(lsusb | grep EW-7811Un)


echo "${MAGENTA}"
echo "************************************"
echo "**** Stratux Setup Starting... *****"
echo "************************************"
echo "${WHITE}"

if which ntp >/dev/null; then
    ntp -q -g
fi


##############################################################
##  Stop exisiting services
##############################################################
echo
echo "${YELLOW}**** Stop exisiting services... *****${WHITE}"

service stratux stop
echo "${MAGENTA}stratux service stopped...${WHITE}"

if [ -f "/etc/init.d/stratux" ]; then
    # remove old file
    rm -f /etc/init.d/stratux
    echo "/etc/init.d/stratux file found and deleted...${WHITE}"
fi

if [ -f "/etc/init.d/hostapd" ]; then
    service hostapd stop
    echo "${MAGENTA}hostapd service found and stopped...${WHITE}"
fi

if [ -f "/etc/init.d/isc-dhcp-server" ]; then
    service isc-dhcp-server stop
    echo "${MAGENTA}isc-dhcp service found and stopped...${WHITE}"
fi

echo "${GREEN}...done${WHITE}"


##############################################################
##  Dependencies
##############################################################
echo
echo "${YELLOW}**** Installing dependencies... *****${WHITE}"

if [ "$REVISION" == "$RPI2BxREV" ] || [ "$REVISION" == "$RPI2ByREV" ]  || [ "$REVISION" == "$RPI3BxREV" ] || [ "$REVISION" == "$RPI3ByREV" ] || [ "$REVISION" == "$RPI0xREV" ] || [ "$REVISION" == "$RPI0yREV" ]; then
    apt install -y rpi-update
    rpi-update -y
fi

apt update
apt-mark hold plymouth
apt dist-upgrade -y
apt upgrade -y
apt install -y git
git config --global http.sslVerify false
apt install -y iw
apt install -y lshw
apt install -y wget
apt install -y isc-dhcp-server
apt install -y tcpdump
apt install -y cmake
# The name of this package has changed from libusb-1.0-0.dev to libusb-1.0-0-dev.
apt install -y libusb-1.0-0-dev
apt install -y build-essential
apt install -y mercurial
apt install -y autoconf
apt install -y libtool
apt install -y automake
apt remove -y hostapd
apt install -y hostapd
apt install -y pkg-config
apt install -y libncurses-dev
# python-* packages have had their name prefix changed to python3-*
apt install -y libjpeg-dev i2c-tools python3-smbus python3-pip python3-dev python3-pil python3-daemon screen
# Dependency packages for building FFTW3.
apt install -y ocaml ocamlbuild autoconf automake indent libtool
if [ "$MACHINE" == "$ARM6L" ] || [ "$MACHINE" == "$ARM7L" ]; then
# Raspberry Pi 32-bit
wget https://github.com/WiringPi/WiringPi/releases/download/3.8/wiringpi_3.8_armhf.deb
dpkg --install wiringpi_3.8_armhf.deb
elif [ "$MACHINE" == "$ARM64" ]; then
# Raspberry Pi 64-bit
wget https://github.com/WiringPi/WiringPi/releases/download/3.8/wiringpi_3.8_arm64.deb
dpkg --install wiringpi_3.8_arm64.deb
fi
# FFTW3 is no longer available on apt. Must build from source. This has been changed to clone the FFTW3 repository.
wget http://fftw.org/fftw-3.3.10.tar.gz
tar -zxf fftw-3.3.10.tar.gz
cd fftw-3.3.10
./configure
make -j $PARALLEL_JOBS
make install
cd ../
rm -rf fftw-3.3.10

#apt-get purge golang*

echo "${GREEN}...done${WHITE}"


##############################################################
##  Hardware check
##############################################################
echo
echo "${YELLOW}**** Hardware check... *****${WHITE}"

if [ "$REVISION" == "$RPI2BxREV" ] || [ "$REVISION" == "$RPI2ByREV" ]  || [ "$REVISION" == "$RPI3BxREV" ] || [ "$REVISION" == "$RPI3ByREV" ] || [ "$REVISION" == "$RPI0xREV" ] || [ "$REVISION" == "$RPI0yREV" ]; then
    echo
    echo "${MAGENTA}Raspberry Pi detected...${WHITE}"

    . ${SCRIPTDIR}/rpi.sh
elif [ "$REVISION" == "$ODROIDC2" ]; then
    echo
    echo "${MAGENTA}Odroid-C2 detected...${WHITE}"

    . ${SCRIPTDIR}/odroid.sh
elif [ "$REVISION" == "$CHIP" ]; then
    echo
    echo "${MAGENTA}CHIP detected...${WHITE}"

    . ${SCRIPTDIR}/chip.sh
else
    echo
    echo "${BOLD}${RED}WARNING - unable to identify the board using /proc/cpuinfo...${WHITE}${NORMAL}"

    #exit
fi

echo "${GREEN}...done${WHITE}"


##############################################################
##  Stratux USB devices udev rules
##############################################################
echo
echo "${YELLOW}**** Stratux USB devices udev rules to /etc/udev/rules.d/10-stratux.rules *****${WHITE}"

cat <<EOT > /etc/udev/rules.d/10-stratux.rules
SUBSYSTEMS=="usb", ATTRS{idVendor}=="1546", ATTRS{idProduct}=="01a8", SYMLINK+="ublox8"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="1546", ATTRS{idProduct}=="01a7", SYMLINK+="ublox7"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="1546", ATTRS{idProduct}=="01a6", SYMLINK+="ublox6"
SUBSYSTEMS=="usb", ATTRS{idVendor}=="067b", ATTRS{idProduct}=="2303", SYMLINK+="prolific%n"
SUBSYSTEMS=="usb", ATTRS{interface}=="Stratux Serialout", SYMLINK+="serialout%n"
EOT

echo "${GREEN}...done${WHITE}"

rm -rf /boot/firmware/stratux.conf
echo '{"UAT_Enabled": true,"OGN_Enabled": false,"DeveloperMode": false}' > /boot/firmware/stratux.conf
touch /boot/firmware/.stratux-first-boot

##############################################################
##  SSH setup and config
##############################################################
echo
echo "${YELLOW}**** SSH setup and config... *****${WHITE}"

if [ ! -d /etc/ssh/authorized_keys ]; then
    mkdir -p /etc/ssh/authorized_keys
fi

cp -n /etc/ssh/authorized_keys/root{,.bak}
cp -f ${SCRIPTDIR}/files/root /etc/ssh/authorized_keys/root
chown root.root /etc/ssh/authorized_keys/root
chmod 644 /etc/ssh/authorized_keys/root

cp -n /etc/ssh/sshd_config{,.bak}
cp -f ${SCRIPTDIR}/files/sshd_config /etc/ssh/sshd_config
rm -f /usr/share/dbus-1/system-services/fi.epitest.hostap.WPASupplicant.service

echo "${GREEN}...done${WHITE}"


##############################################################
##  Hardware blacklisting
##############################################################
echo
echo "${YELLOW}**** Hardware blacklisting... *****${WHITE}"

if ! grep -q "blacklist dvb_usb_rtl28xxu" "/etc/modprobe.d/rtl-sdr-blacklist.conf"; then
    echo blacklist dvb_usb_rtl28xxu >>/etc/modprobe.d/rtl-sdr-blacklist.conf
fi

if ! grep -q "blacklist e4000" "/etc/modprobe.d/rtl-sdr-blacklist.conf"; then
    echo blacklist e4000 >>/etc/modprobe.d/rtl-sdr-blacklist.conf
fi

if ! grep -q "blacklist rtl2832" "/etc/modprobe.d/rtl-sdr-blacklist.conf"; then
    echo blacklist rtl2832 >>/etc/modprobe.d/rtl-sdr-blacklist.conf
fi

if ! grep -q "blacklist dvb_usb_rtl2832u" "/etc/modprobe.d/rtl-sdr-blacklist.conf"; then
    echo blacklist dvb_usb_rtl2832u >>/etc/modprobe.d/rtl-sdr-blacklist.conf
fi


##############################################################
##  Go environment setup
##############################################################
echo
echo "${YELLOW}**** Go environment setup... *****${WHITE}"

# if any of the following environment variables are set in .bashrc delete them
if grep -q "export GOROOT_BOOTSTRAP=" "/root/.bashrc"; then
    line=$(grep -n 'GOROOT_BOOTSTRAP=' /root/.bashrc | awk -F':' '{print $1}')d
    sed -i $line /root/.bashrc
fi

if grep -q "export GOPATH=" "/root/.bashrc"; then
    line=$(grep -n 'GOPATH=' /root/.bashrc | awk -F':' '{print $1}')d
    sed -i $line /root/.bashrc
fi

if grep -q "export GOROOT=" "/root/.bashrc"; then
    line=$(grep -n 'GOROOT=' /root/.bashrc | awk -F':' '{print $1}')d
    sed -i $line /root/.bashrc
fi

if grep -q "export PATH=" "/root/.bashrc"; then
    line=$(grep -n 'PATH=' /root/.bashrc | awk -F':' '{print $1}')d
    sed -i $line /root/.bashrc
fi

# only add new paths
XPATH="\$PATH"
if [[ ! "$PATH" =~ "/root/go/bin" ]]; then
    XPATH+=:/root/go/bin
fi

if [[ ! "$PATH" =~ "/root/go_path/bin" ]]; then
    XPATH+=:/root/go_path/bin
fi

echo export GOROOT_BOOTSTRAP=/root/gobootstrap >>/root/.bashrc
echo export GOPATH=/root/go_path >>/root/.bashrc
echo export GOROOT=/root/go >>/root/.bashrc
echo export PATH=${XPATH} >>/root/.bashrc

export GOROOT_BOOTSTRAP=/root/gobootstrap
export GOPATH=/root/go_path
export GOROOT=/root/go
export PATH=${PATH}:/root/go/bin:/root/go_path/bin

source /root/.bashrc

echo "${GREEN}...done${WHITE}"


##############################################################
##  Go bootstrap compiler installation
##############################################################
echo
echo "${YELLOW}**** Go bootstrap compiler installtion... *****${WHITE}"

cd /root

rm -rf go/
rm -rf gobootstrap/

if [ "$MACHINE" == "$ARM6L" ] || [ "$MACHINE" == "$ARM7L" ]; then
    #### For RPi-2/3, is there any disadvantage to using the armv6l compiler?
# Updated with latest version of Go compiler
    wget https://go.dev/dl/go1.23.0.linux-armv6l.tar.gz --no-check-certificate
    tar -zxvf go1.23.0.linux-armv6l.tar.gz

    if [ ! -d /root/go ]; then
        echo "${BOLD}${RED}ERROR - go folder doesn't exist, exiting...${WHITE}${NORMAL}"
        exit
    fi

#    if [ "$MACHINE" == "$ARM6L" ]; then
#        export GOARM=6
#    else
#        export GOARM=7
#    then
elif [ "$MACHINE" == "$ARM64" ]; then
    ulimit -s 1024     # set the thread stack limit to 1mb
    # ulimit -s          # check that it worked
    env GO_TEST_TIMEOUT_SCALE=10 GOROOT_BOOTSTRAP=/root/gobootstrap
# Updated with latest version of Go compiler
    wget https://go.dev/dl/go1.23.0.linux-arm64.tar.gz --no-check-certificate
    tar -zxvf go1.23.0.linux-arm64.tar.gz
    rm go1.23.0.linux-arm64.tar.gz
    
    if [ ! -d /root/go ]; then
        echo "${BOLD}${RED}ERROR - go folder doesn't exist, exiting...${WHITE}${NORMAL}"
        exit
    fi
else
    echo
    echo "${BOLD}${RED}ERROR - unsupported machine type: $MACHINE, exiting...${WHITE}${NORMAL}"
fi

rm -f go1.*.linux*
rm -rf /root/go_path
mkdir -p /root/go_path

echo "${GREEN}...done${WHITE}"


##############################################################
##  RTL-SDR tools build
##############################################################
echo
echo "${YELLOW}**** RTL-SDR library build... *****${WHITE}"

cd /root

rm -rf librtlsdr
git clone https://github.com/steve-m/librtlsdr
cd librtlsdr
mkdir build
cd build
cmake ../
make -j $PARALLEL_JOBS
make install
ldconfig

echo "${GREEN}...done${WHITE}"


##############################################################
##  Stratux build and installation
##############################################################
echo
echo "${YELLOW}**** Stratux build and installation... *****${WHITE}"

cd /root

rm -rf stratux
# b3nn0/stratux is the new official repository
git clone https://github.com/b3nn0/stratux.git --recursive
cd stratux
git fetch --tags
tag=$(git describe --tags `git rev-list --tags --max-count=1`)
# checkout the latest release
git checkout $tag

make -j $PARALLEL_JOBS all
make install

#### minimal sanity checks
# Updated sanity check paths. Previously, gen_gdl90 and dump1090 were in /usr/bin. These files
# are now installed into /opt/stratux/bin.
if [ ! -f "/opt/stratux/bin/gen_gdl90" ]; then
    echo "${BOLD}${RED}ERROR - gen_gdl90 file missing, exiting...${WHITE}${NORMAL}"
    exit
fi

if [ ! -f "/opt/stratux/bin/dump1090" ]; then
    echo "${BOLD}${RED}ERROR - dump1090 file missing, exiting...${WHITE}${NORMAL}"
    exit
fi

echo "${GREEN}...done${WHITE}"


##############################################################
##  Kalibrate build and installation
##############################################################
echo
echo "${YELLOW}**** Kalibrate build and installation... *****${WHITE}"

cd /root

rm -rf kalibrate-rtl
git clone https://github.com/steve-m/kalibrate-rtl
cd kalibrate-rtl
./bootstrap
./configure
make -j $PARALLEL_JOBS
make install

echo "${GREEN}...done${WHITE}"


##############################################################
##  System tweaks
##############################################################
echo
echo "${YELLOW}**** System tweaks... *****${WHITE}"

##### disable serial console
if [ -f /boot/cmdline.txt ]; then
    sed -i /boot/cmdline.txt -e "s/console=ttyAMA0,[0-9]\+ //"
fi

##### Set the keyboard layout to US.
if [ -f /etc/default/keyboard ]; then
    sed -i /etc/default/keyboard -e "/^XKBLAYOUT/s/\".*\"/\"us\"/"
fi

#### allow starting services
if [ -f /usr/sbin/policy-rc.d ]; then
    rm /usr/sbin/policy-rc.d
fi

echo "${GREEN}...done${WHITE}"


#################################################
## Setup /root/.stxAliases
#################################################
echo
echo "${YELLOW}**** Setup /root/.stxAliases *****${WHITE}"

if [ -f "/root/stratux/image/stxAliases.txt" ]; then
    cp /root/stratux/image/stxAliases.txt /root/.stxAliases
else
    cp ${SCRIPTDIR}/files/stxAliases.txt /root/.stxAliases
fi

if [ ! -f "/root/.stxAliases" ]; then
    echo "${BOLD}${RED}ERROR - /root/.stxAliases file missing, exiting...${WHITE}${NORMAL}"
    exit
fi

echo "${GREEN}...done${WHITE}"


#################################################
## Add .stxAliases command to /root/.bashrc
#################################################
echo
echo "${YELLOW}**** Add .stxAliases command to /root/.bashrc *****${WHITE}"

if ! grep -q ".stxAliases" "/root/.bashrc"; then
cat <<EOT >> /root/.bashrc
if [ -f /root/.stxAliases ]; then
. /root/.stxAliases
fi
EOT
fi

echo "${GREEN}...done${WHITE}"


##############################################################
##  WiFi Access Point setup
##############################################################
echo
echo "${YELLOW}**** WiFi Access Point setup... *****${WHITE}"

. ${SCRIPTDIR}/wifi-ap.sh


##############################################################
## Copying motd file
##############################################################
echo
echo "${YELLOW}**** Copying motd file... *****${WHITE}"

cp ${SCRIPTDIR}/files/motd /etc/motd

echo "${GREEN}...done${WHITE}"

##############################################################
## Copying rc.local file
##############################################################
#echo
#echo "${YELLOW}**** Copying rc.local file... *****${WHITE}"

#chmod 755 ${SCRIPTDIR}/files/rc.local
#cp ${SCRIPTDIR}/files/rc.local /usr/bin/rc.local

#echo "${GREEN}...done${WHITE}"


##############################################################
## Copying fancontrol.py file
##############################################################
echo
echo "${YELLOW}**** Copying fancontrol.py file... *****${WHITE}"

chmod 755 ${SCRIPTDIR}/files/fancontrol.py
cp ${SCRIPTDIR}/files/fancontrol.py /usr/bin/fancontrol.py

echo "${GREEN}...done${WHITE}"


##############################################################
## Copying the hostapd_manager.sh utility
##############################################################
echo
echo "${YELLOW}**** Copying the hostapd_manager.sh utility... *****${WHITE}"

chmod 755 ${SCRIPTDIR}/files/hostapd_manager.sh
cp ${SCRIPTDIR}/files/hostapd_manager.sh /usr/bin/hostapd_manager.sh

echo "${GREEN}...done${WHITE}"


##############################################################
## Disable ntpd autostart
##############################################################
echo
echo "${YELLOW}**** Disable ntpd autostart... *****${WHITE}"

if which ntp >/dev/null; then
    systemctl disbable ntp
fi

echo "${GREEN}...done${WHITE}"


##############################################################
## Epilogue
##############################################################
echo
echo
echo "${MAGENTA}**** Setup complete, don't forget to reboot! *****${WHITE}"
echo

echo ${NORMAL}
