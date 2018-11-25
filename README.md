## openvpn-install custom edition

Based on the OpenVPN [road warrior installer for Debian, Ubuntu and CentOS.](https://github.com/Nyr/openvpn-install)

This script will let you setup your own VPN server in no more than a minute, even if you haven't used OpenVPN before. It has been designed to be as unobtrusive and universal as possible.

This is a custom version which does a bit more than the original:
* [Use login/password together with certificates](#login--password)
* [Filter rogue DNS on the server side](#filter-dns)

### Installation
Run the script and follow the assistant:

`git clone https://github.com/albancrommer/openvpn-install.git && cd openvpn-install && bash openvpn-install.sh`

Once it ends, you have to create login/passwords using the following command line:

`/etc/openvpn/openvpn-sqlite-auth/add-user.py <username>`

Make the ovpn file available to users, for example using nginx-light + Letsencrypt

### User tutorial

Install on your phone the openvpn application from your prefered app store.

Download the ovpn file as sent to you: it should open in the openvpn app 

Fill the login and password sent to you

Click "Add" to validate this new VPN

Activate the VPN, and enjoy your renewed privacy!


### What's so custom about this script 

We hacked the original in the spirit of the original road warrior approach : fast, simple, efficient.

#### Login & password 

This version was born from the need of having secure and simple login-based VPN.

It allows multiple clients to use the same certificate but different credentials.

This is way more simple when you need to set up accounts for non-techy friends & family members.

We use the [SQLite Auth](https://github.com/mdeous/openvpn-sqlite-auth) project for that purpose. 

They are a set of python scripts we locate in `/etc/openvpn/openvpn-sqlite-auth` on the server. 

#### Filter DNS 

This was inspired by Blokada which provides a local VPN with DNS blackholing.

It means that requests to domain names considered *unsafe* are blackholed, i.e. sent to a virtual trashbin.

Apart from sparing a reasonable of bandwidth, the advantage lays in what is considered *unsafe*. We consider analytics, tracking or exploits to be *unsafe*. 

[PiHole](https://pi-hole.net/) and [BobsNico](https://github.com/BobNisco/adblocking-vpn) were other inspirations / guides on that topic.

We use [dnsmasq](http://www.thekelleys.org.uk/dnsmasq/doc.html) for that purpose, together with an agressive [Hosts Blacklist](https://github.com/mitchellkrogza/Ultimate.Hosts.Blacklist) as a default.

A daily cron script is created to update daily the hosts ban list. You can edit and configure your sources in `/etc/hosts_ban.conf`, one HTTP source per line.


### Donations

If you want to show your appreciation, you can donate to the original author of this script via [PayPal](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=VBAYDL34Z7J6L) or [cryptocurrency](https://pastebin.com/raw/M2JJpQpC). Thanks!
