## @file
# This file contains the implementation of the Database authentication class.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 1.0
# @date    12 March 2012
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
# Implementation of a basic database authentication class. This will
# compare a user's credentials to those stored in a database table.
# The users' passwords are never stored as plain text - this uses a
# salted, hashed storage mechanism for passwords.
#
# This module will expect at least the following configuration values
# to be passed to the constructor.
#
# * table     - The name of the database table to authenticate against.
#               This must be accessible to the system-wide dbh object.
# * userfield - The name of the column in the table that stores usernames.
# * passfield - The password column in the table.
#
# The following arguments may also be provided to the module constructor:
#
# * bcrypt_cost - the number of iterations of hashing to perform. This
#                 defaults to COST_DEFAULT if not specified.
package AuthMethod::Database;

use strict;
use base qw(AuthMethod); # This class extends AuthMethod
use Crypt::Eksblowfish::Bcrypt qw(bcrypt en_base64);

# Custom module imports
use Logging qw(die_log);

use constant COST_DEFAULT => 14; # The default cost to use if bcrypt_cost is not set.


# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Construct a new AuthMethod object. This will create a new AuthMethod object
# initialised with the provided arguments. All the arguments are copied into
# the new object 'as is', with no processing - the caller must make sure they
# are sane before calling this.
#
# @param args A hash of arguments to initialise the AuthMethod object with.
# @return A new AuthMethod object on success, an error message otherwise.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(@_);

    # bomb if the parent constructor failed.
    return $class -> SUPER::get_error() if(!$self);

    # Set default values as needed
    $self -> {"bcrypt_cost"} = COST_DEFAULT;

    # check that required settings are set...
    return "AuthMethod::Database missing 'table' argument in new()" if(!$self -> {"table"});
    return "AuthMethod::Database missing 'userfield' argument in new()" if(!$self -> {"userfield"});
    return "AuthMethod::Database missing 'passfield' argument in new()" if(!$self -> {"passfield"});

    return $self;
}


# ============================================================================
#  Interface code

## @method $ authenticate($username, $password, $auth)
# Attempt to authenticate the user against the database. This will check the user's
# login against the configured database tabke, and return true if the login is valid.
#
# @param username The username to check against the database.
# @param password The password to check against the database.
# @param auth     A reference to the Auth object calling this function,
#                 if any errors are encountered while performing the
#                 authentication, they will be appended to $auth -> {"lasterr"}.
# @return true if the user's credentials are valid, false otherwise.
sub authenticate {
    my $self     = shift;
    my $username = shift;
    my $password = shift;
    my $auth     = shift;

    my $userh = $self -> {"dbh"} -> prepare("SELECT ".$self -> {"passfield"}." FROM ".$self -> {"table"}."
                                             WHERE ".$self -> {"userfield"}." LIKE ?");
    $userh -> execute($username)
        or die_log($self -> {"cgi"} -> remote_host(), "Unable to execute user lookup query: ".$self -> {"dbh"} -> errstr);

    # If a user has been found with the specified username, check the password...
    my $user = $userh -> fetchrow_arrayref();
    if($user && $user -> [0]) {
        my $hash = $self -> hash_password($password, $user -> [0]);

        # If the new hash matches the stored hash, the password is valid.
        return ($hash eq $user -> [0]);
    }

    return 0;
}


## @method $ hash_password($password, $settings)
# Generate a salted hash of the supplied password. This will create a 59 character
# long string containing the hashed password and its salt suitable for storing in
# the database. If the $settings string is not provided, one will be generated.
# When creating accounts, $settings will be omitted unless the caller wants to
# provide its own salting system. When checking passwords, password should be the
# password being checked, and settings should be a hash string previously
# generated by this function. The result of this function can then be compared to
# the stored hash to determine whether the password is correct.
#
# @param password The plain-text password to check.
# @param settings An optional settings string, leave undefined for new accounts,
#                 set to a previously generated hash string when doing password
#                 validity checking.
# @return A bcrypt() generated, 59 character hash containing the settings string
#         and the hashed, salted password.
sub hash_password {
    my $self     = shift;
    my $password = shift;
    my $settings = shift || generate_settings($self -> {"bcrypt_cost"});

    return bcrypt($password, $settings);
}


# ============================================================================
#  Ghastly internals

## @fn private $ generate_settings($cost)
# Generate a settings string to provide to bcrypt(). This will generate a
# string in the form '$2$', followed by the cost - which will be padded with a
# leading zero for you if it is less than 10, and does not have one already -
# followed by '$' and then a 22 character Base64 encoded string containing the
# password salt.
#
# @todo This uses /dev/urandom directly, which is not only unportable, it
#       is cryptographically weak. /dev/random fixes the latter - at the cost
#       of potentially blocking the user, and has therefore been avoided.
#       Possibly switching to Crypt::Random, and doing account creation
#       asynchronously (ie: users do not get immediately created accounts)
#       would allow proper strength salting in a potentially platform-neutral
#       fashion here.
#
# @param cost The cost of the hash. The number of hash iterations is 2^cost.
#             This should be as high as possible (at least 14, preferably over 16)
#             while not drastically slowing user login.
# @return A settings string suitable for use with bcrypt().
sub generate_settings {
    my $cost = shift;

    # Make sure the cost has a leading zero if needed.
    $cost = "0$cost"
        unless($cost > 9 || $cost =~ /^0\d$/);

    # Bytes, bytes, we need random(ish) byes!
    open(RND, "/dev/urandom")
        or die "Unable to open random source: $!\n";
    binmode(RND);

    my $buffer;
    my $read = read(RND, $buffer, 16);
    die "Unable to read 16 bytes from random source: $!\n" if($read != 16);
    close(RND);

    # Can't use MIME::Base64 directly here as bcrypt() expects a somewhat...
    # idiosycratic variation of base64 encoding. Use its own encoder instead.
    return '$2$'.$cost.'$'.en_base64($buffer);
}

1;
