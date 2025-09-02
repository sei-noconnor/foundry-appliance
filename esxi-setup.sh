#!/bin/bash -e
#
# esxi-setup.sh [esxi ip address]
#
# Adds 'esxi.foundry.local' hostname for VMware ESXi server and
# installs Foundry Appliance TLS certificate and key into the same server
#

HOSTS_FILE=/etc/hosts
ESXI_USER=root
ESXI_HOSTNAME=esxi.foundry.local
ESXI_CERTDIR=/etc/vmware/ssl
RUI_CRT=$(cat certs/host.pem certs/int-ca.pem)
RUI_KEY=$(<certs/host-key.pem)
APPLIANCE_IP=$(ip route get 1 | sed -n 's/^.*src \([0-9.]*\) .*$/\1/p')
TOPOMOJO_PV=$(kubectl get pvc topomojo-nfs --output=jsonpath='{.spec.volumeName}')

if [[ ! $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo -e "\nUsage: $0 [esxi ip address]\n"
  exit 1
fi

echo -e "\n*** If prompted, type your SUDO password. ***\n"

if grep -q "$ESXI_HOSTNAME" $HOSTS_FILE; then
  sudo sed -i -r "s/.*($ESXI_HOSTNAME)/$1 \1/" $HOSTS_FILE
  echo -e "\n$ESXI_HOSTNAME ($1) updated in $HOSTS_FILE"
else
  echo "$1 $ESXI_HOSTNAME" | sudo tee -a $HOSTS_FILE > /dev/null
  echo -e "\n$ESXI_HOSTNAME ($1) added to $HOSTS_FILE"
fi

sudo systemctl restart dnsmasq
echo -e "\ndnsmasq restarted."

echo -e "\n*** If prompted, type your ESXi $ESXI_USER password. ***\n"

ssh $ESXI_USER@$1 << EOF
  esxcli storage nfs41 add -H $APPLIANCE_IP -v iso -s /export/$TOPOMOJO_PV

  if [ ! -f "$ESXI_CERTDIR/rui.crt.orig" ]; then
    cp $ESXI_CERTDIR/rui.crt $ESXI_CERTDIR/rui.crt.orig
  fi
  echo "$RUI_CRT" > $ESXI_CERTDIR/rui.crt
  
  if [ ! -f "$ESXI_CERTDIR/rui.key.orig" ]; then
    cp $ESXI_CERTDIR/rui.key $ESXI_CERTDIR/rui.key.orig
  fi
  echo "$RUI_KEY" > $ESXI_CERTDIR/rui.key

  /etc/init.d/hostd restart
  /etc/init.d/vpxa restart
EOF

echo -e "\nESXi setup completed for $ESXI_HOSTNAME\n"