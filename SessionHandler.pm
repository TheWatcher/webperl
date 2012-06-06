## @file
# This file contains the implementation of the perl session class.
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
# The SessionHandler class provides cookie-based session facilities for
# maintaining user state over http transactions. This code provides session
# verification, and takes some steps towards ensuring security against
# cookie hijacking, but as with any cookie based auth system there is
# the potential for security issues.
#
# To initialise session handling in your code, simply create a new SessionHandler
# object and ensure that, when sending the header back to the client, you send
# the cookies obtained via session_cookies() to the client. If the user did not
# send any cookies with their request, the new session will be anonymous,
# otherwise the session cookies are validated. If the session is invalid (timed
# out, junk, or hijacked) it is replaced with an anonymous session, otherwise
# its timestamp is updated.
#
# To convert an initially anonymous session into a logged-in session,
# call create_session() with the user's userid. This will update the user's
# session cookies - you only need to call create_session the once when the
# user logs in, from that point the user will remain logged in until the
# cookies are deleted or time out. To log a user out, call delete_session().
#
# SessionHandler provides functions that wrap access to the authenticator
# object (see below about this) - while you can access it directly via
# `my $sess = SessionHandler -> new(...); $sess -> {"auth"} -> whatever()`,
# methods that wrap the most common operations are provided in SessionHandler
# and you are encouraged to use them for readability and futureproofing. The
# following convenience methods are provided for interacting with the
# authenticator:
#
# - get_session_userid() obtains the id of the session user
# - get_user_byid() obtains the user record for a specified user, or the
#   current session user if no userid is specified.
# - valid_user() returns true if the provided user credentials are valid,
#   false if they are not.
# - auth_error() lets you fetch the authenticator's `lasterr` message.
# - anonymous_session() returns true if the session is anonymous, false
#   if the session belongs to a logged-in user.
# - admin_session() returns true if the session belongs to a logged-in admin
#   user.
#
# When creating a new SessionHandler, you must provide an authenticator
# object. The authenticator object should encapsulate interaction with the
# user table, and must provide at least the following functions and values:
#
# - `$auth -> {"ANONYMOUS"}` should contain the ID of the anonymous (not logged in) user.
# - `$ get_config($name)` should return a string, the value of which depends on the value
#   set for the specified configuration variable. The used variables are:
#   + `allow_autologin`: Should be set to 1 to allow automatic logins, 0 or missing to disable them.
#   + `max_autologin_time`: How long should autologins last, should be something like '30d'. Defaults to 356d.
#   + `ip_check`: How may pieces of IP should be checked to verify user sessions. 0 = none, 4 = all four IP parts.
#   + `session_length`: How long should sessions last, in seconds.
#   + `session_gc`: How frequently should sessions be garbage collected, in seconds.
# - `$ get_user_byid($userid, $onlyreal)` - should return a reference to a hash of user
#   data corresponding to the specified userid, or undef if the userid does not
#   correspond to a valid user. If the onlyreal argument is set, the userid must correspond
#   to a 'real' user - bots or inactive users should not be returned. The hash must
#   contain at least:
#   + `user_id` - the user's unique id
#   + `user_type` - 0 = normal user, 1 = inactive, 2 = bot/anonymous, 3 = admin
#   + `username` - the user's username
# - `$ unique_id($extra)` - should return a unique id number. 'Uniqueness' is only important
#   from the point of view of using the id as part of session id calculation. The extra
#   argument allows the addition of an arbitrary string to the seed used to create the id.
#
# This code is heavily based around the session code used by phpBB3, with
# features removed or added to fit the different requirements of the
# framework.
#
# This class requires three database tables: one for sessions, one for session keys (used
# for autologin), and one for session variables. If autologins are permanently disabled
# (that is, you can guarantee that `get_config("allow_autologin")` always returns false)
# then the `session_keys` table may be omitted. If session variables are not needed then
# the `session_variables` table may also be omitted. The tables should be as follows:
#
# A session table, the name of which is stored in the configuration as `{"database"} -> {"sessions"}`:
#
#     CREATE TABLE `sessions` (
#      `session_id` char(32) NOT NULL,
#      `session_user_id` mediumint(9) unsigned NOT NULL,
#      `session_start` int(11) unsigned NOT NULL,
#      `session_time` int(11) unsigned NOT NULL,
#      `session_ip` varchar(40) NOT NULL,
#      `session_autologin` tinyint(1) unsigned NOT NULL,
#      PRIMARY KEY (`session_id`),
#      KEY `session_time` (`session_time`),
#      KEY `session_user_id` (`session_user_id`)
#     ) DEFAULT CHARSET=utf8 COMMENT='Website sessions';
#
# A session key table, the name of which is in `{"database"} -> {"keys"}`:
#
#     CREATE TABLE `session_keys` (
#      `key_id` char(32) COLLATE utf8_bin NOT NULL DEFAULT '',
#      `user_id` mediumint(8) unsigned NOT NULL DEFAULT '0',
#      `last_ip` varchar(40) COLLATE utf8_bin NOT NULL DEFAULT '',
#      `last_login` int(11) unsigned NOT NULL DEFAULT '0',
#      PRIMARY KEY (`key_id`,`user_id`),
#      KEY `last_login` (`last_login`)
#     ) DEFAULT CHARSET=utf8 COLLATE=utf8_bin COMMENT='Autologin keys';
#
# A session variables table, the name of which is in `{"database"} -> {"session_variables"}`:
#
#     CREATE TABLE `session_variables` (
#       `session_id` char(32) NOT NULL,
#       `var_name` varchar(80) NOT NULL,
#       `var_value` text NOT NULL,
#       KEY `session_id` (`session_id`),
#       KEY `sess_name_map` (`session_id`,`var_name`)
#     ) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Session-related variables';
package SessionHandler;

