## @file
# This file contains the implementation of the multi-method authentication class.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 1.0
# @date    5 March 2012
# @copy    2012, Chris Page &lt;chris@starforge.co.uk&gt;
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
# Authentication support for user logins. This class is intended to interface
# with the SessionHandler class, and provides support for user authentication against
# multiple auth systems in a way that is transparent to the caller. The class works
# by calling on two other modules to do most of the work: it relies on a subclass of
# SystemUser for system-specific user management operations, and the AuthMethods
# class for authentication plugin loading.
#
# This class requires an entry in the settings table with the name 'Auth:unique_id',
# and settings as required by SessionHandler.
package Auth;

use strict;

# Custom module imports
use AuthMethods;
use Logging qw(die_log);

our $errstr;

BEGIN {
	$errstr = '';
}

# ============================================================================
#  Constructor

## @cmethod Auth new(%args)
# Create a new Auth object. This will create an Auth object that may be (for example)
# passed to SessionHandler to provide user authentication. The arguments to this
# constructor must include:
#
# - cgi, a reference to a CGI object.
# - dbh, a reference to the DBI object to issue database queries through.
# - settings, a reference to the global settings object.
# - system, a reference to a SystemUser object to perform user-related db queries through.
#
# @param args A hash of key, value pairs to initialise the object with.
# @return     A reference to a new Auth object on success, undef on failure.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = {
        cgi       => undef,
        dbh       => undef,
        settings  => undef,
        system    => undef,
        @_,
    };

    # Ensure that we have objects that we need
    return set_error("cgi object not set") unless($self -> {"cgi"});
    return set_error("dbh object not set") unless($self -> {"dbh"});
    return set_error("settings object not set") unless($self -> {"settings"});
    return set_error("system object not set") unless($self -> {"system"});

    # Create the authmethods object to handle invocation of individual methods
    $self -> {"methods"} = AuthMethods -> new(cgi      => $self -> {"cgi"},
                                              dbh      => $self -> {"dbh"},
                                              settings => $self -> {"settings"},
                                              system   => $self -> {"system"})
        or return set_error("Unable to create AuthMethods object: ".$Auth::Methods -> errstr);

    $self -> {"ANONYMOUS"} = $self -> {"system"} -> anonymous_user();
    $self -> {"ADMINTYPE"} = $self -> {"system"} -> adminuser_type();

    return bless $self, $class;
}


# ============================================================================
#  Interface code

## @method $ get_config($name)
# Obtain the value for the specified configuration variable.
#
# @param name The name of the configuration variable to return.
# @return The value for the name, or undef if the value is not set.
sub get_config {
    my $self = shift;
    my $name = shift;

    # Make sure the configuration name starts with the appropriate module handle
    $name = "Auth:$name" unless($name =~ /^Auth:/);

    return $self -> {"settings"} -> {"config"} -> {$name};
}


## @method $ unique_id($extra)
# Obtain a unique ID number. This id number is guaranteed to be unique across calls, and
# may contain non-alphanumeric characters. The returned scalar may contain binary data.
#
# @param extra An extra string to append to the id before returning it.
# @return A unique ID. May contain binary data, is guaranteed to start with a number.
sub unique_id {
    my $self  = shift;
    my $extra = shift || "";

    # Potentially not atomic, but putting something in place that is really isn't worth it right now...
    my $id = $self -> {"settings"} -> {"config"} -> {"Auth:unique_id"};
    $self -> {"settings"} -> set_db_config($self -> {"dbh"}, $self -> {"settings"} -> {"database"} -> {"settings"}, "Auth:unique_id", ++$id);

    # Ask urandom for some randomness to combat potential problems with the above non-atomicity
    my $buffer;
    open(RND, "/dev/urandom")
        or die_log($self -> {"cgi"} -> remote_host(), "Unable to open urandom: $!");
    read(RND, $buffer, 24);
    close(RND);

    # append the process id and random buffer to the id we got from the database. The
    # PID should be enough to prevent atomicity problems, the random junk just makes sure.
    return $id.$$.$buffer.$extra;
}


## @method $ get_user_byid($userid, $onlyreal)
# Obtain the user record for the specified user, if they exist. This should
# return a reference to a hash of user data corresponding to the specified userid,
# or undef if the userid does not correspond to a valid user. If the onlyreal
# argument is set, the userid must correspond to 'real' user - bots or inactive
# users should not be returned.
#
# @param userid   The id of the user to obtain the data for.
# @param onlyreal If true, only users of type 0 or 3 are returned.
# @return A reference to a hash containing the user's data, or undef if the user
#         can not be located (or is not real)
sub get_user_byid {
    my $self     = shift;
    my $userid   = shift;
    my $onlyreal = shift || 0;

    return $self -> {"system"} -> get_user_byid($userid, $onlyreal);
}


## @method $ valid_user($username, $password)
# Determine whether the specified user is valid, and obtain their user record.
# This will authenticate the user, and if the credentials supplied are valid, the
# user's internal record will be returned to the caller.
#
# @param username The username to check.
# @param password The password to check.
# @return A reference to a hash containing the user's data if the user is valid,
#         undef if the user is not valid. If this returns undef, the reason is
#         contained in $obj -> {"lasterr"}. Note that this may return a user
#         AND have a value in $obj -> {"lasterr"}, in which case the value in
#         lasterr is a warning regarding the user...
sub valid_user {
    my $self       = shift;
    my $username   = shift;
    my $password   = shift;
    my $valid      = 0;

    $self -> {"lasterr"} = "";

    # Is the user disabled?
    if($self -> {"system"} -> user_blocked($username)) {
        $self -> {"lasterr"} = "This user account has been disabled.";
        return undef;
    }

    # Does the user already have an auth method set?
    my $authmethod = $self -> {"system"} -> get_user_authmethod($username);

    # Try the user's set authmethod if possible
    if($authmethod) {
        my $methodimpl = $self -> {"methods"} -> load_method($authmethod);

        # Check whether the user can authenticate if the implementation was found
        $valid = $methodimpl -> authenticate($username, $password, $self)
            if($methodimpl);
    }

    # If no authmethod was found for the user, or the auth failed and fallback is enabled,
    # all the available auth methods should be checked. Note that !$methodimpl is here so
    # that, if an auth method is removed for some reason, the system will try other auth
    # methods instead.
    if(!$valid && (!$authmethod || !$methodimpl || $self -> {"settings"} -> {"Auth:enable_fallback"})) {
        my $methods = $self -> {"methods"} -> available_methods();

        foreach $authmethod (@{$methods}) {
            my $methodimpl = $self -> {"methods"} -> load_method($authmethod);

            $valid = $methodimpl -> authenticate($username, $password, $self)
                if($methodimpl);

            # If an auth method says the user is valid, stop immediately
            last if($valid);
        }
    }

    # If one of the auth methods succeeded in validating the user, record it
    # invoke the system standard post-auth for the user, and return the user's
    # database record.
    if($valid) {
        $self -> {"system"} -> set_user_authmethod($username, $authmethod);
        $self -> {"lasterr"} = $self -> {"system"} -> post_authenticate($username);

        return $self -> {"system"} -> get_user($username);
    }

    $self -> {"lasterr"} = "Invalid username or password specified.";

    # Authentication failed.
    return undef;
}


# ============================================================================
#  Error functions

sub set_error { $errstr = shift; return undef; }

1;