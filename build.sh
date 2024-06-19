#!/bin/bash
set -eux
if [ -z $1 ]; then
    echo "Usage: $0 ESXi.iso"
    exit 1
fi
if [ ! -f $1 ]; then
    echo "$1 is not a file"
    exit 1
fi

set -eux
ESXI_ISO=$1
# We use the label of the ISO image
VERSION=$(file -b ${ESXI_ISO}| cut -d"'" -f2|sed 's,ESXI-\(.*\),\1,')
BASE_DIR=$(pwd)
TMPDIR=${HOME}/tmp/${VERSION}
ESXI_MOUNT_POINT=${TMPDIR}/mount
VSHPERE_MOUNT_POINT=${TMPDIR}/vsphere
TARGET_ISO=${TMPDIR}/new

rm -f esxi-${VERSION}.yaml
rm -f esxi-${VERSION}.qcow2

mkdir -p ${ESXI_MOUNT_POINT}
mkdir -p ${TARGET_ISO}

if [[ $(df --output=fstype ${ESXI_MOUNT_POINT}| tail -n1) != "iso9660" ]]; then
    sudo mount -o loop ${ESXI_ISO} ${ESXI_MOUNT_POINT}
fi

rsync -av ${ESXI_MOUNT_POINT}/ ${TARGET_ISO}
sleep 1
sudo umount ${ESXI_MOUNT_POINT}

echo "

vmaccepteula
# You can generate using mkpasswd --method=SHA-512 --stdin
# root/root
# rootpw --iscrypted \$6\$92/5uTgSZSu4BTVR\$TSOk5JV9RWE81ZbW7tzO/bSw9jtHX/ImhAE/AEmJNJJAl27GVhFF8GeoD5Zc.9c4wJjDrawtyk0mJ7kbBP7tV1
rootpw $(uuidgen)
install --firstdisk --overwritevmfs
network --bootproto=dhcp

%post --interpreter=busybox

halt

%firstboot --interpreter=busybox

esxcfg-vmknic -d Management Network
#/sbin/firmwareConfig.sh --reset-only
rm /etc/dhclient-vmk0.leases
echo '/adv/Net/FollowHardwareMac = \"1\"' > /etc/vmware/esx.conf

cat << 'EOF' > /etc/rc.local.d/local.sh
# This is a base64 copy of
# https://github.com/goneri/esxi-cloud-init/blob/master/esxi-cloud-init.py
echo '$(curl -L -s https://raw.githubusercontent.com/goneri/esxi-cloud-init/master/esxi-cloud-init.py|base64 -)' | python -m base64 -d - > /etc/esxi-cloud-init.py

vim-cmd hostsvc/start_ssh
python /etc/esxi-cloud-init.py > /etc/esxi-cloud-init.log 2>&1
exit 0
EOF
chmod +x /etc/rc.local.d/local.sh
sh -eux /sbin/auto-backup.sh

halt

EOL" > /tmp/ks_cust.cfg
sudo cp /tmp/ks_cust.cfg ${TARGET_ISO}/ks_cust.cfg
sudo sed -i s,timeout=5,timeout=1, ${TARGET_ISO}/boot.cfg
sudo sed -i 's,\(kernelopt=.*\),\1 ks=cdrom:/KS_CUST.CFG,' ${TARGET_ISO}/boot.cfg
sudo sed -i 's,TIMEOUT 80,TIMEOUT 1,' ${TARGET_ISO}/isolinux.cfg

sudo genisoimage -relaxed-filenames -J -R -o ${TMPDIR}/new.iso -b isolinux.bin -c boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -eltorito-alt-boot -e efiboot.img -no-emul-boot ${TARGET_ISO}

sudo mv ${TARGET_ISO}.iso /var/lib/libvirt/images/
sudo chmod 644 /var/lib/libvirt/images/new.iso

nic_driver=vmxnet3
disk_size=128
echo "Deployment ongoing, you will just have to press [ENTER] at the end."
virt-install --connect qemu:///system \
	-n esxi-${VERSION}_tmp -r 4096 \
	--vcpus=sockets=1,cores=2,threads=2 \
	--cpu host --disk path=/var/lib/libvirt/images/esxi-${VERSION}_tmp.qcow2,size=${disk_size},sparse=yes,target.bus=sata \
	-c /var/lib/libvirt/images/new.iso --osinfo detect=on,require=off \
	--accelerate --network=network:default,model=${nic_driver} \
	--hvm --graphics vnc,listen=0.0.0.0 \
	--check disk_size=off
sleep 180
sudo qemu-img convert -f qcow2 -O qcow2 -c /var/lib/libvirt/images/esxi-${VERSION}_tmp.qcow2 esxi-${VERSION}.qcow2
cp default_config.yaml esxi-${VERSION}.yaml
echo "default_nic_model: e1000e" >> esxi-${VERSION}.yaml

sudo virsh undefine --remove-all-storage esxi-${VERSION}_tmp
sudo rm /var/lib/libvirt/images/new.iso

echo "You image is ready! Do use it:
    Virt-Lightning:
        sudo cp -v esxi-${VERSION}.qcow2 esxi-${VERSION}.yaml /var/lib/virt-lightning/pool/upstream/

    OpenStack:
        source ~/openrc.sh
        openstack image create --disk-format qcow2 --container-format bare --file esxi-${VERSION}.qcow2 --property hw_disk_bus=sata --property hw_cpu_policy=dedicated --property hw_cdrom_bus=ide --property hw_vif_model=e1000e --property hw_boot_menu=true --property hw_qemu_guest_agent=no --min-disk 1 --min-ram 4096 esxi-${VERSION}"
