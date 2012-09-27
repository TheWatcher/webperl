## @file
# This file contains the implementation of the base Message Transport class.
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

## @class Message::Transport
# This is the 'base' class for the Message::Transport modules. It provides
# any functionality that needs to be shared between the Message::Transport::*
# modules.
package Message::Transport;
use strict;
use base qw(Message);

# ============================================================================
#  Delivery

## @method $ deliver($message)
# Attempt to deliver the specified message to its recipients. This function
# does not actually do anything in the Message::Transport class - it must
# be overridden in subclasses to actually perform message delivery.
#
# @param message A reference to hash containing the message data.
# @return true if the message is sent successfully, undef if not.
sub deliver {
    my $self    = shift;
    my $message = shift;

    return $self -> self_error("Attempt to send message '".$message -> {"id"}."' through transport ".ref($self)." with no deliver() mechanism.");
}


## @method $ allow_disable()
# If this transport can be disabled for users, this returns true. Otherwise it
# will return false - the default is false, and subclasses must override this
# function if they want to allow users to disable delivery.
#
# @return true if the transport supports being disabled per-user, false otherwise.
sub allow_disable {
    my $self = shift;

    return 0;
}


## @method $ use_transport($userid)
# Determine whether the user wants to use the current transport. By default, all
# transports are set to be used for all users.
#
# @param userid The ID of the user to check.
# @return true if the user wants to receive messages through this transport, false
#         if they don't, undef on error.
sub use_transport {
    my $self   = shift;
    my $userid = shift;

    # If there is no transport user control table, all transports work
    return 1 unless($self -> {"settings"} -> {"database"} -> {"message_userctrl"});

    my $enableh = $self -> {"dbh"} -> prepare("SELECT enabled
                                               FROM `".$self -> {"settings"} -> {"database"} -> {"message_userctrl"}."`
                                               WHERE transport_id = ?
                                               AND user_id = ?");
    $enableh -> execute($self -> {"transport_id"}, $userid)
        or return $self -> self_error("Unable to execute user transport control lookup: ".$self -> {"dbh"} -> errstr);

    # If there's no entry for this user for this transport, assume the user should get messages
    my $enabled = $enableh -> fetchrow_arrayref()
        or return 1;

    return $enabled -> [0];
}


1;
