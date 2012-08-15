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
use Utils qw(hash_or_hashref);

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
    my $self = $class -> SUPER::new(@_)
        or return undef;

    return $self;
}


## @method void DESTROY()
# Destructor method to prevent a circular list formed from a reference to the modules
# object from derailing normal destruction.
sub DESTROY {
    my $self = shift;

    $self -> {"module"} = undef;
}


## @method void set_module_obj($module)
# Set the reference to the system module loader. This allows deferred initialisation
# of the module loader.
#
# @param module A reference to the system module handler object.
sub set_module_obj {
    my $self = shift;

    $self -> {"module"} = shift;
}


# ============================================================================
#  Transport handling

## @method $ get_transports($include_inactive)
# Obtain a list of currently defined message transports. This will return an array of
# transport hashes describing the currently defined transports.
#
# @param include_inactive Include all transports, even if they are marked as inactive.
# @return A reference to an array of transport record hashrefs.
sub get_transports {
    my $self             = shift;
    my $include_inactive = shift;

    $self -> clear_error();

    my $transh = $self -> {"dbh"} -> prepare("SELECT *
                                              FROM `".$self -> {"settings"} -> {"database"} -> {"message_transports"}."`".
                                             ($include_inactive ? "" : " WHERE enabled = 1"));
    $transh -> execute()
        or return $self -> self_error("Unable to perform message transport lookup: ". $self -> {"dbh"} -> errstr);

    return $transh -> fetchall_arrayref({});
}


## @method $ load_transport_module($args)
# Attempt to load an create an instance of a Message::Transport module.
#
# @param modulename The name of the transport module to load.
# @return A reference to an instance of the requested transport module on success,
#         undef on error.
sub load_transport_module {
    my $self = shift;
    my $args = hash_or_hashref(@_);

    return $self -> self_error("Module loader not available at this time")
        unless($self -> {"module"});

    # Work out which field is being searched on
    my $field;
    if($args -> {"id"}) {
        $field = "id";
    } elsif($args -> {"name"}) {
        $field = "name";
    } else {
        return $self -> self_error("Incorrect arguments to load_transport_module: id or name not provided");
    }

    my $modh = $self -> {"dbh"} -> prepare("SELECT perl_module
                                            FROM `".$self -> {"settings"} -> {"database"} -> {"message_transports"}."`
                                            WHERE $field = ?");
    $modh -> execute($args -> {$field})
        or return $self -> self_error("Unable to execute transport module lookup: ".$self -> {"dbh"} -> errstr);

    my $modname = $modh -> fetchrow_arrayref()
        or return $self -> self_error("Unable to fetch module name for transport module: entry does not exist");

    return $self -> {"module"} -> load_module($modname -> [0]);
}

1;
