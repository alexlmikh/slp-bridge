#!/usr/bin/perl -w 

#######################################################################
# Copyright (c) 2015 Transparent Language, Inc.  All rights reserved. #
#                                                                     #
# Author: Alexander L. Mikhailov                                      # 
# Date: 25 Dec 2015                                                   # 
#                                                                     #
# Abstract:                                                           #
#                                                                     #
#  This is a POE-based state machine, listening to the Linux Kernel   #
#  Netlink messages, which implements an SLP bridge between the two   # 
#  local network interfaces.                                          #
#                                                                     #
#  The primary purpose of it is to allow SLP clients (UAs)            #
#  to operate correctly inside the Docker container.                  #
####################################################################### 

use POE;
use Socket;
use Socket::Netlink qw( :DEFAULT );
use Socket::Netlink::Route qw( :DEFAULT );
use IO::Socket::Netlink::Route;
use IO::Socket::Multicast;

use constant POOL_SIZE => 512;
use constant DTGR_SIZE => 1024;
use constant MCAST_SLP_IP => "239.255.255.253";
use constant MCAST_SLP_PORT => "427";
use constant MCAST_BRIDGE_OUT_PORT => "4427";
use constant CONNECTED => 0x0F;
use constant LINK_OP_READY => 0x06;

#Turn buffering off
local $| = 1;

my $help = <<END;
SLP Bridge 1.0
	
A super-simple Service Location Protocol bridge
	
Usage: 

slp-bridge SOURCE_IFACE TARGET_IFACE

\t SOURCE_IFACE - interface to listen for SLP requests on
\t TARGET_IFACE - interface to relay SLP requests to

Example:

slp-bridge docker0 eth0
END

if($#ARGV != 1) {
	print $help;
	exit 1;
}

sub IFACE_N {
	my $idx = shift;

	if($idx eq $ARGV[0]) {
		return 0x01;
	} elsif($idx eq $ARGV[1]) {
		return 0x02;
	} else {
		return 0x00;
	}
}

sub logit {
	printf ("slpbridge: " . shift . "\n",@_);
}

sub bridgeStatus {
	my $bb = sprintf("[%04b]",shift); 
	$bb =~ tr/01/-*/; 
	return $bb;
}

