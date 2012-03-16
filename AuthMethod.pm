## @file
# This file contains the implementation of the authentication method base class.
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
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

## @class
# The base class for all authentication method classes. This class is
# mainly present for documentation purposes - it doesn't actually provide
# any meaningful implementation of an authentication method, and the
# actually interesting stuff should happen in subclasses of it.
package AuthMethod;

use strict;

our $errstr;

BEGIN {
	$errstr = '';
}

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Construct a new AuthMethod object. This will create a new AuthMethod object
# initialised with the provided arguments. All the arguments are copied into
# the new object 'as is', with no processing - the caller must make sure they
# are sane before calling this.
#
# @param args A hash of arguments to initialise the AuthMethod object with.
# @return A new AuthMethod object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;

    my $self     = {
        @_,
    };

    return bless $self, $class;
}


# ============================================================================
#  Interface code

## @method $ authenticate($username, $password, $auth)
# Authenticate a user based on the credentials supplied. This will attempt
# to determine whether the user's credentials are valid, and will return
# true if they are, or false if they are not or a problem occured while
# performing the authentication.
#
# @param username The username of the user to authenticate.
# @param password The password of the user to authenticate.
# @param auth     A reference to the Auth object calling this function,
#                 if any errors are encountered while performing the
#                 authentication, they will be appended to $auth -> {"lasterr"}.
# @return true if the user's credentials are valid, false otherwise.
sub authenticate {
    my $self     = shift;
    my $username = shift;
    my $password = shift;
    my $auth     = shift;

    # This class does not know how to authenticate users, always return false.
    return 0;
}


# ============================================================================
#  Error functions

sub get_error { return $errstr; }

sub set_error { $errstr = shift; return undef; }

1;
