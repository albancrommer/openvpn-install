#!/bin/bash
#
# https://github.com/Nyr/openvpn-install
#
# Copyright (c) 2013 Nyr. Released under the MIT License.


# Detect Debian users running the script with "sh" instead of bash
if readlink /proc/$$/exe | grep -q "dash"; then
    echo "This script needs to be run with bash, not sh"
    exit
fi

if [[ "$EUID" -ne 0 ]]; then
    echo "Sorry, you need to run this as root"
    exit
fi

if [[ ! -e /dev/net/tun ]]; then
    echo "The TUN device is not available
You need to enable TUN before running this script"
    exit
fi

if [[ -e /etc/debian_version ]]; then
    OS=debian
    GROUPNAME=nogroup
    RCLOCAL='/etc/rc.local'
elif [[ -e /etc/centos-release || -e /etc/redhat-release ]]; then
    OS=centos
    GROUPNAME=nobody
    RCLOCAL='/etc/rc.d/rc.local'
else
    echo "Looks like you aren't running this installer on Debian, Ubuntu or CentOS"
    exit
fi

APP_PATH=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

# set some variables that can be overriden in the config.sh file
# DO NOT CHANGE THESE PARAMETERS IF YOU DON'T KNOW WHAT YOU'RE DOING
IP_LOCAL_BASE=10.8.0.0
IP_LOCAL_RANGE=255.255.255.0
IP_LOCAL_DNS=10.8.0.1
IP_RANGE=24
DEV=tun

# if a config.sh is available in the same directory, use it
CONF_PATH="${APP_PATH}/config.sh"
if [ -f "$CONF_PATH" ] ; then 
    echo "Using provided $CONF_PATH file"
    source "$CONF_PATH"
fi

newclient () {
    # Generates the custom client.ovpn

    cp /etc/openvpn/client-common.txt "$2"
    echo "<ca>" >> "$2"
    cat /etc/openvpn/easy-rsa/pki/ca.crt >> "$2"
    echo "</ca>" >> "$2"
    echo "<cert>" >> "$2"
    cat /etc/openvpn/easy-rsa/pki/issued/$1.crt >> "$2"
    echo "</cert>" >> "$2"
    echo "<key>" >> "$2"
    cat /etc/openvpn/easy-rsa/pki/private/$1.key >> "$2"
    echo "</key>" >> "$2"
    echo "<tls-auth>" >> "$2"
    cat /etc/openvpn/ta.key >> "$2"
    echo "</tls-auth>" >> "$2"
}

