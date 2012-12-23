## @file
# This file contains the implementation of the SystemModule base class.
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

## @class SystemModule
# This is a base class for system modules, providing common
# features - primarily a simple base constructor and error functions.
# Subclasses will generally only need to override the constructor, usually
# chaining it with `$class -> SUPER::new(..., @_);`. If attempting to call
# set_error() in a subclass, remember to use SystemModule::set_error().
package SystemModule;

use strict;

our $errstr;

BEGIN {
    $errstr = '';
}

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Create a new SystemModule object. The minimum values you need to provide are:
#
# * dbh       - The database handle to use for queries.
# * settings  - The system settings object
# * logger    - The system logger object.
# * minimal   - Defaults to false. If set to true, the other arguments are
#               treated as optional.
#
# @param args A hash of key value pairs to initialise the object with.
# @return A new SystemModule object, or undef if a problem occured.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = {
        dbh          => undef,
        settings     => undef,
        logger       => undef,
        minimal      => 0,
        max_refcount => 2147483648,
        @_,
    };

    # Check that the required objects are present
    return set_error("No database connection available.") if(!$self -> {"dbh"} && !$self -> {"minimal"});
    return set_error("No settings object available.") if(!$self -> {"settings"} && !$self -> {"minimal"});
    return set_error("No logger object available.") if(!$self -> {"logger"} && !$self -> {"minimal"});

    return bless $self, $class;
}


# ============================================================================
#  Clean shutdown support

## @method void clear()
# A function callable by System to ensure that any circular references do not
# prevent object destruction.
sub clear {
    my $self = shift;

    # The method, it does nothing!
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

    # Log the error in the database if possible.
    $self -> {"logger"} -> log("error", 0, undef, $self -> {"errstr"})
        if($self -> {"logger"} && $self -> {"errstr"});

    return undef;
}


## @method private void clear_error()
# Clear the object's errstr value. This is a convenience function to help
# make the code a bit cleaner.
sub clear_error {
    my $self = shift;

    $self -> self_error(undef);
}


## @method $ errstr()
# Return the current value set in the object's errstr value. This is a
# convenience function to help make code a little cleaner.
sub errstr {
    my $self = shift;

    return $self -> {"errstr"};
}

1;
