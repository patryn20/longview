#!/usr/bin/env perl
use strict;
use warnings;

=head1 COPYRIGHT/LICENSE

Copyright 2013 Linode, LLC.  Longview is made available under the terms
of the Perl Artistic License, or GPLv2 at the recipients discretion.

=head2 Perl Artistic License

Read it at L<http://dev.perl.org/licenses/artistic.html>.

=head2 GNU General Public License (GPL) Version 2

  This program is free software; you can redistribute it and/or
  modify it under the terms of the GNU General Public License
  as published by the Free Software Foundation; either version 2
  of the License, or (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see http://www.gnu.org/licenses/

See the full license at L<http://www.gnu.org/licenses/>.

=cut

BEGIN {
	use Config;
	use FindBin;
	push @INC, "$FindBin::RealBin/../";
	push @INC, "$FindBin::RealBin/../lib/perl5";
	push @INC, "$FindBin::RealBin/../lib/perl5/${Config{archname}}/";
	push @INC, "$FindBin::RealBin/../usr/include";
	{
		no warnings 'once';
		$Net::HTTP::SOCKET_CLASS = 'IO::Socket::INET6';
	}
	require Net::HTTP;
}

use JSON;
use Config::YAML;
use Try::Tiny;
use Sys::Hostname;
use LWP::UserAgent;
use Compress::Zlib;
use IO::Socket::INET6;
use Linode::Longview::DataGetter;
use Linode::Longview::Util ':DRIVER';

$logger->info("Starting Longview Agent version $VERSION");

$logger->logdie('Longview must be run as root in order to collect data') unless ($< == 0);
my $pid = check_already_running();
$logger->logdie("The Longview agent is already running as PID: $pid") if $pid;

my $confdir    = '/etc/linode';
my $conf_file = "$confdir/config.yaml";

my $conf_yaml = scalar(slurp_file($conf_file));
unless ($conf_yaml){
	umask 066;
	mkdir $confdir;
	open my $fh, '>', $conf_file or $logger->logdie("Couldn't open $conf_file for writing: $!");
	print $fh "---\n\n";
	close $fh or $logger->logdie("Couldn't close $conf_file: $!");
}

our $config = Config::YAML->new( 
	config => $conf_file,
	output => $conf_file,
 	post_target => "",
 	apikey => ""
);

$apikey = $config->get_apikey;
$post_target = $config->get_post_target;
unless ($apikey){
	print "\nNo API key found. Please enter your API Key: " if -t;
	$apikey = <>;
	unless(defined $apikey){
		print "No API key found. Please add your API key to /etc/linode/config.yaml before starting longview.\n";
		exit 1;
	}
	chomp($apikey);
	unless ($apikey =~ /^[0-9A-F]{8}-(?:[0-9A-F]{4}-){2}[0-9A-F]{16}\z$/){
		print "Invalid API Key\n";
		exit 1;
	}
	$config->set_apikey($apikey)
}
$logger->logdie('Invalid API key') unless ($apikey =~ /^[0-9A-F]{8}-(?:[0-9A-F]{4}-){2}[0-9A-F]{16}\z$/);

unless ($post_target){
	print "\nNo API endpoint found. Please enter the full URL of the endpoint (eg:http://127.0.0.1/endpoint/v1/log): " if -t;
	$post_target = <>;
	unless(defined $post_target){
		print "No API endpoint found. Please add your API endpoint URL to /etc/linode/config.yaml before starting longview.\n";
		exit 1;
	}
	chomp($post_target);
	unless ($post_target =~ /^(http|https):\/\//){
		print "Invalid API endpoint\n";
		exit 1;
	}
	$config->set_post_target($post_target)
}
$logger->logdie('Invalid API endpoint') unless ($post_target =~ /^(http|https):\/\//);

$config->write;

my $stats = {
	apikey  => $apikey,
	version => '1.0',
	payload => [],
};

_prep_for_main();

my ($quit, $data, $reload) = (0, {}, 0);
while (!$quit) {
	if ($reload){
		reload_modules();
		$reload = 0;
	}
	my $sleep = $SLEEP_TIME;
	$data->{timestamp} = time;
	get($_,$data,) for @{run_order()};

	constant_push($stats->{payload},$data);
	$data = {};

	$stats->{timestamp} = time;
	my $req = post($stats);

	if ($req->is_success){
		$logger->debug($req->status_line);
		$logger->debug($req->decoded_content);
		my $rep;
		try {
			$rep = decode_json($req->decoded_content);
		} catch {
			$logger->debug("Couldn't decode JSON response: $_");
		};
		$sleep = $rep->{sleep} if defined $rep->{sleep};
		if (defined($rep->{die}) && $rep->{die} eq 'please') {
			$logger->logdie('Server has requested this API Key stop sending data');
		}
		@{$stats->{payload}} = ();
	}
	else{
		$logger->info($req->status_line);
		$logger->info($req->decoded_content);
	}

	sleep $sleep;
}

sub _prep_for_main {
	chown 0, 0, $conf_file;
	chmod 0600, $conf_file;

	daemonize_self();
	enable_debug_logging() if(defined $ARGV[0] && $ARGV[0] =~ /Debug/i);
	load_modules();

	$0 = 'linode-longview';
	$SIG{TERM} = $SIG{INT} = $SIG{QUIT} = sub { $quit = 1 };
	$SIG{HUP} = sub { $reload = 1};
	$logger->info('Start up complete');
	$logger->info($post_target);
}