require 5.005;
use strict;

# Standard module imports
use DBI;
use Digest::MD5 qw(md5_hex);
use Compress::Bzip2;
use MIME::Base64;

use Data::Dumper;

# Globals...
our $errstr;

BEGIN {
    $errstr = '';
}

# ============================================================================
#  Constructor

## @cmethod SessionHandler new(@args)
# Create a new SessionHandler object, and start session handling.
#
# @param args A hash of key, value pairs to initialise the object with.
# @return     A reference to a new SessionHandler object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = {
        cgi       => undef,
        dbh       => undef,
        auth      => undef,
        settings  => undef,
        @_,
    };

    # Ensure that we have objects that we need
    return set_error("cgi object not set") unless($self -> {"cgi"});
    return set_error("dbh object not set") unless($self -> {"dbh"});
    return set_error("auth object not set") unless($self -> {"auth"});
    return set_error("settings object not set") unless($self -> {"settings"});

    # Bless class so we canuse it properly
    $self = bless $self, $class;

    # cleanup if necessary
    return undef
        unless($self -> session_cleanup());

    # Determine the name of the cookie, and fall over if it isn't available for some reason
    my $cookiebase = $self -> {"settings"} -> {"config"} -> {"cookie_name"}
        or return set_error("Unable to determine sessioncookie name");

    # Now try to obtain a session id - start by looking at the cookies
    $self -> {"sessid"}   = $self -> {"cgi"} -> cookie($cookiebase."_sid"); # The session id cookie itself
    $self -> {"sessuser"} = $self -> {"cgi"} -> cookie($cookiebase."_u");   # Which user does this session claim to be for?
    $self -> {"autokey"}  = $self -> {"cgi"} -> cookie($cookiebase."_k");   # Do we have an autologin key for the user?

    # If we don't have a session id now, try to pull it from the query string
    $self -> {"sessid"} = $self -> {"cgi"} -> param("sid") if(!$self -> {"sessid"});

    # If we have a session id, we need to check it
    if($self -> {"sessid"}) {
        # Try to get the session...
        my $session = $self -> get_session($self -> {"sessid"});

        # Do we have a valid session?
        if($session) {
            $self -> {"session_time"} = $session -> {"session_time"};

            # Does the user in the session match the one in the cookie?
            if($self -> {"sessuser"} == $session -> {"session_user_id"}) {

                # Does the user exist, and is their account enabled?
                my $userdata = $self -> {"auth"} -> get_user_byid($self -> {"sessuser"});
                if($userdata && ($userdata -> {"user_type"} == 0 || $userdata -> {"user_type"} == 3)) {

                    # Is the user accessing the site from the same(-ish) IP address?
                    if($self -> ip_check($ENV{"REMOTE_ADDR"}, $session -> {"session_ip"})) {
                        # Has the session expired?
                        if(!$self -> session_expired($session)) {
                            # The session is valid, and can be touched.
                            $self -> touch_session($session);

                            return $self;
                        } # if(!$self -> session_expired($session)) {
                    } # if($self -> ip_check($ENV{"REMOTE_ADDR"}, $session -> {"session_ip"})) {
                } else {
                    $self -> {"sessuser"} = undef; # bad user id, remove it
                }
            } else {
                $self -> {"sessuser"} = undef; # possible spoofing attempt, kill it
            } # if($self -> {"sessuser"} == $session -> {"session_user_id"}) {
        } # if($session) {
    } # if($sessid) {

    # Get here, and we don't have a session at all, so make one.
    return $self -> create_session();
}


