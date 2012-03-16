## @file
# This file contains the implementation of the authentication method loader class.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 1.0
# @date    13 March 2012
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
# Dynamic AuthMethod loader class. This provides the facility to load
# AuthMethod subclasses on the fly to support the Auth class. It relies
# on information stored in the auth_methods and auth_params tables to
# load AuthMethod subclasses, initialise them, and pass them back to
# the caller to use.
package AuthMethods;

use strict;

our $errstr;

BEGIN {
	$errstr = '';
}

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Construct a new AuthMethods object. This will create a new AuthMethods object
# initialised with the provided arguments.
#
# @param args A hash of arguments to initialise the AuthMethods object with.
# @return A new AuthMethods object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = {
        @_,
    };

    # Ensure that we have objects that we need
    return set_error("cgi object not set") unless($self -> {"cgi"});
    return set_error("dbh object not set") unless($self -> {"dbh"});
    return set_error("settings object not set") unless($self -> {"settings"});
    return set_error("app object not set") unless($self -> {"app"});

    return bless $self, $class;
}


# ============================================================================
#  Interface code

## @method $ available_methods($only_active)
# Generate a list of available AuthMethod subclasses. This pulls a list of
# auth methods from the database, and returns an array containing the internal
# ids.
#
# @param only_active If true, the returned array will only contain methods
#                    flagged as being active. Otherwise it will contain all
#                    known methods.
# @return A reference to an array of method ids.
sub available_methods {
    my $self = shift;
    my $only_active = shift;

    my $methodh = $self -> {"dbh"} -> prepare("SELECT id FROM ".$self -> {"settings"} -> {"database"} -> {"auth_methods"}.
                                              ($only_active ? " WHERE active = 1 " : " ").
                                              "ORDER BY priority ASC");
    $methodh -> execute()
        or die_log($self -> {"cgi"} -> remote_host(), "Unable to execute auth method list query: ".$self -> {"dbh"} -> errstr);

    my @methods;
    while(my $method = $methodh -> fetchrow_arrayref()) {
        push(@methods, $method -> [0]);
    }

    return \@methods;
}


## @method $ load_method($method_id)
# Load the auth method with the specified id and initialise it. This will
# dynamically load the method with the specified id, provided it is active,
# and return a reference to the method object.
#
# @param method_id The id of the auth method to load.
# @return A reference to an AuthMethod subclass implementing the method
#         on success, undef on failure or if the method is disabled. If this
#         returns undef, $self -> {"lasterr"} is set to a message indicating
#         what went wrong. Note that attempting to load a disabled method is
#         NOT considered an error: this will return undef, but lasterr will
#         be empty.
sub load_method {
    my $self      = shift;
    my $method_id = shift;

    $self -> {"errstr"} = "";

    # Fetch the module name first
    my $moduleh = $self -> {"dbh"} -> prepare("SELECT perl_module, active FROM ".$self -> {"settings"} -> {"database"} -> {"auth_methods"}."
                                               WHERE id = ?");
    $moduleh -> execute($method_id)
        or die_log($self -> {"cgi"} -> remote_host(), "Unable to execute auth method lookup query: ".$self -> {"dbh"} -> errstr);

    my $module = $moduleh -> fetchrow_hashref();
    return $self -> self_error("Unknown auth method requested in load_method($method_id)") if($module);

    # Is the module active? If not, do nothing
    return undef if(!$module -> {"active"});

    # Module is active, fetch its settings
    my $paramh = $self -> {"dbh"} -> prepare("SELECT name, value FROM ".$self -> {"settings"} -> {"database"} -> {"auth_params"}."
                                              WHERE method_id = ?");
    $paramh -> execute($method_id)
        or die_log($self -> {"cgi"} -> remote_host(), "Unable to execute auth method parameter query: ".$self -> {"dbh"} -> errstr);

    # Build up a settings hash using the standard objects, and settings for the
    # module loaded from the database.
    my %settings = ( cgi      => $self -> {"cgi"},
                     dbh      => $self -> {"dbh"},
                     settings => $self -> {"settings"},
                     app      => $self -> {"app"}); # Methods shouldn't actually need access to app, but add it anyway in case.
    while(my $param = $paramh -> fetchrow_hashref()) {
        $settings{$param -> {"name"}} = $param -> {"value"};
    }

    # For readability...
    my $name = $module -> {"perl_module"};

    no strict "refs"; # must disable strict references to allow named module loading.
    eval "require $name";
    die "Unable to load auth module $name: $@" if($@);

    my $methodobj = $name -> new(%settings);
    use strict;

    # Return undef and set error if the call to new returned an error message
    return $self -> self_error("Unable to load auth module: ".$methodobj)
        if(!ref($methodobj));

    # Otherwise, return the auth method object.
    return $methodobj;
}


# ============================================================================
#  Error functions

sub set_error { $errstr = shift; return undef; }

sub self_error { my $self = shift; $self -> {"errstr"} = shift; return undef; }

1;

