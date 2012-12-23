## @file
# This file contains the implementation of the perl phpBB3 interaction class.
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
# The phpBB3 class provides facilities for interacting with a phpBB3 forum
# installation. The methods provided by this class are intended to give
# a perl script low-level access to the data stored in a phpBB3 database,
# and they should be used with caution. Unlike phpBB3, no security checks
# are done on, for example, whether the user is supposed to be able to see
# a topic in a forum: while it would be technically possible to achieve
# this, it would add a dramatic overhead to the listing and fetching of
# posts and would involve session shenanigans to ensure users are logged
# into a phpBB3 account.
#
#
package phpBB3;

use strict;

# Standard module imports
use DBI;
use Digest::MD5 qw(md5 md5_hex);
use Time::HiRes qw(gettimeofday);
use WWW::Mechanize; # Needed to register via phpBB's registration form

# Custom module imports
use Utils qw(path_join);

# Globals...
our ($ANONYMOUS, $errstr, %fmt_map);

BEGIN {
    $ANONYMOUS = 1;   # ID of the anonymous user, should be 1 unless you Know What You're Doing.
    $errstr    = '';  # Global error string

    # Hash to map php date() formats to strftime format codes
    %fmt_map = ( "d" => "%d",
                 "D" => "%a",
                 "j" => "%d",
                 "l" => "%A",
                 "N" => "%u",
                 "S" => "",   # UNSUPPORTED: English ordinal suffix for the day of the month, 2 characters
                 "w" => "%w",
                 "z" => "%j",
                 "W" => "%V",
                 "F" => "%B",
                 "m" => "%m",
                 "M" => "%b",
                 "n" => "%m", # PARTIAL: (should be month without zero)
                 "t" => "",   # UNSUPPORTED: Number of days in the given month 28 through 31
                 "L" => "",   # UNSUPPORTED: Whether it's a leap year 1 if it is a leap year, 0 otherwise.
                 "o" => "%G",
                 "Y" => "%Y",
                 "y" => "%y",
                 "a" => "%P",
                 "A" => "%p",
                 "B" => "",   # UNSUPPORTED: Swatch Internet time 000 through 999
                 "g" => "%l", # PARTIAL: 12-hour format of an hour without leading zeros 1 through 12
                 "G" => "%k", # PARTIAL: 24-hour format of an hour without leading zeros 0 through 23
                 "h" => "%I",
                 "H" => "%H",
                 "i" => "%M",
                 "s" => "%S",
                 "u" => "",   # UNSUPPORTED: Milliseconds (added in PHP 5.2.2) Example: 54321
                 "e" => "%Z",
                 "I" => "",   # UNSUPPORTED: (capital i) Whether or not the date is in daylight saving time 1 if Daylight Saving Time, 0 otherwise.
                 "O" => "%z",
                 "P" => "",   # UNSUPPORTED: Difference to Greenwich time (GMT) with colon between hours and minutes (added in PHP 5.1.3)
                 "T" => "%Z",
                 "Z" => "",   # UNSUPPORTED: Timezone offset in seconds. The offset for timezones west of UTC is always negative, and for those east of UTC is always positive.
                 "c" => "%FT%T%z",
                 "r" => "%a, %d %b %Y %H:%M:%S %z",
                 "U" => "%s");
}

# ==============================================================================
# Creation and destruction

## @cmethod $ new(%args)
# Create a new phpBB3 intraction object. This will create an object that provides functions
# to pull data out of, and process, the data in the tables of a phpBB3 database. Meaningful
# options for this are:
# prefix    - The table prefix for phpBB3 tables, defaults to 'phpbb_'.
# codepath  - The path to the module to load to handle bbcode, if not provided bbcode conversion is disabled.
# cgi       - The CGI object to access parameters and cookies through.
# dbh       - The database handle to use for queries.
# allowanon - Set to true to treat the system anonymous account as a valid user (defaults to 0)
# username  - The username to use when connecting to the database, if dbh is not provided.
# password  - The password to connect to the database with, if dbh is not provided.
# data_src  - The datasource to use to connect to the database, if dbh is not provided.
# dbopts    - An optional hashref of settings to pass to connect(), defaults to { RaiseError => 0, AutoCommit => 1 }.
# url       - The URL of the phpBB3 forum. Defaults to /
# If dbh is not provided, and username, password, and data_src are provided, this will attempt
# to create a connection to the database for you. If you provide a database connection handle,
# you do not need to provide the username, password, or data_src.
#
# @param args A hash of key, value pairs to initialise the object with.
# @return A new phpBB3 object, or undef if no database connection has been provided or
#         established.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = {
        prefix    => 'phpbb_',
        codepath  => undef,
        cgi       => undef,
        dbh       => undef,
        username  => undef,
        password  => undef,
        data_src  => undef,
        allowanon => 0,
        dbopts    => { RaiseError => 0, AutoCommit => 1 },
        url       => "/",
        ANONYMOUS => $ANONYMOUS,
        @_,
    };

    my $obj = bless $self, $class;

    # If we haven't been given a database handle, but we have database credentials,
    # try to open the database connection with those credentials.
    if(!$obj -> {"dbh"} && $self -> {"username"} & $obj -> {"password"} && $obj -> {"data_src"}) {
        $obj -> {"dbh"} = DBI -> connect($obj -> {"data_src"},
                                          $obj -> {"username"},
                                          $obj -> {"password"},
                                          $obj -> {"dbopts"})
            or return set_error("Unable to open database connection - ".$DBI::errstr);

        $obj -> {"localdbh"} = 1;
    }

    # If we get here and still don't have a database connection, we need to fall over
    return set_error("No database connection available.") if(!$obj -> {"dbh"});

    # Check we also have a cgi object to play with
    return set_error("No CGI object available.") if(!$obj -> {"cgi"});

    # If we have a codefile, attempt to load it
    if($obj -> {"codepath"}) {
        require $obj -> {"codepath"}."/BBCode.pm";
        $obj -> {"bbcode"} = BBCode -> new(smilies_path => $obj -> get_smilie_url())
            or return set_error("Unable to create new bbcode handler.");
    }

    # Otherwise, we're good...
    return $obj;
}