if [[ -e /etc/openvpn/server.conf ]]; then
    while :
    do
    clear
        echo "Looks like OpenVPN is already installed."
        echo
        echo "What do you want to do?"
        echo "   1) Add a new user"
        echo "   2) Revoke an existing user"
        echo "   3) Remove OpenVPN"
        echo "   4) Exit"
        read -p "Select an option [1-4]: " option
        case $option in
            1)
            echo
            echo "Tell me a name for the client certificate."
            echo "Please, use one word only, no special characters."
            read -p "Client name: " -e CLIENT
            cd /etc/openvpn/easy-rsa/
            EASYRSA_CERT_EXPIRE=3650 ./easyrsa build-client-full $CLIENT nopass
            # Generates the custom client.ovpn
            newclient "$CLIENT"
            echo
            echo "Client $CLIENT added, configuration is available at:" ~/"$CLIENT.ovpn"
            exit
            ;;
            2)
            # This option could be documented a bit better and maybe even be simplified
            # ...but what can I say, I want some sleep too
            NUMBEROFCLIENTS=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep -c "^V")
            if [[ "$NUMBEROFCLIENTS" = '0' ]]; then
                echo
                echo "You have no existing clients!"
                exit
            fi
            echo
            echo "Select the existing client certificate you want to revoke:"
            tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | nl -s ') '
            if [[ "$NUMBEROFCLIENTS" = '1' ]]; then
                read -p "Select one client [1]: " CLIENTNUMBER
            else
                read -p "Select one client [1-$NUMBEROFCLIENTS]: " CLIENTNUMBER
            fi
            CLIENT=$(tail -n +2 /etc/openvpn/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | sed -n "$CLIENTNUMBER"p)
            echo
            read -p "Do you really want to revoke access for client $CLIENT? [y/N]: " -e REVOKE
            if [[ "$REVOKE" = 'y' || "$REVOKE" = 'Y' ]]; then
                cd /etc/openvpn/easy-rsa/
                ./easyrsa --batch revoke $CLIENT
                EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
                rm -f pki/reqs/$CLIENT.req
                rm -f pki/private/$CLIENT.key
                rm -f pki/issued/$CLIENT.crt
                rm -f /etc/openvpn/crl.pem
                cp /etc/openvpn/easy-rsa/pki/crl.pem /etc/openvpn/crl.pem
                # CRL is read with each client connection, when OpenVPN is dropped to nobody
                chown nobody:$GROUPNAME /etc/openvpn/crl.pem
                echo
                echo "Certificate for client $CLIENT revoked!"
            else
                echo
                echo "Certificate revocation for client $CLIENT aborted!"
            fi
            exit
            ;;
            3)
            echo
            read -p "Do you really want to remove OpenVPN? [y/N]: " -e REMOVE
            if [[ "$REMOVE" = 'y' || "$REMOVE" = 'Y' ]]; then
                PORT=$(grep '^port ' /etc/openvpn/server.conf | cut -d " " -f 2)
                PROTOCOL=$(grep '^proto ' /etc/openvpn/server.conf | cut -d " " -f 2)
                if pgrep firewalld; then
                    IP=$(firewall-cmd --direct --get-rules ipv4 nat POSTROUTING | grep '\-s $IP_LOCAL_BASE/$IP_RANGE '"'"'!'"'"' -d $IP_LOCAL_BASE/$IP_RANGE -j SNAT --to ' | cut -d " " -f 10)
                    # Using both permanent and not permanent rules to avoid a firewalld reload.
                    firewall-cmd --zone=public --remove-port=$PORT/$PROTOCOL
                    firewall-cmd --zone=trusted --remove-source=$IP_LOCAL_BASE/$IP_RANGE
                    firewall-cmd --permanent --zone=public --remove-port=$PORT/$PROTOCOL
                    firewall-cmd --permanent --zone=trusted --remove-source=$IP_LOCAL_BASE/$IP_RANGE
                    firewall-cmd --direct --remove-rule ipv4 nat POSTROUTING 0 -s $IP_LOCAL_BASE/$IP_RANGE -j SNAT --to $IP
                    firewall-cmd --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s $IP_LOCAL_BASE/$IP_RANGE -j SNAT --to $IP
                else
                    IP=$(grep 'iptables -t nat -A POSTROUTING -s $IP_LOCAL_BASE/$IP_RANGE -j SNAT --to ' $RCLOCAL | cut -d " " -f 14)
                    iptables -t nat -D POSTROUTING -s $IP_LOCAL_BASE/$IP_RANGE -j SNAT --to $IP
                    sed -i '/iptables -t nat -A POSTROUTING -s 10.8.0.0\/24 ! -d 10.8.0.0\/24 -j SNAT --to /d' $RCLOCAL
                    if iptables -L -n | grep -qE '^ACCEPT'; then
                        iptables -D INPUT -p $PROTOCOL --dport $PORT -j ACCEPT
                        iptables -D FORWARD -s $IP_LOCAL_BASE/$IP_RANGE -j ACCEPT
                        iptables -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
                        sed -i "/iptables -I INPUT -p $PROTOCOL --dport $PORT -j ACCEPT/d" $RCLOCAL
                        sed -i "/iptables -I FORWARD -s 10.8.0.0\/24 -j ACCEPT/d" $RCLOCAL
                        sed -i "/iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT/d" $RCLOCAL
                    fi
                fi
                if sestatus 2>/dev/null | grep "Current mode" | grep -q "enforcing" && [[ "$PORT" != '1194' ]]; then
                    semanage port -d -t openvpn_port_t -p $PROTOCOL $PORT
                fi
                if [[ "$OS" = 'debian' ]]; then
                    apt-get remove --purge -y openvpn
                else
                    yum remove openvpn -y
                fi
                rm -rf /etc/openvpn
                rm -f /etc/sysctl.d/30-openvpn-forward.conf
                echo
                echo "OpenVPN removed!"
            else
                echo
                echo "Removal aborted!"
            fi
            exit
            ;;
            4) exit;;
        esac
    done
