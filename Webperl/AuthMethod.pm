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
# along with this program.  If not, see http://www.gnu.org/licenses/.

## @class
# The base class for all authentication method classes. This class is
# mainly present for documentation purposes - it doesn't actually provide
# any meaningful implementation of an authentication method, and the
# actually interesting stuff should happen in subclasses of it.
package Webperl::AuthMethod;

use strict;
use base qw(Webperl::SystemModule);

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Construct a new AuthMethod object. This will create a new AuthMethod object
# initialised with the provided arguments.
#
# @param args A hash of arguments to initialise the AuthMethod object with.
# @return A new AuthMethod object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self = $class -> SUPER::new(@_)
        or return undef;

    $self -> {"capabilities"} = {"activate"           => 0,
                                 "activate_message"   => $self -> {"noactivate_message"}   || $self -> {"settings"} -> {"config"} -> {"AuthMethod::noactivate_message"},
                                 "recover"            => 0,
                                 "recover_message"    => $self -> {"norecover_message"}    || $self -> {"settings"} -> {"config"} -> {"AuthMethod::norecover_message"},
                                 "passchange"         => 0,
                                 "passchange_message" => $self -> {"nopasschange_message"} || $self -> {"settings"} -> {"config"} -> {"AuthMethod::nopasschange_message"},
                                 "failcount"          => 0,
                                 "failcount_message"  => $self -> {"nofailcount_message"}  || $self -> {"settings"} -> {"config"} -> {"AuthMethod::nofailcount_message"},
                                };

    return $self;
}


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


## @method $ capabilities($capability)
# Interrogate the capabilities of the authentication method. This will either
# return a reference to a hash containing the capability information for the
# auth method or, if a valid capability argument is specified, this returns
# the value for that capability.
#
# @param capability The optional name of the capability to obtain the value for.
# @return If no 'capabilities' argument is provided, a reference to a hash
#         containing all of the authmethod's capabilities. If a capability is
#         specified, this returns the value for it, or undef if the requested
#         capability is unknown.
sub capabilities {
    my $self       = shift;
    my $capability = shift;

    return($self -> {"capabilities"} -> {$capability})
        if($capability && $self -> {"capabilities"});

    return $self -> {"capabilities"};
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
    return $self -> self_error($self -> capabilities("activate_message"));
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
    return $self -> self_error($self -> capabilities("activate_message"));
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
    return $self -> self_error($self -> capabilities("recover_message"));
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
    return $self -> self_error($self -> capabilities("passchange_message"));
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
    return $self -> self_error($self -> capabilities("passchange_message"));
}


## @method $ force_passchange($userid)
# Determine whether the user needs to reset their password (either because they are
# using a temporary system-allocated password, or the password policy requires it).
#
# If a password expiration policy is in use, `policy_max_passwordage` should be set
# in the auth_method_params for the applicable authmethods. The parameter should contain
# the maximum age of any given password in seconds. If not set, expiration is not
# enforced.
#
# @param userid The ID of the user to check for password change requirement.
# @return A string indicating why the user must change their password if they need
#         to, the empty string if they do not, undef on error.
sub force_passchange {
    my $self   = shift;
    my $userid = shift;

    # By default, AuthMethods do not support password changing, so they can't force it.
    return ''
}


## @method @ mark_loginfail($userid)
# Increment the login failure count for the specified user. The following configuration
# parameter (which should be set for each applicable authmethod in the auth_method_params
# table) is used to control the login failure marking process:
#
# - `policy_max_loginfail`, the number of login failures a user may have before their
#   account is deactivated.
#
# @warning Login failure limiting should not be performed unless account activation
#          and password changes are supported. Otherwise the system has no means of
#          preventing attempts to log in past the limit.
#
# @param userid The ID of the user to increment the login failure counter for.
# @return An array containing two values: The first is the number of login failures
#         recorded for the user, the second is the number of allowed failures. If
#         the second value is zero, no failure limiting is being performed. If an error
#         occurs or the user does not exist, both values are undef.
sub mark_loginfail {
    my $self   = shift;
    my $userid = shift;

    # login failure counting is not supported by default, so users never get deactivated.
    return (0, 0);
}


