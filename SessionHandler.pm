## @file
# This file contains the implementation of the perl phpBB3 interaction class.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 0.5
# @date    23 Sep 2009
# @copy    2009, Chris Page &lt;chris@starforge.co.uk&gt;
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
# maintaining user state over http transactions. This code depends on 
# integration with a phpBB3 database: a number of custom tables are needed
# (see config docs), but user handling is tied to phpBB3 user tables, and
# a number of joins between custom tables and phpBB3 ones require the two 
# to share database space. This code provides session verification, and 
# takes some steps towards ensuring security against cookie hijacking, but
# as with any cookie based auth system there is the potential for security
# issues.
#
# This code is heavily based around the session code used by phpBB3, with
# features removed or added to fit the different requirements of the ORB,
# starforge site, etc
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
use phpBB3;
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
        phpbb     => undef,
        template  => undef,
        settings  => undef,
        @_,
    };

    # Ensure that we have objects that we need
    return set_error("cgi object not set") unless($self -> {"cgi"});
    return set_error("dbh object not set") unless($self -> {"dbh"});
    return set_error("phpbb object not set") unless($self -> {"phpbb"});
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
    $self -> {"autokey"} = $persist = '' if(!$self -> {"phpbb"} -> get_config("allow_autologin"));

    # Set a default last visit, might be updated later
    $self -> {"last_visit"} = $now;

    # If we have a key, and a user in the cookies, try to get it
    if($self -> {"autokey"} && $self -> {"sessuser"} && $self -> {"sessuser"} != $phpBB3::ANONYMOUS) {
        my $autocheck = $self -> {"dbh"} -> prepare("SELECT u.* FROM ".
                                                    $self -> {"phpbb"} -> {"prefix"}."users AS u, ".
                                                    $self -> {"settings"} -> {"database"} -> {"keys"}." AS k
                                                    WHERE u.user_id = ? 
                                                    AND u.user_type IN (0, 3)
                                                    AND k.user_id = u.user_id
                                                    AND k.key_id = ?");
        $autocheck -> execute($self -> {"sessuser"}, md5_hex($self -> {"autokey"}))
            or return set_error("Unable to peform user lookup query\nError was: ".$self -> {"dbh"} -> errstr);            

        $userdata = $autocheck -> fetchrow_hashref;

    # If we don't have a key and user in the cookies, do we have a user specified?
    } elsif($user) {
        $self -> {"autokey"} = '';
        $self -> {"sessuser"} = $user;

        my $userh = $self -> {"dbh"} -> prepare("SELECT * FROM ".$self -> {"phpbb"} -> {"prefix"}."users 
                                                 WHERE user_id = ?
                                                 AND user_type IN (0, 3)");
        $userh -> execute($self -> {"sessuser"})
            or return set_error("Unable to peform user lookup query\nError was: ".$self -> {"dbh"} -> errstr);            

        $userdata = $userh -> fetchrow_hashref;
    }

    # If we don't have any user data then either the key didn't match in the database,
    # the user doesn't exist, is inactive, or is a bot. Just get the anonymous user
    if(!$userdata) {
        $self -> {"autokey"} = '';
        $self -> {"sessuser"} = $phpBB3::ANONYMOUS;

         my $userh = $self -> {"dbh"} -> prepare("SELECT * FROM ".$self -> {"phpbb"} -> {"prefix"}."users 
                                                 WHERE user_id = ?");
        $userh -> execute($self -> {"sessuser"})
            or return set_error("Unable to peform user lookup query\nError was: ".$self -> {"dbh"} -> errstr);            

        $userdata = $userh -> fetchrow_hashref;

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
    my $is_registered = ($userdata -> {"user_id"} && $userdata -> {"user_id"} != $phpBB3::ANONYMOUS && ($userdata -> {"user_type"} == 0 || $userdata -> {"user_type"} == 3));
    $persist = (($self -> {"autokey"} || $persist) && $is_registered) ? 1 : 0;

    # Do we already have a session id? If we do, and it's an anonymous session, we want to nuke it
    if($self -> {"sessid"}) {
        my $killsess = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"sessions"}.
                                                   " WHERE session_id = ? AND session_user_id = ?");
        $killsess -> execute($self -> {"sessid"}, $phpBB3::ANONYMOUS)
            or return set_error("Unable to remove anonymous session\nError was: ".$self -> {"dbh"} -> errstr);
    }
    
    # generate a new session id. The md5 of a unique ID should be unique enough...
    $self -> {"sessid"} = md5_hex($self -> {"phpbb"} -> unique_id());

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
    if($self -> {"sessuser"} != $phpBB3::ANONYMOUS) {
        
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
        my $expires = "+".($self -> {"phpbb"} -> get_config("max_autologin_time") || 365)."d";
        my $sesscookie = $self -> create_cookie($self -> {"settings"} -> {"config"} -> {"cookie_name"}.'_sid', $self -> {"sessid"}, $expires);
        my $sessuser   = $self -> create_cookie($self -> {"settings"} -> {"config"} -> {"cookie_name"}.'_u', $self -> {"sessuser"}, $expires);
        my $sesskey;
        if($self -> {"sessuser"} != $phpBB3::ANONYMOUS) {
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
    my $iplen = $self -> {"phpbb"} -> get_config('ip_check');

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
# @return true oin successful cleanup (or cleanup not needed), false on error.
sub session_cleanup {
    my $self = shift;

    my $now = time();
    my $timelimit = $now - $self -> {"phpbb"} -> get_config("session_length");

    # We only want to run the garbage collect occasionally
    if($self -> {"settings"} -> {"config"} -> {"lastgc"} < $now - $self -> {"phpbb"} -> get_config("session_gc")) {
        # Okay, we're due a garbage collect, update the config to reflect that we're doing it
        $self -> {"settings"} -> set_db_config($self -> {"dbh"}, $self -> {"settings"} -> {"database"} -> {"settings"}, "lastgc", $now);

        # Remove expired guest sessions first
        my $nukesess = $self -> {"dbh"} -> prepare("DELETE FROM ".$self -> {"settings"} -> {"database"} -> {"sessions"}.
                                                   " WHERE session_user_id = ?
                                                     AND session_time < ?");
        $nukesess -> execute($phpBB3::ANONYMOUS, $timelimit)
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
        return 1 if($sessdata -> {"session_time"} < time() - ($self -> {"phpbb"} -> get_config("session_length") + 60));

    } else {
        my $max_autologin = $self -> {"phpbb"} -> get_config("max_autologin_time");

        # If the session is autologin, and it is older than the max autologin time, or autologin is not enabled, it's expired
        return 1 if(!$self -> {"phpbb"} -> get_config("allow_autologin") || 
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
    my $key_id = $self -> {"phpbb"} -> unique_id(substr($self -> {"sessid"}, 0, 8));

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