## @method $ create_session($user, $persist, $initvars)
# Create a new session. If the user is not specified, this creates an anonymous session,
# otherwise the session is attached to the user. Generally you will only ever call this
# immediately upon logging a user in - otherwise session maintainence is handled for you.
#
# @param user     Optional user ID to associate with the session.
# @param persist  If true, and autologins are permitted, an autologin key is generated for
#                 this session.
# @param initvars Optional reference to a hash of initial session variables to set for the
#                 new session.
# @return true if the session was created, undef otherwise.
sub create_session {
    my $self     = shift;
    my $user     = shift;
    my $persist  = shift;
    my $initvars = shift;
    my $userdata;

    # nuke the cookies, it's the only way to be sure
    delete($self -> {"cookies"}) if($self -> {"cookies"});

    # get the current time...
    my $now = time();

    # If persistent logins are not permitted, disable them
    $self -> {"autokey"} = $persist = '' if(!$self -> {"auth"} -> get_config("allow_autologin"));

    # Set a default last visit, might be updated later
    $self -> {"last_visit"} = $now;

    # If we have a key, and a user in the cookies, try to get it
    if($self -> {"autokey"} && $self -> {"sessuser"} && $self -> {"sessuser"} != $self -> {"auth"} -> {"ANONYMOUS"}) {
        my $autocheck = $self -> {"dbh"} -> prepare("SELECT user_id FROM ".$self -> {"settings"} -> {"database"} -> {"keys"}." AS k
                                                    WHERE k.key_id = ?");
        $autocheck -> execute(md5_hex($self -> {"autokey"}))
            or return set_error("Unable to peform key lookup query\nError was: ".$self -> {"dbh"} -> errstr);

        my $keyid = $autocheck -> fetchrow_hashref;

        # Do the key and user match? If so, fetch the user's data.
        $userdata = $self -> {"auth"} -> get_user_byid($self -> {"sessuser"}, 1)
            if($keyid && $keyid -> {"user_id"} == $self -> {"sessuser"});

    # If we don't have a key and user in the cookies, do we have a user specified?
    } elsif($user) {
        $self -> {"autokey"} = '';
        $self -> {"sessuser"} = $user;
        $self -> {"sessid"}   = undef;

        $userdata = $self -> {"auth"} -> get_user_byid($user, 1);
    }

    # If we don't have any user data then either the key didn't match in the database,
    # the user doesn't exist, is inactive, or is a bot. Just get the anonymous user
    if(!$userdata) {
        $self -> {"autokey"} = '';
        $self -> {"sessid"}   = undef;
        $self -> {"sessuser"} = $self -> {"auth"} -> {"ANONYMOUS"};

        $userdata = $self -> {"auth"} -> get_user_byid($self -> {"sessuser"});

        # Give up if we can't get the anonymous user.
        return set_error("Unable to fall back on anonymous user: user does not exist") if(!$userdata);

    # If we have user data, we also want their last login time if possible
    } elsif($self -> {"settings"} -> {"detabase"} -> {"lastvisit"}) {
        my $visith = $self -> {"dbh"} -> prepare("SELECT last_visit FROM ".$self -> {"settings"} -> {"detabase"} -> {"lastvisit"}.
                                                 " WHERE user_id = ?");
        $visith -> execute($userdata -> {"user_id"})
            or return set_error("Unable to peform last visit lookup query\nError was: ".$self -> {"dbh"} -> errstr);

        my $visitr = $visith -> fetchrow_arrayref;

        # Fall back on now if we have no last visit time
        $self -> {"last_visit"} = $visitr -> [0] if($visitr);
    }

    # Determine whether the session can be made persistent (requires the user to be registered, and normal)
    my $is_registered = ($userdata && $userdata -> {"user_id"} && $userdata -> {"user_id"} != $self -> {"auth"} -> {"ANONYMOUS"} && ($userdata -> {"user_type"} == 0 || $userdata -> {"user_type"} == 3));
    $persist = (($self -> {"autokey"} || $persist) && $is_registered) ? 1 : 0;

    # Do we already have a session id? If we do, and it's an anonymous session, we want to nuke it
    if($self -> {"sessid"}) {
        my $killsess = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"sessions"}.
                                                   " WHERE session_id = ? AND session_user_id = ?");
        $killsess -> execute($self -> {"sessid"}, $self -> {"auth"} -> {"ANONYMOUS"})
            or return set_error("Unable to remove anonymous session\nError was: ".$self -> {"dbh"} -> errstr);
    }

    # generate a new session id. The md5 of a unique ID should be unique enough...
    $self -> {"sessid"} = md5_hex($self -> {"auth"} -> unique_id());

    # store the time
    $self -> {"session_time"} = $now;

    # create a new session
    my $sessh = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"sessions"}.
                                            "(session_id, session_user_id, session_start, session_time, session_ip, session_autologin)
                                             VALUES(?, ?, ?, ?, ?, ?)");
    $sessh -> execute($self -> {"sessid"},
                      $self -> {"sessuser"},
                      $now,
                      $now,
                      $ENV{"REMOTE_ADDR"},
                      $persist)
            or return set_error("Unable to peform session creation\nError was: ".$self -> {"dbh"} -> errstr);

    $self -> set_login_key($self -> {"sessuser"}, $ENV{"REMOTE_ADDR"}) if($persist);

    # set any initial variables if needed.
    if($initvars) {
        foreach my $var (keys(%{$initvars})) {
            $self -> set_variable($var, $initvars -> {$var});
        }
    }

    return $self;
}


