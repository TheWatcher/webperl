## @file
# This file contains the implementation of the LDAP authentication class.
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
# Implementation of a basic LDAP authentication module. This will allow
# users to be authenticated against most LDAP servers, provided that
# it is configured with the appropriate incantations to talk to it.
#
# This module supports the following comfiguration variables:
#
# - `server`      (required) the server to authenticate the user against, can be either
#                  a hostname, IP address, or URI.
# - `base`        (required) the base dn to use when searching for the user's dn.
# - `searchfield` (required) the field to use when searching for the user dn.
# - `adminuser`   (optional) if specified, searching for the user's DN will be done
#                  using this user rather than anonymously.
# - `adminpass`   (optional) The password to use when logging in as the admin user.
# - `reuseconn`   (optional) If set to a true value, the connection to the LDAP is reused
#                  for authentication after finding the user's dn.
# - `usetls`      (optional) If set to true, start_tls is called on the conntection.
#                 Otherwise *no TLS is used and the server connection is not encrypted*
#
# These will generally be provided by supplying the configuration variables
# in the auth_methods_params table and using Webperl::AuthMethods to load
# the AuthMethod at runtime.
package Webperl::AuthMethod::LDAP;

use strict;
use base qw(Webperl::AuthMethod); # This class extends AuthMethod
use Net::LDAPS;

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
    return set_error("Webperl::AuthMethod::LDAP missing 'server' argument in new()")      if(!$self -> {"server"});
    return set_error("Webperl::AuthMethod::LDAP missing 'base' argument in new()")        if(!$self -> {"base"});
    return set_error("Webperl::AuthMethod::LDAP missing 'searchfield' argument in new()") if(!$self -> {"searchfield"});

    return $self;
}


# ============================================================================
#  Interface code

## @method $ authenticate($username, $password, $auth)
# Attempt to authenticate the user against the LDAPS server. This will check the user's
# login against the configured LDAPS server, and return true if the login is valid.
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
        # First obtain the user dn
        my $userdn;
        my $ldap = Net::LDAP -> new($self -> {"server"}, version => 3);

        if($ldap) {
            $ldap -> start_tls(verify => 'none') if($self -> {"usetls"});

            # Bind for the search - if the object has adminuser and password, bind with them,
            # otherwise fall back on using an anonymous bind.
            my $mesg = ($self -> {"adminuser"} && $self -> {"adminpass"}) ? $ldap -> bind($self -> {"adminuser"}, $self -> {"adminpass"})
                                                                          : $ldap -> bind();
            if($mesg -> code) {
                return $auth -> self_error("LDAP bind to ".$self -> {"server"}." failed. Response was: ".$mesg -> error);
            } else {
                # Search for a user with the specified username in the base dn
                my $result = $ldap -> search("base"   => $self -> {"base"},
                                             "filter" => $self -> {"searchfield"}."=".$username);

                # Fetch the user's dn out of the response if possible.
                my $entry = $result -> shift_entry;
                $userdn = $entry -> dn
                    if($entry);
            }

            $ldap -> unbind();

            # If a userdn has been obtained, check that the password for it is valid
            if($userdn) {
                # Open a new connection unless the old one can be reused.
                if(!$self -> {"reuseconn"}) {
                    $ldap = Net::LDAP -> new($self -> {"server"});

                    $ldap -> start_tls(verify => 'none')
                        if($ldap && $self -> {"usetls"});
                }

                if($ldap) {
                    # Do the actual login...
                    $mesg = $ldap -> bind($userdn, password => $password);
                    $valid = 1
                        unless($mesg -> code);

                    $ldap -> unbind();
                } else {
                    return $auth -> self_error("Unable to connect to LDAP server: $@");
                }
            }
        } else {
            return $auth -> self_error("Unable to connect to LDAP server: $@");
        }

        return $valid;
    }

    return $auth -> self_error("LDAP login failed: username and password are required");
}

1;