else
    clear
    echo 'Welcome to this OpenVPN "road warrior" installer!'
    echo
    # OpenVPN setup and first user creation
    echo "I need to ask you a few questions before starting the setup."
    echo "You can leave the default options and just press enter if you are ok with them."
    echo
    echo "First, provide the IPv4 address of the network interface you want OpenVPN"
    echo "listening to."
    # Autodetect IP address and pre-fill for the user
    IP=$(ip addr | grep 'inet' | grep -v inet6 | grep -vE '127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1)
    read -p "IP address: " -e -i $IP IP
    # If $IP is a private IP address, the server must be behind NAT
    if echo "$IP" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
        echo
        echo "This server is behind NAT. What is the public IPv4 address or hostname?"
        read -p "Public IP address / hostname: " -e PUBLICIP
    fi
    echo
    echo "Which protocol do you want for OpenVPN connections?"
    echo "   1) UDP (recommended)"
    echo "   2) TCP"
    read -p "Protocol [1-2]: " -e -i 1 PROTOCOL
    case $PROTOCOL in
        1)
        PROTOCOL=udp
        ;;
        2)
        PROTOCOL=tcp
        ;;
    esac
    echo
    echo "What port do you want OpenVPN listening to?"
    read -p "Port: " -e -i 1194 PORT
    echo
    echo "Which DNS do you want to use with the VPN?"
    echo "   1) Current system resolvers"
    echo "   2) 1.1.1.1"
    echo "   3) Google"
    echo "   4) OpenDNS"
    echo "   5) Verisign"
    read -p "DNS [1-5]: " -e -i 1 DNS
    echo
    echo "Finally, tell me your name for the client certificate."
    echo "Please, use one word only, no special characters."
    read -p "Client name: " -e -i client CLIENT
    echo
    echo "Okay, that was all I needed. We are ready to set up your OpenVPN server now."
    read -n1 -r -p "Press any key to continue..."
    if [[ "$OS" = 'debian' ]]; then
        apt-get update
        apt-get install curl openvpn iptables openssl ca-certificates dnsmasq -y
    else
        # Else, the distro is CentOS
        yum install epel-release -y
        yum install curl openvpn iptables openssl ca-certificates dnsmasq -y
    fi

    # Get easy-rsa
    echo
    echo "Installing Easy RSA"
    echo
    EASYRSAURL='https://github.com/OpenVPN/easy-rsa/releases/download/v3.0.5/EasyRSA-nix-3.0.5.tgz'
    wget -O ~/easyrsa.tgz "$EASYRSAURL" 2>/dev/null || curl -Lo ~/easyrsa.tgz "$EASYRSAURL"
    tar xzf ~/easyrsa.tgz -C ~/
    mv ~/EasyRSA-3.0.5/ /etc/openvpn/
    mv /etc/openvpn/EasyRSA-3.0.5/ /etc/openvpn/easy-rsa/
    chown -R root:root /etc/openvpn/easy-rsa/
    rm -f ~/easyrsa.tgz

    # Get the sqlite auth project
    echo
    echo "Installing OpenVPN SQLite Auth"
    echo
    SQLITEAUTHURL='https://github.com/mdeous/openvpn-sqlite-auth/archive/master.tar.gz'
    wget -O ~/openvpn-sqlite-auth.tgz "$SQLITEAUTHURL" 2>/dev/null || curl -Lo ~/openvpn-sqlite-auth.tgz "$SQLITEAUTHURL"
    tar xzf ~/openvpn-sqlite-auth.tgz -C ~/
    mv ~/openvpn-sqlite-auth-master/ /etc/openvpn/openvpn-sqlite-auth
    rm -f ~/openvpn-sqlite-auth.tgz
    # Install the sql auth config
    echo "# -*- coding: utf-8 -*-