## @method $ delete_session()
# Delete the current session, resetting the user's data to anonymous. This will
# remove the user's current session, and any associated autologin key, and then
# generate a new anonymous session for the user.
#
# @return true if the session was created, undef otherwise.
sub delete_session {
    my $self = shift;

    # Okay, the important part first - nuke the session
    my $nukesess = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"sessions"}.
                                               " WHERE session_id = ? AND session_user_id = ?");
    $nukesess -> execute($self -> {"sessid"}, $self -> {"sessuser"})
        or return set_error("Unable to remove session\nError was: ".$self -> {"dbh"} -> errstr);

    # If we're not dealing with anonymous, we need to store the visit time,
    # and nuke any autologin key for the now defunct session
    if($self -> {"sessuser"} != $self -> {"auth"} -> {"ANONYMOUS"}) {

        # If we don't have a session time for some reason, make it now
        $self -> {"session_time"} = time() if(!$self -> {"session_time"});

        # set this user's last visit time to the session time if possible
        if($self -> {"settings"} -> {"database"} -> {"lastvisit"}) {
            my $newtime = $self -> {"dbh"} -> prepare("UPDATE ".$self -> {"settings"} -> {"database"} -> {"lastvisit"}.
                                                      " SET last_visit = ?
                                                        WHERE user_id = ?");
            $newtime -> execute($self -> {"session_time"}, $self -> {"sessuser"})
                or return set_error("Unable to update last visit time\nError was: ".$self -> {"dbh"} -> errstr);
        }

        # And now remove any session keys
        if($self -> {"autokey"}) {
            my $nukekeys = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"keys"}.
                                                       " WHERE key_id = ? AND user_id = ?");
            $nukekeys -> execute(md5_hex($self -> {"autokey"}), $self -> {"sessuser"})
                or return set_error("Unable to remove session key\nError was: ".$self -> {"dbh"} -> errstr);
        }
    }

    # clear all the session settings internally for safety
    $self -> {"sessuser"} = $self -> {"sessid"} = $self -> {"autokey"} = $self -> {"session_time"} = undef;

    # And create a new anonymous session (note that create_session should handle deleting the cookie cache!)
    return $self -> create_session();
}


## @method $ encode_querystring($query, $nofix)
# Encode the query string so that it is safe to include it in a hidden input field
# in the login form.
#
# @param query The querystring to encode
# @param nofix If true, this disables the fix needed to make CGI::query_string()'s output usable.
# @return The safely encoded querystring.
sub encode_querystring {
    my $self   = shift;
    my $query  = shift;
    my $nofix  = shift;

    $query =~ s/;/&/g unless($nofix); # fix query_string() return... GRRRRRRR...

    return encode_base64($query, '');
}