## @method void cleanup(void)
# Shut down the database connection, if needed. You only need to call this if you
# did not specify a dbh in the arguments to new().
sub cleanup {
    my $self = shift;

    # Only do a disconnect if we are actually responsible for the database handle
    if($self -> {"localdbh"} && $self -> {"dbh"}) {
        $self -> {"dbh"} -> disconnect();

        # clear these, just in case someone tries to call cleanup twice.
        $self -> {"dbh"} = undef;
        $self -> {"localdbh"} = undef;
    }
}


# ==============================================================================
# User and group handling

## @method $ register_user($args, $url)
# Register a new user in the phpBB3 installation. This will create a new user record
# in the system, and return a reference to the user's data if successful.
#
# @param args The arguments to pass to the registration form. Must contain entries for
#             'username', 'email', and 'password'.
# @param url  The url of the registration agreement page for the forum.
# @return A reference to a hash containing the new user's data on success, otherwise
#         a string containing an error message.
sub register_user {
    my $self = shift;
    my $args = shift;
    my $url  = shift;

    # We need to mechanise the registration
    my $www = WWW::Mechanize -> new(cookie_jar => { },
                                    agent => 'Mozilla/5.0 (Windows; U; Windows NT 5.1; en-US; rv:1.8.1.23) Gecko/20090825 SeaMonkey/1.1.18');

    # Get the first page of the registration process
    $www -> get($url);
    return "Failed to obtain registration first step page. Response was: ".$www -> res -> message if(!$www -> success());

    #die "Content is: ".$www -> content();

    # Pick the correct form....
    $www -> form_id('agreement')
        or return "Unable to locate the first step registration form.";

    # hit the agreed button
    $www -> click('agreed');
    return "Failed when accepting registration first step. Response was: ".$www -> res -> message if(!$www -> success());

    # Check that we have content we were expecting...
    my $content = $www -> content();
    return "Unexpected content in response to registration first step accept."
        unless($content =~ /PLEASE DO NOT ATTEMPT TO REGISTER USING THIS FORM/);

    $www -> form_id('register')
        or return "Unable to locate the second step registration form.";

    # Now we can fill in fields to submit
    $www -> field ('username'        , $args -> {"username"});
    $www -> field ('email'           , $args -> {"email"});
    $www -> field ('email_confirm'   , $args -> {"email"});
    $www -> field ('new_password'    , $args -> {"password"});
    $www -> field ('password_confirm', $args -> {"password"});
    $www -> field ('question1'       , 'forging new realities');
    $www -> field ('question2'       , 'chris page');
    $www -> select('lang'            , 'en');
    $www -> select('tz'              , '0');

    # And submit that
    $www -> click('submit');
    return "Failed when posting registration second step. Response was: ".$www -> res -> message if(!$www -> success());

    # Check that we have content we were expecting...
    $content = $www -> content();
    if($content !~ /Thank you for registering, your account has been created/) {
        my ($errmsg) = $content =~ m{<dl><dd class="error">(.*?)</dd></dl>}iso;

        $content =~ s/</&lt;/g;
        $content =~ s/>/&gt;/g;

        return "Unexpected response to registration:<br/>$errmsg<br/>Unable to add user.</p><pre style=\"text-align: left;\">$content</pre><p>"
    }

    # Okay, registration is completed, now we need to find out which user id the new user has
    my $user = $self -> get_user($args -> {"username"});
    return "Unable to determine the user id for ".$args -> {"username"}.", unable to complete registration."
        if(!$user);

    return $user;
}