## @method $ apply_policy($password)
# Apply the configured password policy to the specified password string.
# The following configuration parameters (which should be set for each applicable
# authmethod in the auth_method_params table) are used to control the policy. If
# no value is set for a given parameter, the policy is assumed to not care about
# the parameter:
#
# - `policy_min_length`, passwords must be at least this number of characters long.
# - `policy_min_lowercase`, at least this number of lowercase characters must be present.
# - `policy_min_uppercase`, at least this many uppercase characters must be included.
# - `policy_min_digits`, the minimum number of digits that must be used.
# - `policy_min_other`, the number of non-alphanumeric characters that must be present.
# - `policy_min_entropy`, the minimum password entropy (as calculated by Data::Password::Entropy)
#                         to allow for passwords. See
# - `policy_use_cracklib`, if true, passwords are checked using cracklib.
#
# @param password The password string to check against the password policy.
# @return undef if the password passes the password policy, otherwise a reference to
#         a hash, the keys forming the names of the policy rules failed, and the values
#         being array references containing the settings for the policy rule and the value
#         detected.
sub apply_policy {
    my $self     = shift;
    my $password = shift;
    my $failures = {};

    $failures -> {"policy_min_length"} = [ $self -> {"policy_min_length"}, length($password) ]
        if($self -> {"policy_min_length"} && length($password) < $self -> {"policy_min_length"});

    my $lowercount = $password =~ tr/a-z//;
    $failures -> {"policy_min_lowercase"} = [ $self -> {"policy_min_lowercase"}, $lowercount ]
        if($self -> {"policy_min_lowercase"} && $lowercount < $self -> {"policy_min_lowercase"});

    my $uppercount = $password =~ tr/A-Z//;
    $failures -> {"policy_min_uppercase"} = [ $self -> {"policy_min_uppercase"}, $uppercount ]
        if($self -> {"policy_min_uppercase"} && $uppercount < $self -> {"policy_min_uppercase"});

    my $digitcount = $password =~ tr/0-9//;
    $failures -> {"policy_min_digits"} = [ $self -> {"policy_min_digits"}, $digitcount ]
        if($self -> {"policy_min_digits"} && $digitcount < $self -> {"policy_min_digits"});

    my $othercount = length($password) - ($lowercount + $uppercount + $digitcount);
    $othercount = 0 if($othercount < 0); # Impossibru! But check it anyway.
    $failures -> {"policy_min_others"} = [ $self -> {"policy_min_others"}, $othercount ]
        if($self -> {"policy_min_others"} && $othercount < $self -> {"policy_min_others"});

    # Check against Data::Password::Entropy if possible
    if($self -> {"policy_min_entropy"}) {
        # Load the entropy module at runtime, so that systems that don't test entropy don't need it...
        eval {
            require Data::Password::Entropy;
            Data::Password::Entropy -> import();
        };

        # Handle attempted load that fails. This is transparent to users, which may be a bad thing....
        if($@) {
            $self -> {"logger"} -> log("error", 0, undef, "policy_min_entropy is set, but unable to load Data::Password::Entropy!");
        } else {
            my $entropy = password_entropy($password);
            $failures -> {"policy_min_entropy"} = [ $self -> {"policy_min_entropy"}, $entropy ]
                if($entropy < $self -> {"policy_min_entropy"});
        }
    }

    # Potentially invoke cracklib
    if($self -> {"policy_use_cracklib"}) {
        # Load the cracklib module at runtime, so that systems that don't test against it don't need it...
        eval {
            require Crypt::Cracklib;
            Crypt::Cracklib -> import();
        };

        # Handle attempted load that fails. This is transparent to users, which may be a bad thing....
        if($@) {
            $self -> {"logger"} -> log("error", 0, undef, "policy_use_cracklib is set, but unable to load Crypt::Cracklib!");
        } else {
            my $crackres = fascist_check($password);

            $failures -> {"policy_use_cracklib"} = [1, $crackres]
                if($crackres ne "ok");
        }
    }

    return scalar(keys(%$failures)) ? $failures : undef;
}


## @method $ get_policy()
# Obtain a hash containing the password policy settings. This generates a hash containing
# the details of the password policy (effectively, all 'policy_*' values set for the
# current AuthMethod) and returns a reference to it.
#
# @return A reference to a hash containing the AuthMethod's policy settings, if no
#         policy is currently in place, this returns undef.
sub get_policy {
    my $self = shift;
    my %policy;

    # Get the list of keys that start 'policy_'
    my @policy_keys = grep {/^policy_/} keys %{$self};

    # And a hash slice from those keys.
    @policy{@policy_keys} = @$self{@policy_keys};

    return scalar(%policy) ? \%policy : undef;
}


1;
