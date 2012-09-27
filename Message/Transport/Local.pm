## @file
# This file contains the implementation of the Local Message Transport class.
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

## @class Message::Transport::Local
# This class implements the local delivery transport. Local delivery actually involves
# no work whatsoever - any messages that are queued for local deliver can always be
# delivered.
package Message::Transport::Local;
use strict;
use base qw(Message::Transport);

# ============================================================================
#  Delivery

## @method $ deliver($message)
# Attempt to deliver the specified message to its recipients. This function
# is always successful - it is impossible for local delivery to fail, as the
# message is already there!
#
# @param message A reference to hash containing the message data.
# @return Always returns true.
sub deliver {
    my $self    = shift;
    my $message = shift;

    return 1;
}

1;
