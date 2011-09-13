## @file
# This file contains the implementation of the perl session class.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 1.1
# @date    13 Sept 2011
# @copy    2011, Chris Page &lt;chris@starforge.co.uk&gt;
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
# This code is heavily based around the session code used by phpBB3, with
# features removed or added to fit the different requirements of the ORB,
# starforge site, etc
#
# When creating a new SessionHandler, you must provide an authenticator
# object. The authenticator object should encapsulate interaction with the
# user table, and must provide at least the following functions and values:
#
# $auth -> {"ANONYMOUS"} - should contain the ID of the anonymous (not logged in)
#                          user.
#
# $ get_config($name) - should return a string, the value of which depends on the
#                       value set for the specified configuration variable. The
#                       used variables are:
#      allow_autologin: Should be set to 1 to allow automatic logins, 0 or missing to disable them.
#   max_autologin_time: How long should autologins last, should be something like '30d'. Defaults to 356d.
#             ip_check: How may pieces of IP should be checked to verify user sessions. 0 = none, 4 = all four IP parts.
#       session_length: How long should sessions last, in seconds.
#           session_gc: How frequently should sessions be garbage collected, in seconds.
#
# $ get_user_byid($userid, $onlyreal) - should return a reference to a hash of user
#                       data corresponding to the specified userid, or undef if the
#                       userid does not correspond to a valid user. If the onlyreal
#                       argument is set, the userid must correspond to 'real' user -
#                       bots or inactive users should not be returned. The hash must
#                       contain at least:
#
#                       user_id   - the user's unique id
#                       user_type - 0 = normal user, 1 = inactive, 2 = bot/anonymous, 3 = admin
#
# $ unique_id($extra) - should return a unique id number. 'Uniqueness' is only important from the point
#                       of view of using the id as part of session id calculation. The extra argument
#                       allows the addition of an arbitrary string to the seed used to create the
#                       id.
#
# This class requires two database tables: one for sessions, one for session keys (used
# for autologin). If autologins are permanently disabled (get_config('allow_autologin') always returns
# false) then the session_keys table may be omitted. The tables should be as follows:
#
# A session table, the name of which is stored in the configuration as {"database"} -> {"sessions"}:
# CREATE TABLE `sessions` (
#  `session_id` char(32) NOT NULL,
#  `session_user_id` mediumint(9) unsigned NOT NULL,
#  `session_start` int(11) unsigned NOT NULL,
#  `session_time` int(11) unsigned NOT NULL,
#  `session_ip` varchar(40) NOT NULL,
#  `session_autologin` tinyint(1) unsigned NOT NULL,
#  PRIMARY KEY (`session_id`),
#  KEY `session_time` (`session_time`),
#  KEY `session_user_id` (`session_user_id`)
# ) DEFAULT CHARSET=utf8 COMMENT='Website sessions';
#
# A session key table, the name of which is in {"database"} -> {"keys"}
# CREATE TABLE `session_keys` (
#  `key_id` char(32) COLLATE utf8_bin NOT NULL DEFAULT '',
#  `user_id` mediumint(8) unsigned NOT NULL DEFAULT '0',
#  `last_ip` varchar(40) COLLATE utf8_bin NOT NULL DEFAULT '',
#  `last_login` int(11) unsigned NOT NULL DEFAULT '0',
#  PRIMARY KEY (`key_id`,`user_id`),
#  KEY `last_login` (`last_login`)
# ) DEFAULT CHARSET=utf8 COLLATE=utf8_bin COMMENT='Autologin keys';
#
package SessionHandler;

require 5.005;
use strict;

# Standard module imports
use DBI;
use Digest::MD5 qw(md5_hex);
use Compress::Bzip2;
use MIME::Base64;

use Data::Dumper;

# Custom module imports
use Logging qw(die_log);

# Globals...
use vars qw{$VERSION $errstr};

BEGIN {
	$VERSION = 0.2;
	$errstr  = '';
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
        template  => undef,
        settings  => undef,
        @_,
    };

    # Ensure that we have objects that we need
    return set_error("cgi object not set") unless($self -> {"cgi"});
    return set_error("dbh object not set") unless($self -> {"dbh"});
    return set_error("auth object not set") unless($self -> {"auth"});
    return set_error("template object not set") unless($self -> {"template"});
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

        $self -> {"session_time"} = $session -> {"session_time"};

        # Do we have a valid session?
        if($session) {
            # Is the user accessing the site from the same(-ish) IP address?
            if($self -> ip_check($ENV{"REMOTE_ADDR"}, $session -> {"session_ip"})) {
                # Has the session expired?
                if(!$self -> session_expired($session)) {
                    # The session is valid, and can be touched.
                    $self -> touch_session($session);

                    return $self;
                } # if(!$self -> session_expired($session)) {
            } # if($self -> ip_check($ENV{"REMOTE_ADDR"}, $session -> {"session_ip"})) {
        } # if($session) {
    } # if($sessid) {

    # Get here, and we don't have a session at all, so make one.
    return $self -> create_session();
}


