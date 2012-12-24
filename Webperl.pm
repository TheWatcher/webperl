## @file
# This file contains the implementation of the base Webperl class.
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
# This is a class intended to contain features common across all Webperl
# modules. At the moment, this is essentially a wrapper around Webperl::Application.
package Webperl;

use strict;
use Webperl::Application;

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Create a new Webperl::Application object. Please refer to the documentation
# for that class for constructor arguments.
#
# @param args A hash of arguments to initialise the Webperl::Application object with.
# @return A new Webperl::Application object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;

    # Discard any invocant or class passed in, this just really makes a new Application
    return Webperl::Application -> new(@_);
}

1;
