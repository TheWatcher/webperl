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
package Webperl::AuthMethod;

use strict;

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
#                 authentication, they will be set in $auth -> {"errstr"}.
# @return true if the user's credentials are valid, false otherwise.
sub authenticate {
    my $self     = shift;
    my $username = shift;
    my $password = shift;
    my $auth     = shift;

    # This class does not know how to authenticate users, always return false.
    return 0;
}


## @method $ require_activate()
# Determine whether the AuthMethod module requires that user accounts
# be activated before they can be used.
#
# @return true if the AuthMethod requires activation, false if it does not.
sub require_activate {
    my $self = shift;

    # By default, AuthMethods do not require account activation
    return 0;
}


## @method $ noactivate_message()
# Generate a message (or, better yet, a language variable marker) to show to users
# who attempt to activate an account that uses an AuthMethod that does not require it.
#
# @return A message to show to the user when redundantly attempting to activate.
sub noactivate_message {
    my $self = shift;

    return $self -> {"noactivate_message"} || $self -> {"settings"} -> {"config"} -> {"AuthMethod::noactivate_message"};
}


## @method $ supports_recovery()
# Determine whether the AuthMethod allows users to recover their account details
# within the system.
#
# @return True if the AuthMethod supports in-system account recovery, false if it does not.
sub supports_recovery {
    my $self = shift;

    # By default, AuthMethods do not support recovery
    return 0;
}


## @method $ norecover_message()
# Generate a message to show users who attempt to recover their account using an AuthMethod
# that does not support in-system recovery.
#
# @return A message to show to the user attempting an unsupported recovery operation.
sub norecover_message {
    my $self = shift;

    return $self -> {"norecover_message"} || $self -> {"settings"} -> {"config"} -> {"AuthMethod::norecover_message"};
}

1;
