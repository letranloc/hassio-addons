#!/bin/bash

sleep 5

# SIGTERM-handler this funciton will be executed when the container receives the SIGTERM signal (when stopping)
term_handler() {
  logger "Stopping Hass.io Access Point" 0
  ifdown $INTERFACE
  ip link set $INTERFACE down
  ip addr flush dev $INTERFACE
  exit 0
}

# Logging function to set verbosity of output to addon log
logger() {
  msg=$1
  level=$2
  if [ $DEBUG -ge $level ]; then
    echo $msg
  fi
}

CONFIG_PATH=/data/options.json

SSID=$(jq --raw-output ".ssid" $CONFIG_PATH)
WPA_PASSPHRASE=$(jq --raw-output ".wpa_passphrase" $CONFIG_PATH)
CHANNEL=$(jq --raw-output ".channel" $CONFIG_PATH)
ADDRESS=$(jq --raw-output ".address" $CONFIG_PATH)
NETMASK=$(jq --raw-output ".netmask" $CONFIG_PATH)
BROADCAST=$(jq --raw-output ".broadcast" $CONFIG_PATH)
INTERFACE=$(jq --raw-output ".interface" $CONFIG_PATH)
HIDE_SSID=$(jq --raw-output ".hide_ssid" $CONFIG_PATH)
DHCP=$(jq --raw-output ".dhcp" $CONFIG_PATH)
DHCP_START_ADDR=$(jq --raw-output ".dhcp_start_addr" $CONFIG_PATH)
DHCP_END_ADDR=$(jq --raw-output ".dhcp_end_addr" $CONFIG_PATH)
ALLOW_MAC_ADDRESSES=$(jq --raw-output '.allow_mac_addresses | join(" ")' $CONFIG_PATH)
DENY_MAC_ADDRESSES=$(jq --raw-output '.deny_mac_addresses | join(" ")' $CONFIG_PATH)
DEBUG=$(jq --raw-output '.debug' $CONFIG_PATH)
HOSTAPD_CONFIG_OVERRIDE=$(jq --raw-output '.hostapd_config_override | join(" ")' $CONFIG_PATH)

# Enforces required env variables
required_vars=(SSID WPA_PASSPHRASE CHANNEL ADDRESS NETMASK BROADCAST)
for required_var in "${required_vars[@]}"; do
  if [[ -z ${!required_var} ]]; then
    error=1
    echo >&2 "Error: $required_var env variable not set."
  fi
done

# Sanitise config value for hide_ssid
if [ $HIDE_SSID -ne 1 ]; then
  HIDE_SSID=0
fi

# Sanitise config value for dhcp
if [ $DHCP -ne 1 ]; then
  DHCP=0
fi

if [[ -n $error ]]; then
  exit 1
fi

# Setup hostapd.conf
logger "# Setup hostapd:" 1
logger "Add to hostapd.conf: ssid=$SSID" 1
echo "ssid=$SSID"$'\n' >>/etc/hostapd/hostapd.conf
logger "Add to hostapd.conf: wpa_passphrase=********" 1
echo "wpa_passphrase=$WPA_PASSPHRASE"$'\n' >>/etc/hostapd/hostapd.conf
logger "Add to hostapd.conf: channel=$CHANNEL" 1
echo "channel=$CHANNEL"$'\n' >>/etc/hostapd/hostapd.conf
logger "Add to hostapd.conf: ignore_broadcast_ssid=$HIDE_SSID" 1
echo "ignore_broadcast_ssid=$HIDE_SSID"$'\n' >>/etc/hostapd/hostapd.conf

