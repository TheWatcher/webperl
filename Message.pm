## @file
# This file contains the implementation of the base Message class.
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

## @class Message
# This is the 'base' class for the Message modules. It provides any functionality
# that needs to be shared between the Message::* modules.
package Message;
use strict;
use base qw(SystemModule);

# ============================================================================
#  Constructor

## @cmethod Message new(%args)
# Create a new Message object. This will create an Message object that may be
# used to store messages to send at a later date, or invoked to send messages
# immediately or from the queue.
#
# @param args A hash of arguments to initialise the Message object with.
# @return A new Message object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;

    return $class -> SUPER::new(@_);
}

1;