## @method $ decode_querystring($query)
# Converts the encoded query string back to standard query string form.
#
# @param query The encoded querystring to decode
# @return The decoded version of the querystring.
sub decode_querystring {
    my $self   = shift;
    my $query  = shift;

    # Bomb if we don't have a query, or it is not valid base64
    return "" if(!$query || $query =~ m{[^A-Za-z0-9+/=]});

    return decode_base64($query);
}


## @method $ session_cookies()
# Obtain a reference to an array containing the session cookies.
#
# @return A reference to an array of session cookies.
sub session_cookies {
    my $self = shift;

    # Cache the cookies if needed, calls to create_session should ensure the cache is
    # removed before any changes are made... but this shouldn't really be called before
    # create_session in reality anyway.
    if(!$self -> {"cookies"}) {
        my $expires = "+".($self -> {"auth"} -> get_config("max_autologin_time") || 365)."d";
        my $sesscookie = $self -> create_cookie($self -> {"settings"} -> {"config"} -> {"cookie_name"}.'_sid', $self -> {"sessid"}, $expires);
        my $sessuser   = $self -> create_cookie($self -> {"settings"} -> {"config"} -> {"cookie_name"}.'_u', $self -> {"sessuser"}, $expires);
        my $sesskey;
        if($self -> {"sessuser"} != $self -> {"auth"} -> {"ANONYMOUS"}) {
            if($self -> {"autokey"}) {
                $sesskey = $self -> create_cookie($self -> {"settings"} -> {"config"} -> {"cookie_name"}.'_k', $self -> {"autokey"}, $expires);
            }
        } else {
            $sesskey = $self -> create_cookie($self -> {"settings"} -> {"config"} -> {"cookie_name"}.'_k', '', '-1y');
        }

        $self -> {"cookies"} = [ $sesscookie, $sessuser, $sesskey ];
    }

    return $self -> {"cookies"};
}


# ============================================================================
#  User/auth abstraction
#  These functions are really just here to hide the innards away

## @method $ get_session_userid()
# Obtain the id of the session user. This will return the id of the user attached
# to the current session.
#
# @return The id of the session user. This should always be a positive integer.
sub get_session_userid {
    my $self = shift;

    return $self -> {"sessuser"};
}


## @method $ get_user_byid($userid, $onlyreal)
# Obtain the user record for the specified user, if they exist. This should
# return a reference to a hash of user data corresponding to the specified userid,
# or undef if the userid does not correspond to a valid user. If the onlyreal
# argument is set, the userid must correspond to 'real' user - bots or inactive
# users should not be returned.
#
# @param userid   The id of the user to obtain the data for. If not specified,
#                 the current session userid is used instead.
# @param onlyreal If true, only users of type 0 or 3 are returned.
# @return A reference to a hash containing the user's data, or undef if the user
#         can not be located (or is not real)
sub get_user_byid {
    my $self     = shift;
    my $userid   = shift;
    my $onlyreal = shift;

    # Fall back on the session user if no userid is given.
    $userid = $self -> {"sessuser"} if(!defined($userid));

    return $self -> {"auth"} -> get_user_byid($userid, $onlyreal);
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
    my $onlyreal = shift || 0;

    return $self -> {"auth"} -> get_user($username, $onlyreal);
}


## @method $ valid_user($username, $password)
# Determine whether the specified user is valid, and obtain their user record.
# This will authenticate the user, and if the credentials supplied are valid, the
# user's internal record will be returned to the caller.
#
# @param username The username to check.
# @param password The password to check.
# @return A reference to a hash containing the user's data if the user is valid,
#         undef if the user is not valid. If this returns undef, the reason can be
#         obtained from auth_error(). Note that this may return a user AND set a
#         value that can be obtained via auth_error(), in which case the value in
#         question is a warning regarding the user...
sub valid_user {
    my $self     = shift;
    my $username = shift;
    my $password = shift;

    return $self -> {"auth"} -> valid_user($username, $password);
}


## @method $ auth_error()
# Obtain the last error message generated by the authentication object. This will
# return the error message generated during the last auth object method call, or
# the empty string if no errors were generated.
#
# @return An error message generated during the last auth object method call, or
#         '' if the call generated no errors.
sub auth_error {
    my $self = shift;

    return $self -> {"auth"} -> {"lasterr"};
}