### MAC address filtering
## Allow is more restrictive, so we prioritise that and set
## macaddr_acl to 1, and add allowed MAC addresses to hostapd.allow
if [ ${#ALLOW_MAC_ADDRESSES} -ge 1 ]; then
  logger "Add to hostapd.conf: macaddr_acl=1" 1
  echo "macaddr_acl=1"$'\n' >>/etc/hostapd/hostapd.conf
  ALLOWED=($ALLOW_MAC_ADDRESSES)
  logger "# Setup hostapd.allow:" 1
  logger "Allowed MAC addresses:" 0
  for mac in "${ALLOWED[@]}"; do
    echo "$mac"$'\n' >>/etc/hostapd/hostapd.allow
    logger "$mac" 0
  done
  logger "Add to hostapd.conf: accept_mac_file=/etc/hostapd/hostapd.allow" 1
  echo "accept_mac_file=/etc/hostapd/hostapd.allow"$'\n' >>/etc/hostapd/hostapd.conf
  ## else set macaddr_acl to 0, and add denied MAC addresses to hostapd.deny
else
  if [ ${#DENY_MAC_ADDRESSES} -ge 1 ]; then
    logger "Add to hostapd.conf: macaddr_acl=0" 1
    echo "macaddr_acl=0"$'\n' >>/etc/hostapd/hostapd.conf
    DENIED=($DENY_MAC_ADDRESSES)
    logger "Denied MAC addresses:" 0
    for mac in "${DENIED[@]}"; do
      echo "$mac"$'\n' >>/etc/hostapd/hostapd.deny
      logger "$mac" 0
    done
    logger "Add to hostapd.conf: accept_mac_file=/etc/hostapd/hostapd.deny" 1
    echo "deny_mac_file=/etc/hostapd/hostapd.deny"$'\n' >>/etc/hostapd/hostapd.conf
    # else set macaddr_acl to 0, with blank allow and deny files
  else
    logger "Add to hostapd.conf: macaddr_acl=0" 1
    echo "macaddr_acl=0"$'\n' >>/etc/hostapd/hostapd.conf
  fi
fi

# Add interface to hostapd.conf
logger "Add to hostapd.conf: interface=$INTERFACE" 1
echo "interface=$INTERFACE"$'\n' >>/etc/hostapd/hostapd.conf

# Append override options to hostapd.conf
if [ ${#HOSTAPD_CONFIG_OVERRIDE} -ge 1 ]; then
  logger "# Custom hostapd config options:" 0
  HOSTAPD_OVERRIDES=($HOSTAPD_CONFIG_OVERRIDE)
  for override in "${HOSTAPD_OVERRIDES[@]}"; do
    echo "$override"$'\n' >>/etc/hostapd/hostapd.conf
    logger "Add to hostapd.conf: $override" 0
  done
fi

ip link set $INTERFACE down

iptables-nft -t nat -C POSTROUTING -o eth0 -j MASQUERADE || iptables-nft -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables-nft -C FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT || iptables-nft -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables-nft -C FORWARD -i wlan0 -o eth0 -j ACCEPT || iptables-nft -A FORWARD -i wlan0 -o eth0 -j ACCEPT

iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT

iptables-save | tee /etc/iptables/rules.v4

ip link set $INTERFACE up

# Setup dnsmasq.conf if DHCP is enabled in config
if [ $DHCP -eq 1 ]; then
  logger "# DHCP enabled. Setup dnsmasq:" 1
  cat >"/etc/dnsmasq.d/090_wlan0.conf" <<EOF
domain-needed
interface=${INTERFACE}
dhcp-range=${DHCP_START_ADDR},${DHCP_END_ADDR},${NETMASK},12h
dhcp-option=6,8.8.8.8,8.8.4.4
EOF

  logger "# DHCP enabled. Setup dhcpcd:" 1
  cat >"/etc/dhcpcd.conf" <<EOF
hostname
clientid
persistent
option rapid_commit
option domain_name_servers, domain_name, domain_search, host_name
option classless_static_routes
option ntp_servers
require dhcp_server_identifier
slaac private
nohook lookup-hostname
interface wlan0
metric 
static ip_address=${ADDRESS}/24
static routers=${ADDRESS}
static domain_name_server=${ADDRESS}
EOF
else
  logger "# DHCP not enabled. Skipping dnsmasq/dhcpcd" 1
fi

/bin/bash /etc/raspap/hostapd/servicestart.sh --interface wlan --seconds 3

service procps start
service lighttpd start

touch /tmp/hostapd.log
tail -f /tmp/hostapd.log
