#!/usr/bin/perl -s
use 5.10.0;
use utf8;
use strict;
use warnings;
use open qw( :std :utf8 );
use autodie qw( open close );
use Data::Dumper;
use Path::Class qw( file );
use FindBin;
use Template;

$Data::Dumper::Terse    = 1;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Indent   = 1;

our $base_oid
    or die usage( );

my $FH = file( "$FindBin::Bin/../template/cacti_template.memcached.xml" )->openr;

my $template = Template->new;
$template->process(
    $FH,
    { base_oid => $base_oid },
    \my $output,
);

say $output;

exit;

sub usage {
    return <<END_USAGE;
usage: $0 -base_oid=<base OID>
  base_oid: e.g., .1.3.6.1.4.1.88888.4
END_USAGE
}
