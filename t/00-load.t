#!perl -T
use 5.006;
use strict;
use warnings FATAL => 'all';
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'Webperl::Application' ) || print "Bail out!\n";
    use_ok( 'Webperl::Block' ) || print "Bail out!\n";
    use_ok( 'Webperl::AppUser' ) || print "Bail out!\n";
    use_ok( 'Webperl::BlockSelector' ) || print "Bail out!\n";
    use_ok( 'Webperl::System' ) || print "Bail out!\n";
}

diag( "Testing Webperl $Webperl::VERSION, Perl $], $^X" );
