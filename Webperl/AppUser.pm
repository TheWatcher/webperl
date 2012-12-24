## @file
# This file contains the implementation of the base class for application-specific
# user operations.
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
# The base class for application-specific user actions that must be performed
# during authentication. This provides the functions, potentially minimally
# implemented, that the Auth class relies on to interact with user records
# in the wider system in which it is being used. Subclasses of AppUser may
# provide more complex facilities to support application-specific requirements.
#
# This class assumes that the user data is stored in a table whose name is
# set in the 'users' variable in the 'database' section of the settings, and
# that the following fields are present in the table (order of fields in the
# table is unimportant):
#
# - `user_id` (`unsigned int`), unique to each user
# - `user_type` (`unsigned tinyint`), 0 = normal, 1 = disabled, 3 = admin usually
# - `username` (`varchar` or `text`), contains the user's username, must be unique per user
# - `user_auth` (`unsigned tinyint`), the id of the user's auth method, must allow null
# - `created` (`unsigned int`), stores the user's creation unix timestamp
# - `last_login` (`unsigned int`), stores the user's last login unix timestamp
#
# (note that the first three of these are basic requirements of the SessionHandler)
#
# In general, most subclasses of this class will only really be concerned with
# overriding the pre_authenticate() and post_authenticate() methods - the other
# methods will usually be sufficient for most purposes, and system-specific work
# will usually happen in pre_authenticate() or post_authenticate(). However,
# subclasses that override pre_authenticate() or post_authenticate() may wish
# to call the overridden methods this class via `$self -> SUPER::pre_authenticate()`
# or `$self -> SUPER::pre_authenticate()` to extend the default behaviour with
# system-specifics rather than entirely replacing it.
package Webperl::AppUser;

use strict;
use base qw(Webperl::SystemModule); # Extend SystemModule to get error handling

use constant ANONYMOUS_ID => 1; # Default anonymous user id.
use constant ADMIN_TYPE   => 3; # User type for admin users.

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Create a new Webperl::AppUser object. This will create a Webperl::AppUser object that may be
# passed to the Auth class to provide application-specific user handling.
#
# @param args A hash of arguments to initialise the AppUser object with.
# @return A new AppUser object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(minimal => 1, # minimal tells SystemModule to skip object checks
                                        @_)
        or return undef;

    return $self;
}


## @method $ init($cgi, $dbh, $settings, $logger)
# Initialise the AppUser's references to other system objects. This allows the
# setup of the object to be deferred from construction. If the cgi, dbh, and
# settings objects have been passed into new(), calling this function is not
# required to use the object.
#
# @param cgi      A reference to the system-wide cgi object.
# @param dbh      A reference to the system DBI object.
# @param settings A reference to the global settings.
# @param logger   A reference to the logger object.
# @return undef on success, otherwise an error message
sub init {
    my $self = shift;

    $self -> {"cgi"} = shift;
    $self -> {"dbh"} = shift;
    $self -> {"settings"} = shift;
    $self -> {"logger"} = shift;

    # Check things are set.
    return "cgi object not set" unless($self -> {"cgi"});
    return "dbh object not set" unless($self -> {"dbh"});
    return "settings object not set" unless($self -> {"settings"});
    return "logger object not set" unless($self -> {"logger"});

    #  All good, return nothing...
    return undef;
}


## @method void set_system($system)
# Set the AppUser's refrence to the system object. This must be done after both
# construction and initialisation, as the system object may not be available
# at either stage.
#
# @param system A reference to the system System object.
sub set_system {
    my $self = shift;
    $self -> {"system"} = shift;
}

# ============================================================================
#  Constants access

## @method $ anonymous_user()
# Obtain the ID of the anonymous user in the system.
#
# @return The ID of the anonymous user account.
sub anonymous_user {
    return ANONYMOUS_ID;
}


## @method $ adminuser_type()
# Obtain the user type that corresponds to admin users.
#
# @return The admin user type number.
sub adminuser_type {
    return ADMIN_TYPE;
}