## @method $ get_user($username)
# Search for a user with the specified username in the database. This will attempt
# to obtain a user record for a user with the specified username in the phpBB3
# database, and return a reference to a hash containing the data if successful.
#
# @param username The name of the user to locate.
# @return A reference to the user's data, or undef if the user could not be located
#         or an error occurred.
sub get_user {
    my $self     = shift;
    my $username = shift;

    my $userh = $self -> {"dbh"} -> prepare("SELECT * FROM ".$self -> {"prefix"}."users
                                             WHERE username_clean LIKE ?");
    $userh -> execute(lc($username))
        or die "phpBB3::get_user(): Unable to execute user lookup query.\nError was: ".$self -> {"dbh"} -> errstr."\n";

    return $userh -> fetchrow_hashref();
}


## @method $ get_user_byid($userid, $onlyreal)
# Search for a user with the specified id in the database. This will attempt
# to obtain a user record for a user with the specified id in the phpBB3
# database, and return a reference to a hash containing the data if successful.
#
# @param userid   The id of the user to locate.
# @param onlyreal If set, the userid must correspond to a 'real' user: if the id
#                 is a bot or inactive account, this returns undef.
# @return A reference to the user's data, or undef if the user could not be located
#         or an error occurred.
sub get_user_byid {
    my $self     = shift;
    my $userid   = shift;
    my $onlyreal = shift;

    my $userh = $self -> {"dbh"} -> prepare("SELECT * FROM ".$self -> {"prefix"}."users
                                             WHERE user_id = ?".
                                            ($onlyreal ? " AND user_type IN (0,3)" : ""));
    $userh -> execute($userid)
        or die "phpBB3::get_user_byid(): Unable to execute user lookup query.\nError was: ".$self -> {"dbh"} -> errstr."\n";

    return $userh -> fetchrow_hashref();
}



## @method $ get_group($groupname)
# Search for a group with the specified name in the database. This will attempt
# to obtain a group record for a group with the specified group name in the phpBB3
# database, and return a reference to a hash containing the data if successful.
#
# @param groupname The name of the group to locate.
# @return A reference to the group's data, or undef if the group could not be located
#         or an error occurred.
sub get_group {
    my $self     = shift;
    my $groupname = shift;

    my $grouph = $self -> {"dbh"} -> prepare("SELECT * FROM ".$self -> {"prefix"}."groups
                                             WHERE group_name LIKE ?");
    $grouph -> execute($groupname)
        or die "phpBB3::get_group(): Unable to execute group lookup query.\nError was: ".$self -> {"dbh"} -> errstr."\n";

    return $grouph -> fetchrow_hashref();
}


## @method $ user_in_group(%args)
# Determine whether a user is a member of a group. This will check whether a
# user is listed as being a member of a group, and return true if they are. The
# arguments that can be specified for this are:
# username  - the name of the user to search for.
# user_id   - the id of the user to search for.
# group     - the name of the group to check in.
# group_id  - the id of the group to check in.
# If user_id is specified, username is ignored if it is also provided. If user_id
# is not provided, username must be (ie: you must specify at least one of username
# or user_id, and user_id takes precedence) Similarly, you must specify at least
# one of group or group_id, and group_id takes precedence over group.
#
# @param args A hash of arguments.
# @return true if the user is present in the group, false if not or if an error
#         occured while attempting to check.
sub user_in_group {
    my $self = shift;
    my %args = @_;

    set_error("");

    # Check that we have one of username or user_id
    return set_error("No username or user_id provided")
        if(!$args{'username'} && !$args{'user_id'});

    # similarly for the group and group_id
    return set_error("No group or group_id provided")
        if(!$args{'group'} && !$args{'group_id'});

    # If we don't have a user_id, we need to look it up
    if(!$args{"user_id"}) {
        my $user = $self -> get_user($args{'username'})
            or return set_error("Unable to find user $args{'username'}");
        $args{"user_id"} = $user -> {"user_id"};
    }

    # If we don't have a group_id, we need to look it up
    if(!$args{"group_id"}) {
        my $group = $self -> get_group($args{'group'})
            or return set_error("Unable to find user $args{'group'}");
        $args{"group_id"} = $group -> {"group_id"};
    }


    # Now we should have a user id and group id, so we can go look in the user_group table
    my $ugh = $self -> {"dbh"} -> prepare("SELECT * FROM ".$self -> {"prefix"}."user_group
                                           WHERE group_id = ? AND user_id = ?");
    $ugh -> execute($args{"group_id"}, $args{"user_id"})
        or die "phpBB3::user_in_group(): Unable to execute user_group lookup query.\nError was: ".$self -> {"dbh"} -> errstr."\n";

    # Do we have one or more rows?
    my $ugr = $ugh -> fetchrow_arrayref();

    return defined($ugr);
}


## @method $ valid_user($username, $password)
# Attempt to confirm whether the provided user credentials are valid. This will check
# whether the specified username corresponds to a valid user, and if it does it will
# check that the hash of the provided password matches. If the password matches, this
# returns a reference to a hash containing the user's entry in the users table.
#
# @param username The username of the user to check.
# @param password The password to check against this user.
# @return A reference to a hash containing the user's data, or undef if an error
#         occured, the user could not be found, or the password was invalid.
sub valid_user {
    my $self = shift;
    my $username = shift;
    my $password = shift;

    # first get hold of the user
    my $user = $self -> get_user($username)
        or return set_error("Unable to locate user $username in the forum database.");

    # We have a user, do the passwords match? If so, return the user's hash
    return $user if(_check_hash($password, $user -> {"user_password"}));

    return set_error("The specified password is not valid.");
}


## @method $ get_profile_url($userid)
# Given a userid, produce a full URL that can be used to view the user's profile.
#
# @param userid The ID of the user whose profile URL should be generated.
# @return A string containing the URL of the user's profile.
sub get_profile_url {
    my $self = shift;
    my $userid = shift;

    return path_join($self -> {"url"}, "memberlist.php?mode=viewprofile&amp;u=$userid");
}


## @method $ email_in_use($email)
# Determine whether the specified email address is already in use within the
# system.
#
# @param email    The email address to check.
# @return true if the email address already exists within the database, false
#         if it does not.
sub email_in_use {
    my $self  = shift;
    my $email = shift;

    my $emailh = $self -> {'dbh'} -> prepare("SELECT user_id FROM ".$self -> {"prefix"}."users
                                              WHERE user_email LIKE ?");
    $emailh -> execute($email)
        or die "phpBB3::email_in_use(): Unable to execute email lookup query.\nError was: ".$self -> {"dbh"} -> errstr."\n";

    return $emailh -> fetchrow_hashref();
}


## @method $ is_valid_password($plaintext)
# This determines whether the specified password is valid, based on the current
# phpBB3 settings. If this returns true, the password should have passed all the
# requirements currently set in phpBB3, otherwise it is either the wrong length
# or it does not contain the correct characters.
#
# @param plaintext The plain text password to verify.
# @return true if the password passes the suitability checks, false otherwise.
sub is_valid_password {
    my $self      = shift;
    my $plaintext = shift;

    # Length checks first, the password must be within min_pass_chars to max_pass_chars
    return 0 if(length($plaintext) < $self -> get_config('min_pass_chars') ||
                length($plaintext) > $self -> get_config('max_pass_chars'));

    # Now we need to check for character content based on pass_complex
    my $passmode = $self -> get_config('pass_complex');

    # _ANY is automatically true now..
    if($passmode eq "PASS_TYPE_ANY") {
        return 1;

    # _CASE requires mixed case
    } elsif($passmode eq "PASS_TYPE_CASE" && $plaintext =~ /[a-z]/ && $plaintext =~ /[A-Z]/) {
        return 1;

    # _ALPHA requires letters and numbers
    } elsif($passmode eq "PASS_TYPE_ALPHA" && $plaintext =~ /[a-zA-Z]/ && $plaintext =~ /[0-9]/) {
        return 1;

    # _SYMBOL is as _ALPHA plus symbols
    } elsif($passmode eq "PASS_TYPE_SYMBOL" && $plaintext =~ /[a-zA-Z]/ && $plaintext =~ /[0-9]/ && $plaintext =~ /[^a-zA-Z0-9]/) {
        return 1;
    }

    return 0;
}


# ==============================================================================
# Session handling

## @method @ get_session(void)
# Attempt to obtain the userid and username of the current session user. This
# attempts to determine whether the session in the user's cookies is a valid
# phpBB3 session, and if it is it returns a reference to a hash containing user
# and session data. This will update the timestamp on the session, if needed.
#
# @return A reference to a hash containing user and session data if the session
#         is valid, undef otherwise.
#
# @todo This does not currently support forwarded_for checks, referer checks,
#       or load limiting. It also does not support 'alternative' auth methods:
#       only database auth is supported.
sub get_session {
    my $self = shift;

    # First grab the name of the cookie, and fall over if it isn't available for some reason
    my $cookiebase = $self -> get_config("cookie_name")
        or return set_error("Unable to determine phpBB3 cookie name");

    # First, try to obtain a session id - start by looking at the cookies
    my $sessid   = $self -> {"cgi"} -> cookie($cookiebase."_sid");
    my $sessuser = $self -> {"cgi"} -> cookie($cookiebase."_u");   # Which users does this session claim to be?
    my $autokey  = $self -> {"cgi"} -> cookie($cookiebase."_k");   # Do we have an autologin key for the user?

    # If we don't have a session id now, try to pull it from the query string
    $sessid = $self -> {"cgi"} -> param("sid") if(!$sessid);

    # If we still don't have a session id, the user hasn't logged into phpBB3. Give up on them
    return set_error("Unable to obtain a session id for user.") if(!$sessid);

    # Obtain the session and user record from the database
    my $sessh = $self -> {"dbh"} -> prepare("SELECT u.*,s.*
                                             FROM ".$self -> {"prefix"}."users AS u, ".$self -> {"prefix"}."sessions AS s
                                             WHERE s.session_id = ? AND u.user_id = s.session_user_id");
    $sessh -> execute($sessid)
        or die "phpBB3::get_session(): Unable to obtain session and user data from database.\nError was: ".$self -> {"dbh"} -> errstr."\n";
    my $sessdata = $sessh -> fetchrow_hashref();

    # if we have a session, we need to validate it
    if($sessdata) {
        # If we have anonymous disabled, at this is the anon user, exit immediately
        return set_error("Anonymous user session rejected.")
            if(!$self -> {"allowanon"} && $sessdata -> {"user_id"} == $ANONYMOUS);

        # Do some basic checks on the IP and useragent if they are enabled.
        my ($valid_ip, $valid_ua) = (1, 1);

        # if ip address checking is needed, do it
        my $ipfrags = $self -> get_config("ip_check");
        if($ipfrags) {
            my @sess_parts = split('.', $sessdata -> {"session_ip"});
            my @user_parts = split('.', $ENV{"REMOTE_ADDR"});
            my $session_ip = join(".",splice(@sess_parts, 0, $ipfrags));
            my $user_ip    = join(".",splice(@user_parts, 0, $ipfrags));

            $valid_ip = $session_ip eq $user_ip;
        }

        # Check that the browsers match if needed
        if($self -> get_config("browser_check")) {
            $valid_ua = substr(lc($sessdata -> {"session_browser"}), 0, 150) eq
                        substr(lc($self -> {"cgi"} -> user_agent()), 0, 150);
        }

        # If the ip and browser checks are okay, continue with the validation
        # TODO: add referer and forwarded_for checks here?
        if($valid_ip && $valid_ua) {
            my $expired = 0;

            # If the session is not an autologin, check whether it has timed out
            if(!$sessdata -> {"session_autologin"}) {
                $expired = $sessdata -> {"session_time"} < (time() - ($self -> get_config("session_length") + 60));

            # If the session claims to be autologin, but the server doesn't support it, expire the session
            } elsif(!$self -> get_config("allow_autologin")) {
                $expired = 1;

            # Otherwise, if check whether a maximum autologin time limit has been set, and that the session is within it
            } else {
                my $max_autologin = $self -> get_config("max_autologin_time");
                $expired = ($max_autologin && $sessdata -> {"session_time"} < (time() - ($max_autologin + 60)));
            }

            # If the session has not expired, we want to touch it
            if(!$expired) {
                if(time() - $sessdata -> {"session_time"} > 60) {
                    my $touch = $self -> {"dbh"} -> prepare("UPDATE ".$self -> {"prefix"}."sessions
                                                             SET session_time = ?
                                                             WHERE session_id = ?");
                    $touch -> execute(time(), $sessdata -> {"session_id"})
                        or die "phpBB3::get_session(): Unable to update session timestamp for ".$sessdata -> {"session_id"}."\nError was: ".$self -> {"dbh"} -> errstr."\n";
                }
                return $sessdata;
            } else { # if(!$expired) {
                set_error("The phpBB3 session has expired");
            }
        } else { # if($valid_ip && $valid_ua) {
            set_error("phpBB3 session validation has failed");
        }
    } else { # if($sessdata) {
        set_error("Invalid session ID provided");
    }

    # If we get here, we did not have a valid session, or it has expired. Fall over
    return undef;
}


# ==============================================================================
# Forum listing and extraction

## @method $ get_forum($forumid)
# Obtain the forum row that corresponds to the provided forumid. This will obtain
# reference to a hash containing the data for the forum given by the provided
# forumid, or undef if it can not be located in the database.
#
# @note <b>This function does no permissions checking whatsoever.</b> It is up
#       to the caller to determine whether or not the forum should be visible.
#       If you expose private forums with this function, you have nobody to
#       blame but yourself. You have been warned.
#
# @param forumid The id of the forum to obtain data on.
# @return A reference to a hash containing the forum data, or undef if the
#         forum does not exist in the database.
sub get_forum {
    my $self    = shift;
    my $forumid = shift;

    my $forumh = $self -> {"dbh"} -> prepare("SELECT * FROM ".$self -> {"prefix"}."forums
                                              WHERE forum_id = ?");
    $forumh -> execute($forumid)
        or die "phpBB3::get_forum(): Unable to perform forum lookup query.\nError was: ".$self -> {"dbh"} -> errstr."\n";

    # Just return the hashref as-is...
    return $forumh -> fetchrow_hashref();
}


# ==============================================================================
# Topic listing and extraction

## @method $ get_topic_ids($forum, $count, $offset, $sort_by_last)
# Given a forum id, a topic count, and an offset, obtain a list of topic IDs
# for topics in the forum. This follows the same treatement of posts as the forum
# view in phpBB3: announcements always appear at the start of the list, regardles
# of the offset. The remaining posts are sorted so that sticky topics will
# appear before normal topics, but are otherwise treated normally.
#
# @note <b>This function does no permissions checking whatsoever.</b> It is up
#       to the caller to determine whether or not the forum should be visible.
#       If you expose private forums with this function, you have nobody to
#       blame but yourself. You have been warned.
#
# @param forum        The ID of the forum to obtain a topic list for.
# @param count        The number of topics ids to return, if not specified defaults to 10.
#                     if set to 0, all post ids are returned.
# @param offset       The number of posts to skip, if not specified defaults to 0. This is
#                     ignored if count is set to 0.
# @param sort_by_last If true, posts are sorted by the last reply time rather
#                     than the default creation time order (note that this must
#                     be true to generate the same listing phpBB3 shows)
# @return A reference to an array of topic ids, or undef if no topics are available
#         or an error ocurred.
sub get_topic_ids {
    my $self   = shift;
    my $forum  = shift;
    my $count  = shift;
    my $offset = shift || 0;
    my $slast  = shift;

    $count = 10 if(!defined($count));
    my $fetchall = ($count == 0); # record whether we need to fetch all entries

    # $count will be used directly in queries, so make damned sure it's just numbers
    return set_error("Count contains non-digit characters. Possible SQL insertion attack detected!")
        if($count =~ /\D/);

    # And the same for the offset
    return set_error("Offset contains non-digit characters. Possible SQL insertion attack detected!")
        if($offset =~ /\D/);

    # Check that the forum is valid
    return set_error("Unable to locate a forum with the specified forumid.")
        if(!$self -> get_forum($forum));

    # Work out the order fragment
    my $order = "ORDER BY topic_type DESC, ".($slast ? "topic_last_post_time" : "topic_time")." DESC";

    # First pull out a list of announcements. We can't do this at the same time
    # as pulling out stickies and normal threads, as the offset would screw up
    # always having announcements at the front.
    my $announceh = $self -> {"dbh"} -> prepare("SELECT topic_id FROM ".$self -> {"prefix"}."topics
                                                 WHERE forum_id = ? AND topic_type = 2
                                                 $order
                                                ".($fetchall ? "" : "LIMIT $count"));
    $announceh -> execute($forum)
        or die "phpBB3::get_topic_ids(): Unable to obtain announcement topic list.\nError was: ".$self -> {"dbh"} -> errstr."\n";

    my @topics; # This is where the topic list will be stored

    # process announcement topic rows until we've  processed all the annoucements
    while(my $announcer = $announceh -> fetchrow_arrayref()) {
        push(@topics, $announcer -> [0]);
        --$count if(!$fetchall); # LIMIT $count in the query should prevent this from going negative
    }

    # Do we have any space left in the return array?
    if($count || $fetchall) {
        # Now we want to pull out the stickies and normal topics. topic_type must be < 2 to exclude
        # annoucements.
        my $topich = $self -> {"dbh"} -> prepare("SELECT topic_id FROM ".$self -> {"prefix"}."topics
                                                  WHERE forum_id = ? AND topic_type < 2
                                                  $order
                                                  ".($fetchall ? "" : "LIMIT $offset, $count"));
        $topich -> execute($forum)
            or die "phpBB3::get_topic_ids(): Unable to obtain normal/sticky topic list.\nError was: ".$self -> {"dbh"} -> errstr."\n";

        # Store the topic ids we have from the database...
        while(my $topicr = $topich -> fetchrow_arrayref()) {
            push(@topics, $topicr -> [0]);
        }

    } # if($count) {

    # And we're done. Return a reference to the topics array if it has any contents,
    # undef if it does not.
    return scalar(@topics) ? \@topics : set_error("");
}


## @method $ get_topic($topicid)
# Obtain the data for the topic identified by the specified topicid. This will attempt
# to locate a topic entry with the specified topicid and return a reference to a hash
# containing the topic information.
#
# @param topicid The id of the topic to look up.
# @return A reference to a hash containing the topic data, undef if the topic could
#         not be located in the database.
sub get_topic {
    my $self    = shift;
    my $topicid = shift;

    my $topich = $self -> {"dbh"} -> prepare("SELECT * FROM ".$self -> {"prefix"}."topics
                                              WHERE topic_id = ?");
    $topich -> execute($topicid)
        or die "phpBB3::get_topic(): Unable to execute topic lookup query.\nError was: ".$self -> {"dbh"} -> errstr."\n";

    return $topich -> fetchrow_hashref();
}


## @method $ get_topic_firstpost($topicid, $bbc_to_html)
# Create a reference to a hash containing the text of the first post in the specified
# topic, the number of replies, the poster's details and various other useful pieces
# of information.
#
# @param topicid     The topic id to obtain the first post for
# @param bbc_to_html If true, any bbcode in the post will be converted to html for you.
# @return A reference to a hash containing the first post data and other useful info,
#         or undef if a problem was encountered while generating the hash.
sub get_topic_firstpost {
    my $self        = shift;
    my $topicid     = shift;
    my $bbc_to_html = shift;

    # First we need the topic header
    my $topic = $self -> get_topic($topicid)
        or return set_error("Unable to locate topic $topicid in the database");

    # Now we can obtain the first post and user details
    my $posth = $self -> {"dbh"} -> prepare("SELECT p.*, u.*
                                             FROM ".$self -> {"prefix"}."posts AS p, ".$self -> {"prefix"}."users AS u
                                             WHERE p.post_id = ? AND u.user_id = p.poster_id");
    $posth -> execute($topic -> {"topic_first_post_id"})
        or die "phpBB3::get_topic_firstpost(): Unable to execute post lookup query.\nError was: ".$self -> {"dbh"} -> errstr."\n";

    # Did we get a post?
    my $post = $posth -> fetchrow_hashref();
    if($post) {
        # okay, we can start to build the post data hash now
        my $pdata = { "forum_id"        => $topic -> {"forum_id"},
                      "topic_id"        => $topic -> {"topic_id"},
                      "post_id"         => $topic -> {"post_id"},
                      "post_time"       => $topic -> {"topic_time"},
                      "post_replies"    => $topic -> {"topic_replies"},
                      "post_subject"    => $topic -> {"topic_title"},
                      "post_body"       => "<p>".$post  -> {"post_text"}."</p>",
                      "post_uid"        => $post  -> {"bbcode_uid"},
                      "poster_username" => $post  -> {"username"},
                      "poster_userid"   => $post  -> {"user_id"}};

        # If the user has an avatar, we want to record it. Note that this expects phpBB3
        # to have enforced any restrictions on avatar types.
        if($post -> {"user_avatar_type"}) {
            # width and height should be there regardless of type
            $pdata -> {"avatar_width"}  = $post -> {"user_avatar_width"};
            $pdata -> {"avatar_height"} = $post -> {"user_avatar_height"};

            # type 1 is uploaded
            if($post -> {"user_avatar_type"} == 1) {
                $pdata -> {"avatar_url"} = $self -> get_config("server_protocol").
                                           $self -> get_config("server_name").
                                           path_join($self -> get_config("script_path").
                                                     $self -> get_config("avatar_path").
                                                     $post -> {"user_avatar"});
            # type 2 avatars are remote linked, so the url should be usable as-is
            } elsif($post -> {"user_avatar_type"} == 2) {
                $pdata -> {"avatar_url"} = $post -> {"user_avatar"};

            # type 3 avatars are gallery avatars
            } elsif($post -> {"user_avatar_type"} == 3) {
                $pdata -> {"avatar_url"} = $self -> get_config("server_protocol").
                                           $self -> get_config("server_name").
                                           path_join($self -> get_config("script_path").
                                                     $self -> get_config("avatar_gallery_path").
                                                     $post -> {"user_avatar"});
            }
        }

        # Fix up bbcode if we need to
        $self -> {"bbcode"} -> convert(\$pdata -> {"post_body"}, $pdata -> {"post_uid"})
            if($bbc_to_html && $self -> {"bbcode"});

        # And done...
        return $pdata;
    } # if($post) {

    return set_error("Unable to get post data for the first post in topic $topicid. This should not happen.");
}


## @method $ get_topic_url($forumid, $topicid)
# Given a topicid, produce a full URL that can be used to view the topic thread.
#
# @param forumid The forum the topic is inside.
# @param topicid The ID of the topic to obtain the URL for.
# @return A string containing the URL of the topic thread.
sub get_topic_url {
    my $self    = shift;
    my $forumid = shift;
    my $topicid = shift;

    return path_join($self -> {"url"}, "viewtopic.php?f=$forumid&amp;t=$topicid");
}


## @method $ get_posting_url($forumid, $topicid)
# Given a topicid, produce a full URL that can be used to post to the topic thread.
#
# @param forumid The forum the topic is inside.
# @param topicid The ID of the topic to obtain the URL for.
# @return A string containing the URL of the topic thread.
sub get_posting_url {
    my $self    = shift;
    my $forumid = shift;
    my $topicid = shift;

    return path_join($self -> {"url"}, "posting.php?mode=reply&amp;f=$forumid&amp;t=$topicid");
}


# ==============================================================================
# Theoretically internal stuff

## @method $ get_smilie_url(void)
# Obtain the URL of the directory containing smilies used by the forum.
#
# @return The URL of the smilies directory, or undef if a problem occured
sub get_smilie_url {
    my $self    = shift;

    my $path = $self -> get_config("smilies_path")
        or return set_error("Unable to obtain smilie_path from the database");

    return path_join($self -> {"url"}, $path);
}


## @method $ get_config($name, $default)
# Obtain the value for the specified phpBB3 configuration variable. This will
# return the value for the specified configuration variable if it is found. If
# it is not found, but default is specified, the default is returned, otherwise
# this returns undef.
#
# @param name    The name of the variable to obtain the value for
# @param default An optional default value to return if the named variable can not be found
# @return The value for the named variable, or the default or undef if the
#         variable is not present.
sub get_config {
    my $self    = shift;
    my $name    = shift;
    my $default = shift;

    my $configh = $self -> {"dbh"} -> prepare("SELECT config_value FROM ".$self -> {"prefix"}."config WHERE config_name LIKE ?");
    $configh -> execute($name)
        or die "phpBB3::get_config(): Unable to query database for $name.\nError was:".$self -> {"dbh"} -> errstr."\n";

    my $configr = $configh -> fetchrow_arrayref();

    # If we have a row, and a defined value, return it
    return $configr -> [0]
        if($configr && defined($configr -> [0]));

    # Otherwise, return the default or undef
    return $default;
}


## @method $ unique_id($extra)
# Generate a unique ID that can be used with phpBB3 tables.
#
# @param extra Optional extra string to append to the seed.
# @return a unique ID compatible with phpBB3
sub unique_id {
    my $self  = shift;
    my $extra = shift || "";

    my @bits = gettimeofday();
    my $seed = $self -> get_config("rand_seed").sprintf("%0.8f %d", $bits[1]/1000000, $bits[0]).$extra;
    $seed = md5_hex($seed);

    return substr($seed, 4, 16);
}


## @method $ phpdate_to_strftime($format)
# Convert a php dateformat into something that can be passed to strftime. This goes through
# the provided format string and attempts to convert the format markers from the form used
# by the php date() function into something that can be passed to strftime to get the same
# result. Note that the following php date() format options are not supported and will be
# replaced with the empty string: S, t, L, B, u, I, O, and T. The following options are
# partially supported but the resulting strings are not identical: n (will generate the
# same output as m), g (hour has a leading space instead of zero), and G (hour has a
# leading space instead of zero)
#
# @param format The php date() format string to convert.
# @return The converted format ready to pass to strftime().
sub phpdate_to_strftime {
    my $self   = shift;
    my $format = shift;

    # Yeah, this is really horrible, but applying the hash using a regexp would
    # get really nasty, really quick.
    my @chars = split //, $format;
    my $result = "";

    # Go through each character, converting it to an strftime format character
    # if there is a conversions specified in the map table
    foreach my $char (@chars) {
        # Do we have a conversion for tis character?
        my $conv = $fmt_map{$char};
        # Append the character or the conversion, if we have one.
        $result .= $conv ? $conv: $char;
    }

    return $result;
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


# ==============================================================================
# Seriously internal stuff

# The following functions have been ported wholesale from the phpBB3 'includes/functions.php'
# The port has been done with minimal regard for perlification, and it almost certainly
# could be implemented in a far more efficient and perl-friendly fashion.
#
# Beware, voodoo programming follows.

## @fn $ _hash_encode64($input, $count, $itoa64)
# Convert a number into an encoded string form.
#
# @param input  The number to encode.
# @param count  The number of characters in the number to convert.
# @param itoa64 The string containing the encoding key.
# @return The encoded string.
sub _hash_encode64 {
    my ($input, $count, $itoa64) = @_;

    my $output = '';
    my $i = 0;

    while($i < $count) {
        my $value = ord(substr($input, $i++, 1));
        $output .= substr($itoa64, $value & 0x3F, 1);

        $value |= ord(substr($input, $i, 1)) << 8 if($i < $count);

        $output .= substr($itoa64, ($value >> 6) & 0x3F, 1);
        last if($i++ >= $count);

        $value |= ord(substr($input, $i, 1)) << 16 if($i < $count);

        $output .= substr($itoa64, ($value >> 12) & 0x3F, 1);
        last if($i++ >= $count);

        $output .= substr($itoa64, ($value >> 18) & 0x3F, 1);
    }

    return $output;
}


## @fn _hash_crypt_private($password, $setting, $itoa64)
# Hash a password within the specified setting. This is mostly voodoo pulled
# straight from phpBB3. Have fun with it.
#
# @param password The plain-text password to hash.
# @param setting  The setting in which the password should be hashed (should be another hash)
# @param itoa64   The string containing the encoding key
# @return A string containing the hashed password.
sub _hash_crypt_private {
    my ($password, $setting, $itoa64) = @_;

    my $output = '*';

    return $output if(substr($setting, 0, 3) ne '$H$');

    my $count_log2 = index($itoa64, substr($setting, 3, 1));
    return $output if($count_log2 < 7 || $count_log2 > 30);

    my $count = 1 << $count_log2;
    my $salt  = substr($setting, 4, 8);

    return $output if(length($salt) != 8);

    my $hash = md5($salt.$password);
    do {
        $hash = md5($hash.$password);
    } while(--$count);

    $output = substr($setting, 0, 12);
    $output .= _hash_encode64($hash, 16, $itoa64);

    return $output;
}


## @fn $ _check_hash($password, $hash)
# Determine whether the specified password hashes to the same string as the provided hash.
# This checks whether the plain-text password, and the previously generated hash, are
# actually representing the same string by hashing the plain-text password and comparing
# it to the specified hash. This function can handle phpBB3 (salted md5 hash) and phpBB2
# (straight md5 hash) hashes and chooses the appropriate algorithm based on the length of
# the hash string: if it is 34 characters, it is assumed to be a phpBB3 hash, otherwise it
# is assumed to be a hex encoded 32 character string.
#
# @param password The plain-text password to hash.
# @param hash     The hash to compared the newly hashed password against
# @return true if the password and hash represent the same string, false if the password
#         hashes to a different string.
sub _check_hash {
    my ($password, $hash) = @_;

    # lifted straight from phpBB3, if that changes, this must be changed!
    my $itoa64 = './0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';

    return (_hash_crypt_private($password, $hash, $itoa64) eq $hash)
        if (length($hash) == 34);

    return md5_hex($password) eq $hash;
}

1;
