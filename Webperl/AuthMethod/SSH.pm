## @file
# This file contains the implementation of the SSH authentication class.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see http://www.gnu.org/licenses/.

## @class
# Implementation of a basic ssh authentication module, allowing
# users to be authenticated against an arbitrary ssh server. Note that
# this module involves potentially significant delays in authentication
# as a result of its reliance on Net::SSH::Expect.
#
# This module supports the following comfiguration variables:
#
# - `server`  (required) the server to authenticate the user against, can be either
#              a hostname or ip address.
# - `timeout` (optional) the conection timeout in seconds. This defaults to 5 if not
#              specified (values less than 5 are only recommended on fast
#              networks and when talking to servers that respond rapidly).
# - `binary`  (optional) the location of the ssh binary. Defaults to `/usr/bin/ssh`.
#
# These will generally be provided by supplying the configuration variables
# in the auth_methods_params table and using Webperl::AuthMethods to load
# the AuthMethod at runtime.
package Webperl::AuthMethod::SSH;

use strict;
use base qw(Webperl::AuthMethod); # This class extends AuthMethod
use Net::SSH::Expect;

# Custom module imports
use Utils qw(blind_untaint);


## @cmethod $ new(%args)
# Construct a new AuthMethod object. This will create a new AuthMethod object
# initialised with the provided arguments. All the arguments are copied into
# the new object 'as is', with no processing - the caller must make sure they
# are sane before calling this.
#
# @param args A hash of arguments to initialise the AuthMethod object with.
# @return A new AuthMethod object on success, an error message otherwise.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(@_)
        or return undef;

    # check that required settings are set...
    return set_error("Webperl::AuthMethod::SSH missing 'server' argument in new()")
        if(!$self -> {"server"});

    # Check whether the timeout and binary settings are, well, set...
    $self -> {"timeout"} = 5 unless(defined($self -> {"timeout"}));
    $self -> {"binary"}  = "/usr/bin/ssh" unless(defined($self -> {"binary"}));

    return $self;
}


# ============================================================================
#  Interface code

## @method $ authenticate($username, $password, $auth)
# Attempt to authenticate the user against the SSH server. This will check the user's
# login against the configured SSH server, and return true if the login is valid.
#
# @param username The username to check against the server.
# @param password The password to check against the server.
# @param auth     A reference to the Auth object calling this function,
#                 if any errors are encountered while performing the
#                 authentication, they will be set in $auth -> {"errstr"}.
# @return true if the user's credentials are valid, false otherwise.
sub authenticate {
    my $self     = shift;
    my $username = shift;
    my $password = shift;
    my $auth     = shift;
    my $valid    = 0;

    if($username && $password) {
        my $resp;

        eval {
            # FIXME: This is really godawful ghastly nasty shit that should not exist upon
            #        the living Earth, but if this is run in tainted mode perl will freak out.
            #        Fix this by untainting more safely!
            my $ssh = Net::SSH::Expect -> new(host     => blind_untaint($self -> {"server"}),
                                              user     => blind_untaint($username),
                                              password => blind_untaint($password),
                                              raw_pty  => 1,
                                              timeout  => blind_untaint($self -> {"timeout"}),
                                              binary   => blind_untaint($self -> {"binary"}));
            $resp = $ssh -> login();
            $resp =~ s/\s//g;
            $ssh -> close();
        };

        # Did the ssh fail horribly?
        if($@) {
            return $auth -> self_error("ssh login to ".$self -> {"server"}." failed. Error was: $@");

        # Did the user log in?
        } elsif($resp =~ /Welcome/ || $resp =~ /Last\s*login/s) {
            return 1;
        }

        # Note that password failures ARE NOT reported - just this auth method fails.
        return 0;
    }

    return $auth -> self_error("SSL Login failed: Username and password are required.");
}

1;