# ============================================================================
#  User access

## @method $ user_disabled($username)
# Determine whether the specified user's account is disabled. This will check
# that the user's type is 0 or 3, and return false if it is not.
#
# @param username The name of the user to check
# @return true if the user's account is disabled, false if the account is active
#         or does not exist.
sub user_disabled {
    my $self     = shift;
    my $username = shift;

    my $user = $self -> get_user($username);

    return ($user && !($user -> {"user_type"} == 0 || $user -> {"user_type"} == 3));
}


## @method $ get_user_byid($userid, $onlyreal)
# Obtain the user record for the specified user, if they exist. This returns a
# reference to a hash of user data corresponding to the specified userid,
# or undef if the userid does not correspond to a valid user. If the onlyreal
# argument is set, the userid must correspond to 'real' user - bots or inactive
# users are not be returned.
#
# @param userid   The id of the user to obtain the data for.
# @param onlyreal If true, only users of type 0 or 3 are returned.
# @return A reference to a hash containing the user's data, or undef if the user
#         can not be located (or is not real)
sub get_user_byid {
    my $self     = shift;
    my $userid   = shift;
    my $onlyreal = shift;

    # Return the user record
    return $self -> _get_user("user_id", $userid, $onlyreal);
}


## @method $ get_user($username, $onlyreal)
# Obtain the user record for the specified user, if they exist. This returns a
# reference to a hash of user data corresponding to the specified userid,
# or undef if the userid does not correspond to a valid user. If the onlyreal
# argument is set, the userid must correspond to 'real' user - bots or inactive
# users are not be returned.
#
# @param username The username of the user to obtain the data for.
# @param onlyreal If true, only users of type 0 or 3 are returned.
# @return A reference to a hash containing the user's data, or undef if the user
#         can not be located (or is not real)
sub get_user {
    my $self     = shift;
    my $username = shift;
    my $onlyreal = shift;

    return $self -> _get_user("username", $username, $onlyreal, 1);
}


## @method $ get_user_authmethod($username)
# Attempt to obtain the auth method id set for the user with the specified
# username. If the user does not exist, or does not have an authmethod set,
# this returns undef, otherwise it returns the id of the auth method the
# user last logged in using.
#
# @param username The username of the user to fetch the auth method id for.
# @return The auth method id to try to authenticate the user with, or undef.
sub get_user_authmethod {
    my $self     = shift;
    my $username = shift;

    my $user = $self -> get_user($username);
    return $user -> {"user_auth"} if($user);

    return undef;
}