# Path where users database should be stored
DB_PATH = '/etc/openvpn/openvpn-sqlite-auth/db.sqlite'
# Minimum required length for passwords when creating users
PASSWORD_LENGTH_MIN = 8
# Hash algorithm to use for passwords storage. Can be one of:
# md5, sha1, sha224, sha256, sha384, sha512
HASH_ALGORITHM = 'sha512'
" > /etc/openvpn/openvpn-sqlite-auth/config.py


    # Install the host_ban generator and files
    echo '#/bin/bash
TMPFILE=$(mktemp)
TMPHOSTSFILE=$(mktemp)

# Load all hosts file sequentially
cat /etc/hosts_ban.conf | while read URL ; do
  [[ "$URL" =~ ^# ]] || [[ -z "$URL" ]] && continue
  R=$(curl -s --max-time 120 $URL | grep 0.0.0.0 | grep -E -v "(#|>)" > $TMPFILE )
  [ $? -eq 0 ] && cat $TMPFILE >> $TMPHOSTSFILE
done
sort -u -o $TMPHOSTSFILE $TMPHOSTSFILE

# Filter out regular expressions from whitelist
cat /etc/hosts_ban.whitelist | while read REGEX; do  
  [[ "$REGEX" =~ ^# ]] || [[ -z "$REGEX" ]] && continue
  grep -v " $REGEX$" $TMPHOSTSFILE > $TMPFILE 
  mv $TMPFILE $TMPHOSTSFILE;
done

# Replace final content
mv $TMPHOSTSFILE /etc/hosts_ban
rm -f $TMPFILE 

service dnsmasq restart 
' > /usr/local/sbin/host_ban_generator
    echo '# Hosts ban URLs, see https://github.com/mitchellkrogza/Ultimate.Hosts.Blacklist for more info
https://hosts.ubuntu101.co.za/hosts
    ' > /etc/hosts_ban.conf
    echo '# Hosts ban whitelist 
https://hosts.ubuntu101.co.za/hosts
    ' > /etc/hosts_ban.conf
    chmod 700 /usr/local/sbin/host_ban_generator
    chown root:root /usr/local/sbin/host_ban_generator
    /usr/local/sbin/host_ban_generator

    echo "32 10 * * * root /usr/local/sbin/host_ban_generator &>/dev/null" > /etc/cron.d/host_ban_generator
    chmod 644 /etc/cron.d/host_ban_generator

    # Create the logrotate.d
    echo "/var/log/openvpn/openvpn.log {
        compress
        copytruncate    
        rotate 2 
        weekly
    }"  > /etc/logrotate.d/openvpn.conf

    # Create the PKI, set up the CA and the server and client certificates
    cd /etc/openvpn/easy-rsa/
    ./easyrsa init-pki
    ./easyrsa --batch build-ca nopass
    EASYRSA_CERT_EXPIRE=3650 ./easyrsa build-server-full server nopass
    EASYRSA_CERT_EXPIRE=3650 ./easyrsa build-client-full $CLIENT nopass
    EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
    # Move the stuff we need
    cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/crl.pem /etc/openvpn
    # CRL is read with each client connection, when OpenVPN is dropped to nobody
    chown nobody:$GROUPNAME /etc/openvpn/crl.pem
    # Generate key for tls-auth
    openvpn --genkey --secret /etc/openvpn/ta.key
    # Create the DH parameters file using the predefined ffdhe2048 group
    echo '-----BEGIN DH PARAMETERS-----
MIIBCAKCAQEA//////////+t+FRYortKmq/cViAnPTzx2LnFg84tNpWp4TZBFGQz
+8yTnc4kmz75fS/jY2MMddj2gbICrsRhetPfHtXV/WVhJDP1H18GbtCFY2VVPe0a
87VXE15/V8k1mE8McODmi3fipona8+/och3xWKE2rec1MKzKT0g6eXq8CrGCsyT7
YdEIqUuyyOP7uWrat2DX9GgdT0Kj3jlN9K5W7edjcrsZCwenyO4KbXCeAvzhzffi
7MA0BM0oNC9hkXL+nOmFg/+OTxIy7vKBg8P+OxtMb61zO7X8vC7CIAXFjvGDfRaD
ssbzSibBsu/6iGtCOGEoXJf//////////wIBAg==
-----END DH PARAMETERS-----' > /etc/openvpn/dh.pem
    # Generate server.conf
    echo "local $IP
mode server
tls-server
port $PORT
proto $PROTOCOL
dev $DEV
sndbuf 0
rcvbuf 0
ca ca.crt
cert server.crt
key server.key
dh dh.pem
auth SHA512
tls-auth ta.key 0
topology subnet
server $IP_LOCAL_BASE $IP_LOCAL_RANGE
ifconfig-pool-persist /var/log/openvpn/persistant.txt
push \"redirect-gateway def1 bypass-dhcp\"
push \"dhcp-option DNS $IP_LOCAL_DNS\"
" > /etc/openvpn/server.conf
    # DNS
    case $DNS in
        1)
          # Locate the proper resolv.conf
          # Needed for systems running systemd-resolved
          if grep -q "127.0.0.53" "/etc/resolv.conf"; then
              RESOLVCONF='/run/systemd/resolve/resolv.conf'
          else
              RESOLVCONF='/etc/resolv.conf'
          fi
          # Obtain the resolvers from resolv.conf and use them for OpenVPN

          R=($(grep -v '#' $RESOLVCONF | grep 'nameserver' | grep -E -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'))
          case ${#R[@]} in
            (0) echo "No server found in $RESOLVCONF. Exiting"; exit 1; ;;
            (1) R+=(${R[0]});; # This is a bit dirty. Same address in both slots
          esac
          DNS_1=${R[0]}
          DNS_2=${R[1]}
        ;;
        2)
          DNS_1=1.1.1.1
          DNS_2=1.0.0.1
        ;;
        3)
          DNS_1=8.8.4.4
          DNS_2=8.8.8.8
        ;;
        4)
          DNS_1=208.67.222.220
          DNS_2=208.67.222.222
        ;;
        5)
          DNS_1=64.6.64.6
          DNS_2=64.6.65.6
        ;;
    esac
    echo "
duplicate-cn
keepalive 10 120
cipher AES-256-CBC
user nobody
group $GROUPNAME
persist-key
persist-tun

status /var/log/openvpn/status.log
log-append /var/log/openvpn/openvpn.log
verb 4
mute 10
crl-verify crl.pem
up /etc/openvpn/vpn.up.sh

auth-user-pass-verify /etc/openvpn/openvpn-sqlite-auth/user-auth.py via-env
script-security 3

# EOF" >> /etc/openvpn/server.conf
    # Enable net.ipv4.ip_forward for the system
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/30-openvpn-forward.conf
    # Enable without waiting for a reboot or service restart
    echo 1 > /proc/sys/net/ipv4/ip_forward
    if pgrep firewalld; then
        # Using both permanent and not permanent rules to avoid a firewalld
        # reload.
        # We don't use --add-service=openvpn because that would only work with
        # the default port and protocol.
        firewall-cmd --zone=public --add-port=$PORT/$PROTOCOL
        firewall-cmd --zone=trusted --add-source=$IP_LOCAL_BASE/$IP_RANGE
        firewall-cmd --permanent --zone=public --add-port=$PORT/$PROTOCOL
        firewall-cmd --permanent --zone=trusted --add-source=$IP_LOCAL_BASE/$IP_RANGE
        # Set NAT for the VPN subnet
        firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s $IP_LOCAL_BASE/$IP_RANGE -j SNAT --to $IP
        firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s $IP_LOCAL_BASE/$IP_RANGE -j SNAT --to $IP
    else
        # Needed to use rc.local with some systemd distros
        if [[ "$OS" = 'debian' && ! -e $RCLOCAL ]]; then
            echo '#!/bin/sh -e
exit 0' > $RCLOCAL
        fi
        chmod +x $RCLOCAL
        # Set NAT for the VPN subnet
        iptables -t nat -A POSTROUTING -s $IP_LOCAL_BASE/$IP_RANGE -j SNAT --to $IP
        sed -i "1 a\iptables -t nat -A POSTROUTING -s $IP_LOCAL_BASE/$IP_RANGE -j SNAT --to $IP" $RCLOCAL
        if iptables -L -n | grep -qE '^(REJECT|DROP)'; then
            # If iptables has at least one REJECT rule, we asume this is needed.
            # Not the best approach but I can't think of other and this shouldn't
            # cause problems.
            iptables -I INPUT -p $PROTOCOL --dport $PORT -j ACCEPT
            iptables -I FORWARD \! -d  $IP_LOCAL_BASE/$IP_RANGE -s $IP_LOCAL_BASE/$IP_RANGE -j ACCEPT
            iptables -t nat -A POSTROUTING \! -d 10.8.0.0/24 -s 10.8.0.0/24 -j SNAT --to-source 51.159.17.77
            sed -i "1 a\iptables -I INPUT -p $PROTOCOL --dport $PORT -j ACCEPT" $RCLOCAL
            sed -i "1 a\iptables -I FORWARD \! -d  $IP_LOCAL_BASE/$IP_RANGE -s $IP_LOCAL_BASE/$IP_RANGE -j ACCEPT" $RCLOCAL
            sed -i "1 a\iptables -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" $RCLOCAL
        fi
    fi
    echo "#!/bin/bash
ip l set tun0 up
ip a add $IP_LOCAL_DNS/$IP_RANGE dev tun0
exit 0
" >/etc/openvpn/vpn.up.sh
    chmod 755 /etc/openvpn/vpn.up.sh
    chown root:root /etc/openvpn/vpn.up.sh


    # Set up dnsmasq and restart
    echo "
addn-hosts=/etc/hosts_ban
bogus-priv
domain-needed
listen-address=127.0.0.1
listen-address=$IP_LOCAL_DNS
server=$DNS_1
server=$DNS_2
#EOF" > /etc/dnsmasq.conf
   if [[ "$OS" = 'debian' ]]; then
        # Little hack to check for systemd
        if pgrep systemd-journal; then
            systemctl restart dnsmasq.service
        else
            /etc/init.d/dnsmasq restart
        fi
    else
        if pgrep systemd-journal; then
            systemctl restart dnsmasq.service
            systemctl enable dnsmasq.service
        else
            service dnsmasq restart
            chkconfig dnsmasq on
        fi
    fi
    # If SELinux is enabled and a custom port was selected, we need this
    if sestatus 2>/dev/null | grep "Current mode" | grep -q "enforcing" && [[ "$PORT" != '1194' ]]; then
        # Install semanage if not already present
        if ! hash semanage 2>/dev/null; then
            yum install policycoreutils-python -y
        fi
        semanage port -a -t openvpn_port_t -p $PROTOCOL $PORT
    fi
    # And finally, restart OpenVPN
    mkdir -p /var/log/openvpn
    if [[ "$OS" = 'debian' ]]; then
        # Little hack to check for systemd
        if pgrep systemd-journal; then
            systemctl restart openvpn@server.service
        else
            /etc/init.d/openvpn restart
        fi
    else
        if pgrep systemd-journal; then
            systemctl restart openvpn@server.service
            systemctl enable openvpn@server.service
        else
            service openvpn restart
            chkconfig openvpn on
        fi
    fi
    # If the server is behind a NAT, use the correct IP address
    if [[ "$PUBLICIP" != "" ]]; then
        IP=$PUBLICIP
    fi
    # client-common.txt is created so we have a template to add further users later
    echo "client
tls-client
dev $DEV
proto $PROTOCOL
sndbuf 0
rcvbuf 0
remote $IP $PORT
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth-user-pass
auth SHA512
cipher AES-256-CBC
setenv opt block-outside-dns
key-direction 1
verb 3
# EOF
" > /etc/openvpn/client-common.txt
    # Generates the custom client.ovpn
    OVPN_PATH="/etc/openvpn/client/$CLIENT.ovpn"
    newclient "$CLIENT" "$OVPN_PATH"
    /etc/openvpn/openvpn-sqlite-auth/createdb.py
    echo
    echo "Finished!"
    echo
    echo "Your client configuration is available at:" "$OVPN_PATH"
    echo
    echo "Please create your first user! Run:"
    echo
    echo "  /etc/openvpn/openvpn-sqlite-auth/user-add.py <username>"
    echo


fi