## @method $ anonymous_session()
# Determine whether the current session is anonymous (no currently logged-in user).
#
# @return True if the current session is anonymous, false if the session has
#         a real user attached to it.
sub anonymous_session {
    my $self = shift;

    return (!defined($self -> {"sessuser"}) || $self -> {"sessuser"} == $self -> {"auth"} -> {"ANONYMOUS"});
}


## @method $ admin_session()
# Determine whether the current session user is an admin.
#
# @return True if the current session user is an admin (has user_type of 3),
#         false if the user is not an admin.
sub admin_session {
    my $self = shift;

    my $user = $self -> {"auth"} -> get_user_byid($self -> {"sessuser"});
    return ($user && $user -> {"user_type"} == 3);
}


# ============================================================================
#  Session variables

## @method $ set_variable($name, $value)
# Set the value for a session variable for the current session. This sets the
# variable for the session identified by `name` to the specified value,
# overwriting any previous value.
#
# @note If `session_variables` is not set in the `database` section of the
#       configuration, calling this function will result in a fatal error.
#
# @param name  The name of the variable to set. Variable names must be 80
#              characters or less, but are otherwise unconstrained.
# @param value The value to set for the variable. This must be a scalar value,
#              references are not supported. If this is undef, the variable
#              is deleted.
# @return The previous contents of the variable, or undef if the variable had
#         not been previously set.
sub set_variable {
    my $self  = shift;
    my $name  = shift;
    my $value = shift;
    $self -> self_error("");

    $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Attempt to use session variables without a session variables table!")
        unless($self -> {"settings"} -> {"database"} -> {"session_variables"});

    $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Unsupported reference passed to set_variable")
        if(ref($value));

    # Does the variable exist already?
    my $oldvalue = $self -> get_variable($name);
    if(defined($oldvalue)) {
        # Yes, remove the old value
        my $hukeh = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"session_variables"}."
                                                 WHERE session_id = ?
                                                 AND var_name LIKE ?");
        $hukeh -> execute($self -> {"sessid"}, $name)
            or return $self -> self_error("Unable to look up session variable\nError was: ".$self -> {"dbh"} -> errstr);
    }

    # If a new value has been specified, insert it
    if(defined($value)) {
        my $newh = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"session_variables"}."
                                                (session_id, var_name, var_value)
                                                VALUES(?, ?, ?)");
        $newh -> execute($self -> {"sessid"}, $name, $value)
            or return $self -> self_error("Unable to set session variable\nError was: ".$self -> {"dbh"} -> errstr);
    }

    return $oldvalue;
}