## @method $ set_user_authmethod($username, $methodid)
# Set the auth method id for the specified user. This attempts to update
# the user_auth field for the user with the specified username, it does
# not verify that the methodid corresponds to a valid method, so the
# caller needs to check it. Also note that methodid may be undef, in
# which case the user's auth_method is set to NULL.
#
# @param username The username of the user to update the user_auth field for.
# @param methodid The id of the auth method to set for this user, or undef.
# @return true if the user's user_auth field was updated, false on error.
sub set_user_authmethod {
    my $self     = shift;
    my $username = shift;
    my $methodid = shift;

    my $seth = $self -> {"dbh"} -> prepare("UPDATE ".$self -> {"settings"} -> {"database"} -> {"users"}."
                                            SET user_auth = ?
                                            WHERE username LIKE ?");
    my $result = $seth -> execute($methodid, $username)
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Unable to execute user auth update query. Error was: ".$self -> {"dbh"} -> errstr);

    $self -> self_error("Unable to update user auth method, unknown user selected")
        if($result != 1);

    return ($result == 1);
}


# ============================================================================
#  Pre- and Post-auth functions.

## @method $ pre_authenticate($username, $auth)
# Perform any system-specific pre-authentication tasks on the specified
# user. This function is called once, before the system interrogates any
# defined AuthMethod modules, and it allows systems to tailor pre-auth
# tasks to the requirements of the system. For example, this may be used to
# check the username against a table of authorised users.
#
# @note The implementation provided here does no work, and simply returns
#       true in all cases.
#
# @param username The username of the user to perform pre-auth tasks on.
# @param auth     A reference to the auth object calling this.
# @return true if the authentication process should continue, false if the
#         user should not be authenticated or logged in. If this returns
#         false, an error message will be set in the specified auth's
#         errstr field.
sub pre_authenticate {
    my $self     = shift;
    my $username = shift;
    my $auth     = shift;

    # Always return true
    return 1;
}


## @method $ post_authenticate($username, $password, $auth)
# Perform any system-specific post-authentication tasks on the specified
# user's data. This function allows each system to tailor post-auth tasks
# to the requirements of the system. This function is only called if
# authentication has been successful (one of the AuthMethods has indicated
# that the user's credentials are valid), and if it returns undef the
# authentication is treated as having failed even if the user's credentials
# are valid.
#
# @note The implementation provided here will create an empty user record
#       if one with the specified username does not already exist. The
#       user is initialised as a type 0 ('normal') user, with default
#       values for all the fields. If this behaviour is not required or
#       desirable, subclasses may wish to override this function completely.
#
# @param username The username of the user to perform post-auth tasks on.
# @param password The password the user authenticated with.
# @param auth     A reference to the auth object calling this.
# @return A reference to a hash containing the user's data on success,
#         undef otherwise. If this returns undef, an error message will be
#         set in the specified auth's errstr field.
sub post_authenticate {
    my $self     = shift;
    my $username = shift;
    my $auth     = shift;

    # Determine whether the user exists. If not, create the user.
    my $user = $self -> get_user($username);
    if(!$user) {
        # No record for this user, need to make one...
        my $newuser = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"users"}."
                                                   (username, created, last_login)
                                                   VALUES(?, UNIX_TIMESTAMP(), UNIX_TIMESTAMP())");
        $newuser -> execute($username)
            or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "FATAL: Unable to create new user record: ".$self -> {"dbh"} -> errstr);

        $user = $self -> get_user($username);
    }

    return $auth -> self_error("User addition failed.")
        if(!$user);

    # Touch the user's record...
    my $pokeh = $self -> {"dbh"} -> prepare("UPDATE ".$self -> {"settings"} -> {"database"} -> {"users"}."
                                             SET last_login = UNIX_TIMESTAMP()
                                             WHERE user_id = ?");
    $pokeh -> execute($user -> {"user_id"})
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "FATAL: Unable to update user record: ".$self -> {"dbh"} -> errstr);

    # All done...
    return $user;
}


# ============================================================================
#  Internal functions

## @method private $ _get_user($field, $value, $onlyreal, $uselike)
# Internal implementation of the get_user facility. This allows users to be
# searched for on any given user field, and if the user is found it returns
# the user's data, undef otherwise. If the onlyreal argument is set, the user
# must correspond to 'real' user - bots or inactive users are not be returned.
#
# @param field    The name of the column to search for users on. If the column
#                 contains values that are not unique per user, only the first
#                 match is returned (ie: don't search on non-unique columns.)
# @param value    The value to search for in the user table.
# @param onlyreal If true, only users of type 0 or 3 are returned.
# @param uselike  If true the search uses 'LIKE' instead of exact comparison.
# @return A reference to a hash containing the user's data, or undef if the user
#         can not be located (or is not real)
sub _get_user {
    my $self     = shift;
    my $field    = shift;
    my $value    = shift;
    my $onlyreal = shift;
    my $uselike  = shift;

    my $userh = $self -> {"dbh"} -> prepare("SELECT * FROM ".$self -> {"settings"} -> {"database"} -> {"users"}."
                                             WHERE $field ".($uselike ? "LIKE" : "=")." ?".
                                            ($onlyreal ? " AND user_type IN (0,3)" : ""));
    $userh -> execute($value)
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Unable to execute user lookup query. Error was: ".$self -> {"dbh"} -> errstr);

    return $userh -> fetchrow_hashref();
}

1;
