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
use base qw(Webperl::SystemModule);

# ============================================================================
#  Interface code

## @method $ create_user($username, $authmethod)
# Create a user account in the database. Note that, unless overridden in a subclass,
# this creates a 'stub' user in the database, with minimal information required to
# simply get a user ID needed for other areas of the system. If more complete data
# should be stored with the user, subclasses need to deal with that. For AuthMethods
# that do their authentication against other systems, this user creation function
# is sufficient to pass post_auth requirements - however, they may need to perform
# additional checks in their AppUser implementation to ensure that required fields
# (like email) are populated by the user before they continue.
#
# @param username   The name of the user to create.
# @param authmethod The ID of the authmethod to set as the user's default authmethod.
# @return A reference to the new user's database entry on success, undef on error.
sub create_user {
    my $self = shift;
    my $username = shift;
    my $authmethod = shift;

    $self -> clear_error();

    my $active = !$self -> require_activate();

    my $newuser = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"users"}."
                                               (user_auth, activated, username, created, last_login)
                                               VALUES(?, ?, ?, UNIX_TIMESTAMP(), UNIX_TIMESTAMP())");
    $newuser -> execute($authmethod, $active, $username)
        or $self -> self_error("Unable to create new user record: ".$self -> {"dbh"} -> errstr);

    return $self -> get_user($username);
}


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


## @method $ activated($userid)
# Determine whether the user account specified has been activated.
#
# @param userid The ID of the user account to check the activation status of.
# @return true if the user has been activated (actually, the unix timestamp of
#         their activation), 0 if the user has not been activated/does not exist,
#         or undef on error.
sub activated {
    my $self = shift;

    # By default, users are always active, as activation is not required.
    return 1;
}


## @method $ activate_user($userid)
# Activate the user account with the specified id. This clears the user's
# activation code, and sets the activation timestamp.
#
# @param userid The ID of the user account to activate.
# @return True on success, undef on error.
sub activate_user {
    my $self   = shift;
    my $userid = shift;

    # Activation will always fail if not needed
    return $self -> self_error("Unsupported activation requested");
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


## @method @ reset_password_actcode($userid)
# Forcibly reset the user's password and activation code to new random values.
#
# @param userid The ID of the user to reset the password and act code for
# @return The new password and activation code set for the user, undef on error.
sub reset_password_actcode {
    my $self   = shift;
    my $userid = shift;

    # Do nothing, as by default activation and password change are not supported
    return $self -> self_error("Unsupported password and activation code change requested");
}


## @method $ reset_password($userid)
# Forcibly reset the user's password to a new random value.
#
# @param userid The ID of the user to reset the password for
# @return The (unencrypted) new password set for the user, undef on error.
sub reset_password {
    my $self   = shift;
    my $userid = shift;

    # Do nothing as password changes are not supported
    return $self -> self_error("Unsupported password change requested");
}


## @method $ set_password($userid, $password)
# Set the user's password to the specified value.
#
# @param userid   The ID of the user to set the password for
# @param password The password to set for the user.
# @return True on success, undef on error.
sub set_password {
    my $self   = shift;
    my $userid = shift;

    # Do nothing as password changes are not supported
    return $self -> self_error("Unsupported password change requested");
}


## @method $ generate_actcode($userid)
# Generate a new activation code for the specified user.
#
# @param userid The ID of the user to reset the actcode for
# @return The new activation code for the user
sub generate_actcode {
    my $self   = shift;
    my $userid = shift;

    # do nothing as activation is not required
    return $self -> self_error("Unsupported activation code change requested");
}

1;
