#!/usr/bin/perl -w
use strict;
use local::lib '/home/danlyke/perl5';
use Modern::Perl;
use utf8::all;

# We're SUID and we know it (clap your hands)
$< = $>;
$ENV{'PATH'} ='/home/danlyke/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';

#$UID = $EUID;


use Fby;


package main;



my $cmd = shift @ARGV;

my $commands = &Fby::commands;

if (defined($cmd) && $commands->{$cmd})
{
	&{$commands->{$cmd}}(@ARGV);
}
else
{
	print STDERR "Unrecognized command '$cmd', must be one of\n";
	foreach (sort keys %$commands)
	{
		print STDERR "   $_\n";
	}
}