## @method $ get_variable($name)
# Obtain the value for the specified session variable. This returns the value set
# for the session variable with the given name associated with the current session,
# or undef if the value is not set. Note that, if the value has somehow been set
# to undef (which should not be possible through set_value!), this will return the
# empty string instead! Undef is only returned iff the named variable does not
# appear in the session's variable list.
#
# @param name The name of the session variable to get. Variable names must be 80
#             characters or less, but are otherwise unconstrained.
# @return The contents of the variable, or undef if it does not exist.
sub get_variable {
    my $self = shift;
    my $name = shift;
    $self -> self_error("");

    my $geth = $self -> {"dbh"} -> prepare("SELECT var_value FROM ".$self -> {"settings"} -> {"database"} -> {"session_variables"}."
                                            WHERE session_id = ?
                                            AND var_name LIKE ?");
    $geth -> execute($self -> {"sessid"}, $name)
        or return $self -> self_error("Unable to look up session variable\nError was: ".$self -> {"dbh"} -> errstr);

    my $valrow = $geth -> fetchrow_arrayref();

    return $valrow ? ($valrow -> [0] || "") : undef;
}


# ==============================================================================
# Theoretically internal stuff

## @method private $ ip_check($userip, $sessip)
# Checks whether the specified IPs match. The degree of match required depends
# on the ip_check setting in the SessionHandler object this is called on: 0 means
# that no checking is done, number between 1 and 4 indicate sections of the
# dotted decimal IPs are checked (1 = 127., 2 = 127.0, 3 = 127.0.0., etc)
#
# @param userip The IP the user is connecting from.
# @param sessip The IP associated with the session.
# @return True if the IPs match, false if they do not.
sub ip_check {
    my $self   = shift;
    my $userip = shift;
    my $sessip = shift || "";

    # How may IP address segments should be compared?
    my $iplen = $self -> {"auth"} -> get_config('ip_check');

    # bomb immediately if we aren't checking IPs
    return 1 if($iplen == 0);

    # pull out as much IP as we're interested in
    my ($usercheck) = $userip =~ /((?:\d+.?){$iplen})/;
    my ($sesscheck) = $sessip =~ /((?:\d+.?){$iplen})/;

    # Do the IPs match?
    return $sesscheck && ($usercheck eq $sesscheck);
}


## @method private $ session_cleanup()
# Run garbage collection over the sessions table. This will remove all expired
# sessions and session keys, but in the process it may need to update user
# last visit information.
#
# @return true on successful cleanup (or cleanup not needed), false on error.
sub session_cleanup {
    my $self = shift;

    my $now = time();
    my $timelimit = $now - $self -> {"auth"} -> get_config("session_length");

    # We only want to run the garbage collect occasionally
    if($self -> {"settings"} -> {"config"} -> {"Session:lastgc"} < $now - $self -> {"auth"} -> get_config("session_gc")) {
        # Okay, we're due a garbage collect, update the config to reflect that we're doing it
        $self -> {"settings"} -> set_db_config("Session:lastgc", $now);

        # Remove expired guest sessions first
        my $nukesess = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"sessions"}.
                                                   " WHERE session_user_id = ?
                                                     AND session_time < ?");
        $nukesess -> execute($self -> {"auth"} -> {"ANONYMOUS"}, $timelimit)
            or return set_error("Unable to remove expired guest sessions\nError was: ".$self -> {"dbh"} -> errstr);

        # now get the most recent expired sessions for each user
        my $lastsess = $self -> {"dbh"} -> prepare("SELECT session_user_id,MAX(session_time) FROM ".$self -> {"settings"} -> {"database"} -> {"sessions"}.
                                                   " WHERE session_time < ?
                                                     GROUP BY session_user_id");
        $lastsess -> execute($timelimit)
            or return set_error("Unable to obtain expired session list\nError was: ".$self -> {"dbh"} -> errstr);

        # Prepare an update query so we don't remake it each time through the loop...
        my $updatelast;
        if($self -> {"settings"} -> {"database"} -> {"lastvisit"}) {
            $updatelast = $self -> {"dbh"} -> prepare("UPDATE ".$self -> {"settings"} -> {"database"} -> {"lastvisit"}.
                                                      " SET last_visit = ?
                                                       WHERE user_id = ?");
        }

        # Go through each returned user updating their last visit to the session time
        while(my $lastrow = $lastsess -> fetchrow_arrayref()) {
            # set the user's last visit if needed
            if($self -> {"settings"} -> {"database"} -> {"lastvisit"}) {
                $updatelast -> execute($lastrow -> [1], $lastrow -> [0])
                    or return set_error("Unable to update last visit for user ".$lastrow -> [0]."\nError was: ".$self -> {"dbh"} -> errstr);
            }

            # and then nuke any expired sessions
            $nukesess -> execute($lastrow -> [0], $timelimit)
                or return set_error("Unable to remove expired sessions for user ".$lastrow -> [0]."\nError was: ".$self -> {"dbh"} -> errstr);
        }
    }

    return 1;
}


## @method private $ session_expired($sessdata)
# Determine whether the specified session has expired. Returns true if it has,
# false if it is still valid.
#
# @param $sessdata A reference to a hash containing the session information
# @return true if the session has expired, false otherwise
sub session_expired {
    my $self = shift;
    my $sessdata = shift;

    # If the session is not an autologin session, and the last update was before the session length, it is expired
    if(!$sessdata -> {"session_autologin"}) {
        return 1 if($sessdata -> {"session_time"} < time() - ($self -> {"auth"} -> get_config("session_length") + 60));

    } else {
        my $max_autologin = $self -> {"auth"} -> get_config("max_autologin_time");

        # If the session is autologin, and it is older than the max autologin time, or autologin is not enabled, it's expired
        return 1 if(!$self -> {"auth"} -> get_config("allow_autologin") ||
                    ($max_autologin && $sessdata -> {"session_time"} < time() - ((86400 * $max_autologin) + 60)));
    }

    # otherwise, the session is valid
    return 0;
}


## @method private $ get_session($sessid)
# Obtain the data for the session with the specified session ID. If there is no
# session with the specified id in the database, this returns undef, otherwise it
# returns a reference to a hash containing the session data.
#
# @param sessid The ID of the session to search for.
# @return A reference to a hash containing the session data, or undef on error.
sub get_session {
    my $self   = shift;
    my $sessid = shift;

    my $sessh = $self -> {"dbh"} -> prepare("SELECT * FROM ".$self -> {"settings"} -> {"database"} -> {"sessions"}.
                                            " WHERE session_id = ?");
    $sessh -> execute($sessid)
        or return set_error("Unable to peform session lookup query - ".$self -> {"dbh"} -> errstr);

    return $sessh -> fetchrow_hashref();
}


## @method private void touch_session($session)
# Touch the specified session, updating its timestamp to the current time. This
# will only touch the session if it has not been touched in the last minute,
# otherwise this function does nothing.
#
# @param session A reference to a hash containing the session data.
sub touch_session {
    my $self    = shift;
    my $session = shift;

    if(time() - $session -> {"session_time"} > 60) {
        $self -> {"session_time"} = time();

        my $finger = $self -> {"dbh"} -> prepare("UPDATE ".$self -> {"settings"} -> {"database"} -> {"sessions"}.
                                                 " SET session_time = ?
                                                   WHERE session_id = ?");
        $finger -> execute($self -> {"session_time"}, $session -> {"session_id"})
            or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Unable to touch session. Error was: ".$self -> {"dbh"} -> errstr);
    }
}


## @method private void set_login_key()
# Create the auto login key for the current session user.
#
sub set_login_key {
    my $self = shift;

    my $key = $self -> {"autokey"};
    my $key_id = $self -> {"auth"} -> unique_id(substr($self -> {"sessid"}, 0, 8));

    # If we don't have a key, we want to create a new key in the table
    if(!$key) {
        my $keyh = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"keys"}.
                                               "(key_id, user_id, last_ip, last_login)
                                                VALUES(?, ?, ?, ?)");
        $keyh -> execute(md5_hex($key_id), $self -> {"sessuser"}, $ENV{REMOTE_ADDR}, time())
            or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Unable to create autologin key. Error was: ".$self -> {"dbh"} -> errstr);

    # If we have a key, we want to overwrite it with the new stuff
    } else {
        my $keyh = $self -> {"dbh"} -> prepare("UPDATE ".$self -> {"settings"} -> {"database"} -> {"keys"}.
                                               " SET key_id = ?, last_ip = ?, last_login = ? WHERE user_id = ? AND key_id = ?");
        $keyh -> execute(md5_hex($key_id), $ENV{REMOTE_ADDR}, 0 + time(), 0 + $self -> {"sessuser"}, md5_hex($key))
            or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Unable to update autologin key. Error was: ".$self -> {"dbh"} -> errstr);
    }

    $self -> {"autokey"} = $key_id;
}


## @method private $ create_cookie($name, $value, $expires)
# Creates a cookie that can be sent back to the user's browser to provide session
# information.
#
# @param name    The name of the cookie to set
# @param value   The value to set for the cookie
# @param expires An optional expiration value
# @return A cookie suitable to send to the browser.
sub create_cookie {
    my $self    = shift;
    my $name    = shift;
    my $value   = shift;
    my $expires = shift;

    return $self -> {"cgi"} -> cookie(-name    => $name,
                                      -value   => $value,
                                      -expires => $expires,
                                      -path    => $self -> {"settings"} -> {"config"} -> {"cookie_path"},
                                      -domain  => $self -> {"settings"} -> {"config"} -> {"cookie_domain"},
                                      -secure  => $self -> {"settings"} -> {"config"} -> {"cookie_secure"});
}


# ============================================================================
#  Error functions

## @cmethod private $ set_error($errstr)
# Set the class-wide errstr variable to an error message, and return undef. This
# function supports error reporting in the constructor and other class methods.
#
# @param errstr The error message to store in the class errstr variable.
# @return Always returns undef.
sub set_error { $errstr = shift; return undef; }


## @method private $ self_error($errstr)
# Set the object's errstr value to an error message, and return undef. This
# function supports error reporting in various methods throughout the class.
#
# @param errstr The error message to store in the object's errstr.
# @return Always returns undef.
sub self_error {
    my $self = shift;
    $self -> {"errstr"} = shift;

    return undef;
}

1;