## @method $ create_session($user, $persist)
# Create a new session. If the user is not specified, this creates an anonymous session,
# otherwise the session is attached to the user.
#
# @param user    Optional user ID to associate with the session.
# @param persist If true, and autologins are permitted, an autologin key is generated for
#                this session.
# @return true if the session was created, undef otherwise.
sub create_session {
    my $self     = shift;
    my $user     = shift;
    my $persist  = shift;
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
            if($keyid -> {"user_id"} == $self -> {"sessuser"});

    # If we don't have a key and user in the cookies, do we have a user specified?
    } elsif($user) {
        $self -> {"autokey"} = '';
        $self -> {"sessuser"} = $user;

        $userdata = $self -> {"auth"} -> get_user_byid($user, 1);
    }

    # If we don't have any user data then either the key didn't match in the database,
    # the user doesn't exist, is inactive, or is a bot. Just get the anonymous user
    if(!$userdata) {
        $self -> {"autokey"} = '';
        $self -> {"sessuser"} = $self -> {"auth"} -> {"ANONYMOUS"};

        $userdata = $self -> {"auth"} -> get_user_byid($self -> {"sessuser"});

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
    my $is_registered = ($userdata -> {"user_id"} && $userdata -> {"user_id"} != $self -> {"auth"} -> {"ANONYMOUS"} && ($userdata -> {"user_type"} == 0 || $userdata -> {"user_type"} == 3));
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
                                            " VALUES(?, ?, ?, ?, ?, ?)");
    $sessh -> execute($self -> {"sessid"},
                      $self -> {"sessuser"},
                      $now,
                      $now,
                      $ENV{"REMOTE_ADDR"},
                      $persist)
            or return set_error("Unable to peform session creation\nError was: ".$self -> {"dbh"} -> errstr);

    $self -> set_login_key($self -> {"sessuser"}, $ENV{"REMOTE_ADDR"}) if($persist);

    return $self;
}


## @method $ delete_session()
# Delete the current session, resetting the user's data to anonymous. This will
# remove the user's current session, and any associated autologin key, and then
# generate a new anonymous session for the user.
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


# ==============================================================================
# Theoretically internal stuff


## @method ip_check($userip, $sessip)
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
    my $sessip = shift;

    # How may IP address segments should be compared?
    my $iplen = $self -> {"auth"} -> get_config('ip_check');

    # bomb immediately if we aren't checking IPs
    return 1 if($iplen == 0);

    # pull out as much IP as we're interested in
    my ($usercheck) = $userip =~ /((?:\d+.?){$iplen})/;
    my ($sesscheck) = $sessip =~ /((?:\d+.?){$iplen})/;

    # Do the IPs match?
    return $usercheck eq $sesscheck;
}


## @method $ session_cleanup()
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
    if($self -> {"settings"} -> {"config"} -> {"lastgc"} < $now - $self -> {"auth"} -> get_config("session_gc")) {
        # Okay, we're due a garbage collect, update the config to reflect that we're doing it
        $self -> {"settings"} -> set_db_config($self -> {"dbh"}, $self -> {"settings"} -> {"database"} -> {"settings"}, "lastgc", $now);

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


## @method $ session_expired($sessdata)
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


## @method $ get_session($sessid)
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


## @method void touch_session($session)
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
            or die_log($self -> {"cgi"} -> remote_host(), "Unable to touch session. Error was: ".$self -> {"dbh"} -> errstr);
    }
}


## @method void set_login_key()
# Create the auto login key for the current session user.
#
sub set_login_key {
    my $self = shift;

    my $key = $self -> {"autokey"};
    my $key_id = $self -> {"auth"} -> unique_id(substr($self -> {"sessid"}, 0, 8));

    # If we don't have a key, we want to create a new key in the table
    if(!$key) {
        my $keyh = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"settings"} -> {"database"} -> {"keys"}.
                                               " VALUES(?, ?, ?, ?)");
        $keyh -> execute(md5_hex($key_id), $self -> {"sessuser"}, $ENV{REMOTE_ADDR}, time())
            or die_log($self -> {"cgi"} -> remote_host(), "Unable to create autologin key. Error was: ".$self -> {"dbh"} -> errstr);

    # If we have a key, we want to overwrite it with the new stuff
    } else {
        my $keyh = $self -> {"dbh"} -> prepare("UPDATE ".$self -> {"settings"} -> {"database"} -> {"keys"}.
                                               " SET key_id = ?, last_ip = ?, last_login = ? WHERE user_id = ? AND key_id = ?");
        $keyh -> execute(md5_hex($key_id), $ENV{REMOTE_ADDR}, 0 + time(), 0 + $self -> {"sessuser"}, md5_hex($key))
            or die_log($self -> {"cgi"} -> remote_host(), "Unable to update autologin key. Error was: ".$self -> {"dbh"} -> errstr);
    }

    $self -> {"autokey"} = $key_id;
}


## @method $ create_cookie($name, $value, $expires)
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


## @fn $ set_error($error)
# Set the error string to the specified value. This updates the class error
# string and returns undef.
#
# @param error The message to set in the error string
# @return undef, always.
sub set_error {
    $errstr = shift;

    return undef;
}

1;
