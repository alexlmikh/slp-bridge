# SLP Bridge

Copyright (c) 2015 Transparent Language, Inc.  All rights reserved.
License: MIT (see LICENCE)
Author: Alexander L. Mikhailov

## Synopsis

*SLP Bridge* is a small daemon (service), which will listen for *SLP* requests
on a given (source) network, relay them to another (target) network, and then pass back *SLP* responses,
as appropriate.

That is especially useful for bridging Docker container network stack
with a physical LAN, w/o having to setup a tricky multi-cast routing.

The only (currently) supported mode of operation, is relaying requests from 
the "source" network to the "target" network, i.e. you can not host a real *SLP SA/DA* inside the "source" network.

## Configuration

Service configuration is stored in */etc/default/slpbridge*,
and includes just two parameters:

    #Interface to listen for SLP requests on
    SOURCE_IFACE=docker0

    #Interface to relay SLP requests to
    TARGET_IFACE=eth0

## Logs 

Depending on if SLP Bridge is registered as an Upstart Job or SystemD service,
it's log messages will either go to */var/log/upstart/slpbridge.log* or */var/log/syslog*.

If everything goes well, you should see the log message like this, when SLP Bridge is ready to use:

    ...
    slpbridge: Bridge Up [****] !
    ...

## Starting and Stopping 

*SLP Bridge* service name is *slpbridge*, and depending on if your are running an Upstart, SystemD or a generic SysV system,
you can use *service*, *systemctl* or *initctl* to start and stop it.

## Installation

### Using *deb* package

#Build slpbridge .deb package
%make build

#Install ($PERL_VERSION must match your Perl version, e.g. 5.20)
dpkg -i slpbridge-*.deb perl/$PERL_VERSION/*.deb

#Fix dependencies
apt-get -f install