POE::Session->create(
	inline_states => {
		_start => sub {
			my ($heap,$kernel) = @_[HEAP,KERNEL];

			#Bridge state
			$heap{XID}=-1;
			$heap{POOL}={};

			$heap{IFACE_MAP}={};
			$heap{BRIDGE}=0x00;

			#Listen for netlink notifications from Kernel
			my $rtnlsock_notify = IO::Socket::Netlink::Route->new(
			   Groups => RTMGRP_LINK | RTMGRP_IPV4_IFADDR
			) or die "Cannot make netlink socket - $!";
			$kernel->select_read($rtnlsock_notify,"consumeNetlinkMessages");

			#Force-poll on startup
			my $rtnlsock = IO::Socket::Netlink::Route->new(
			   Groups => RTMGRP_LINK | RTMGRP_IPV4_IFADDR
			) or die "Cannot make netlink socket - $!";

			#Force query current link states
			$rtnlsock->send_nlmsg( $rtnlsock->new_request(
			      nlmsg_type  => RTM_GETLINK,
			      nlmsg_flags => NLM_F_DUMP
			) ) or die "Unable to poll link states - $!";
			$kernel->call($_[SESSION],"consumeNetlinkMessages",$rtnlsock);

			#Force query current interface addresses
			$rtnlsock->send_nlmsg( $rtnlsock->new_request(
			     nlmsg_type  => RTM_GETADDR, 
			     nlmsg_flags => NLM_F_DUMP
			));
			$kernel->call($_[SESSION],"consumeNetlinkMessages",$rtnlsock);

			logit("Initializing source=$ARGV[0] target=$ARGV[1]");			
		},

		consumeNetlinkMessages => sub {
			my ($heap,$kernel, $rtnlsock) = @_[HEAP,KERNEL,ARG0];

			my @messages;
			$rtnlsock->recv_nlmsgs( \@messages, 2**16); 

			foreach my $message (@messages) {
				$kernel->yield("onNetlinkMessage",$message);
			}
		},

		onNetlinkMessage => sub {
			my ($heap,$kernel, $message) = @_[HEAP,KERNEL,ARG0];

			my $bridge=$heap{BRIDGE};

			if($message->nlmsg_type == NLMSG_ERROR) {
			      $! = -(unpack "i!", $message->nlmsg)[0];
				  logit("Netlink ERROR %d !",$!);
   			}

			if($message->nlmsg_type == RTM_NEWLINK) {
				my $iface = ${$message->nlattrs}{"ifname"};
				my $iidx = $message->ifi_index;
				my $operstate = ${$message->nlattrs}{"operstate"};

				logit("Message RTM_NEWLINK iface=%s index=%d operstate=%d",$iface,$iidx,$operstate);
				${$heap{IFACE_MAP}}{$iidx}=$iface;
				
				if($operstate == LINK_OP_READY) {
					$bridge|=IFACE_N($iface);
				} else {
					$bridge&=~IFACE_N($iface);
				}
			}

			if($message->nlmsg_type == RTM_DELADDR && $message->ifa_family == 2) {					
				logit("Message RTM_DELADDR index=%d, family=%d, address=%s",$message->ifa_index,$message->ifa_family,${$message->nlattrs}{"address"});
				$bridge&=~(IFACE_N(${$heap{IFACE_MAP}}{$message->ifa_index}) << 2);
			}

			if($message->nlmsg_type == RTM_NEWADDR && $message->ifa_family == 2) {					
				logit("Message RTM_NEWADDR index=%d, family=%d, address=%s",$message->ifa_index,$message->ifa_family,${$message->nlattrs}{"address"});
				$bridge|=IFACE_N(${$heap{IFACE_MAP}}{$message->ifa_index}) << 2;
			}

			if($heap{BRIDGE} != CONNECTED && $bridge == CONNECTED) {
				$kernel->yield("onBridgeUp");
			}

			if($heap{BRIDGE} == CONNECTED && $bridge != CONNECTED) {
				$kernel->yield("onBridgeDown");
			}

			if($heap{BRIDGE} != $bridge) {
				logit("Bridge state %s => %s",bridgeStatus($heap{BRIDGE}),bridgeStatus($bridge));
				$heap{BRIDGE}=$bridge;
			}
		},

		onBridgeUp => sub {
				my ($heap,$kernel, $socket, $osocket) = @_[HEAP,KERNEL];

				$heap{"osocket"} = IO::Socket::Multicast->new(Proto=>'udp',LocalPort=>MCAST_BRIDGE_OUT_PORT) or die "slpbridge: Failed to create outgoing UDP socket !";
			    $heap{"isocket"} = IO::Socket::Multicast->new(LocalPort=>MCAST_SLP_PORT, LocalAddr=>MCAST_SLP_IP,ReuseAddr => 1) or die "slpbridge: Failed to create incoming UDP socket !";

				$heap{"osocket"}->mcast_if($ARGV[1]);
				$kernel->select_read($heap{"osocket"},"onResponse");

				$heap{"isocket"}->mcast_add(MCAST_SLP_IP,$ARGV[0]);
				$kernel->select_read($heap{"isocket"},"onRequest");

				logit("Bridge Up %s !",bridgeStatus($heap{BRIDGE}));
		},

		onBridgeDown => sub {
				my ($heap,$kernel, $socket, $osocket) = @_[HEAP,KERNEL];

				$kernel->select_read($heap{"osocket"});
				close($heap{"osocket"});

				$kernel->select_read($heap{"isocket"});
				close($heap{"isocket"});

				logit("Bridge Down %s !",bridgeStatus($heap{BRIDGE}));
		},

		onRequest => sub {
			my ($heap,$kernel) = @_[HEAP,KERNEL];
			return unless $heap{BRIDGE} == CONNECTED;

			my $rcpt = recv($heap{"isocket"},my $message, DTGR_SIZE, 0); 
			my ($peer_port, $peer_addr) = unpack_sockaddr_in($rcpt);

			if($peer_port == MCAST_BRIDGE_OUT_PORT) {
                                logit("Request loop detected, please make sure nothing is listening on %s %s:%s (slpd?)",$ARGV[1],MCAST_SLP_IP,MCAST_SLP_PORT);
                        	return;
                        }

			my $slpfunc = vec($message,1,8);
			my $xid = vec($message,5,16);

			if($slpfunc == 0x01 || $slpfunc == 0x06 || $slpfunc == 0x09) {
				$heap{"POOL"}{($heap{"XID"} < POOL_SIZE ? ++$heap{"XID"} : ($heap{"XID"}=0))}={
					rcpt => $rcpt,
					xid => $xid
				};

				vec($message,5,16)=$heap{"XID"};
				$heap{"osocket"}->mcast_send($message,MCAST_SLP_IP . ":" . MCAST_SLP_PORT);
			
				logit("SLP > Request: %s:%d FUNC=%d XID %d => %d",inet_ntoa($peer_addr),$peer_port,$slpfunc,$xid,$heap{"XID"});
			}
		},

		onResponse => sub {
			my ($heap,$kernel) = @_[HEAP,KERNEL];
			return unless $heap{BRIDGE} == CONNECTED;

			my $sndr = recv($heap{"osocket"},my $message, DTGR_SIZE, 0);
			my $xid = vec($message,5,16);
			my $reply = $heap{"POOL"}{$xid};

			vec($message,5,16)=$reply->{xid};
			$heap{"isocket"}->mcast_send($message,$reply->{rcpt});	

			my ($peer_port, $peer_addr) = unpack_sockaddr_in($sndr);
			logit("SLP < Response: %s:%d XID %d => %d",inet_ntoa($peer_addr),$peer_port,$xid,$reply->{xid});
		}
	}
);

POE::Kernel->run();
