## @file
# This file contains the implementation of the base class for application-specific
# class loading.
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
# The base class for appplication-specific module loading. Subclasses of
# this class allow applications to load and initialise any system-specific
# modules.
package System;

use strict;
use base qw(SystemModule);

# ============================================================================
#  Constructor and initialiser

## @cmethod System new(%args)
# Create a new System object. This will create an System object that may be
# used by blocks throughout the application. Generally this method will not
# do any real work, and subclasses will generally never need to override it -
# actual initialisation should be done in the init() method.
#
# @param args A hash of arguments to initialise the System object with.
# @return A new System object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = {
        @_,
    };

    return bless $self, $class;
}


## @method $ init(%args)
# Initialise the System's references to other system objects. This allows the
# setup of the object to be deferred from construction. Subclasses will need
# to override this function to perform system-specific module loading and
# setup.
#
# @param args A hash of arguments to initialise the System object with. The
#             arguments must minimally include the logger, cgi, dbh, settings,
#             template, session, and modules handles.
# @return true on success, false if something failed. If this returns false,
#         the reason is in $self -> {"errstr"}.
sub init {
    my ($self, %args) = @_;

    # COPY ALL THE THINGS
    foreach my $key (keys(%args)) {
        $self -> {$key} = $args{$key};
    }

    return 1;
}


# ============================================================================
#  Cleanup

## @method void clear()
# Delete all references to other application objects from this System object. This
# must be called before the program closes to prevent circular references messing
# with cleanup. Subclasses should override this to explicitly break any circular
# references created during init().
sub clear {
    my $self = shift;

    # clear all the references in $self. Yes, this is inefficient, but
    # the alternative is reassigning self... so no, delete them all.
    foreach my $key (keys %{$self}) {
        $self -> {$key} -> clear() if($self -> {$key} -> can("clear"));
        delete $self -> {$key};
    }
}

1;
