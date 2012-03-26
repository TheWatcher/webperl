## @file
# This file contains the implementation of the Module loading class.
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

## @class Modules
# A class to simplify runtime loading of modules. This class simplifies the
# process of loading modules implementing system functionality at runtime: it
# is primarily designed to load webapp block modules, but it can be used to
# load any arbitrary module at runtime if needed.
#
# When this class is used to load other modules, it loads the module into
# the interpreter, and then calls the module's new() function, passing it a
# hash of arguments. The contents of that hash varies somewhat depending
# on the way in which the loader is called, but at a minimum the hash will
# contain the following key/value pairs:
#
# * cgi       - The system-wide CGI object.
# * dbh       - The database handle to use for queries.
# * settings  - The system settings object.
# * template  - The system template object.
# * session   - The session object.
# * module    - The Modules object that loaded the new module.
#
# However, when calling a loaded module's new() function, this class will
# copy the entirity of its $self variable into the argument list, so any
# values present in the object will be made available to modules loaded by
# it.
#
# The new_module(), new_module_byblockid(), and load_module() are the methods
# most likely to be useful to client code. The first two allow modules with
# entries in the blocks table to be loaded at runtime - these modules will be
# passed a special 'args' value in the hash given to their constructor, the
# contents of which are taken from the block's entry in the blocks table. This
# allows the same code to be invoked with different arguments at runtime. The
# load_module() function is a generic module loader, it requires no database
# support, and allows you to pass in an arbitrary hash of values to give to
# the loaded module's constructor. Note that the hash you provide will have
# the contents of the Modules object's $self added to it, so that your loaded
# modules will be given the standard value listed above in addition to any
# values you specify in the argument hash.
package Modules;

use DBI;
use Module::Load;
use Logging qw(die_log);
use strict;

our $errstr;

BEGIN {
    $errstr = '';
}

# ==============================================================================
# Creation

## @cmethod $ new(%args)
# Create a new Modules object. This will create an object that provides functions
# to create block modules on the fly. Any key/value pairs specified in the argument
# hash will be passed to the new() method of loaded modules, so you may wish to
# include more than the minimum when creating objects of this class in some situations.
# The minimum values you need to provide are:
#
# * cgi       - The CGI object to access parameters and cookies through.
# * dbh       - The database handle to use for queries.
# * settings  - The system settings object
# * template  - The system template object
# * session   - The session object
#
# You may also specify the following:
#
# * blockdir  - The directory containing blocks. This adds the specified directory
#               to the perl module loader search path - if not included, the modules
#               you want to load must be in a location already visible to perl.
#
# @param args A hash of key, value pairs to initialise the object with.
# @return A new Modules object, or undef if a problem occured.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = {
        cgi       => undef,
        dbh       => undef,
        phpbb     => undef,
        settings  => undef,
        template  => undef,
        session   => undef,
        blockdir  => undef,
        @_,
    };

    # If we get here and still don't have a database connection, we need to fall over
    return set_error("No database connection available.") if(!$self -> {"dbh"});

    # Check we also have a cgi object to play with
    return set_error("No CGI object available.") if(!$self -> {"cgi"});

    # Aaand settings....
    return set_error("No settings object available.") if(!$self -> {"settings"});

    # ... finally, template
    return set_error("No template object available.") if(!$self -> {"template"});

    my $obj = bless $self, $class;

    # update @INC if needed
    $obj -> add_load_path($self -> {"blockdir"}) if($self -> {"blockdir"});

    # Set the template object's module reference
    $obj -> {"template"} -> set_module_obj($obj);

    # and we're done
    return $obj
}


# ============================================================================
#  Loading support
#

## @method void add_load_path($path)
# Add a path to the list of paths the Modules object can load modules from.
# This updates perl's INC array to include the specified path.
#
# @param path The path to add to the module load paths list.
sub add_load_path {
    my $self = shift;
    my $path = shift;

    unshift(@INC, $path);
}


## @method $ new_module($arg)
# Attempt to create an instance of a module identified by the id or block name
# specified in the argument. Note that the id or name should appear in the
# blocks table, the name in the module table is not used here!
#
# @param arg Either the numeric id or human-readable name for a block to load the module for.
# @return An instance of the module, or undef on error.
sub new_module {
    my $self = shift;
    my $arg  = shift;
    my $mode = "bad";

    # Is the arg all numeric? If so, it's an id
    if($arg =~ /^\d+$/) {
        $mode = "id = ?";

    # names are just alphanumerics
    } elsif($arg =~ /^[a-zA-Z0-9]+$/) {
        $mode = "name LIKE ?";
    }

    return $self -> self_error("Illegal block id or name specified in new_module.") if($mode eq "bad");

    my $sth = $self -> {"dbh"} -> prepare("SELECT * FROM ".$self -> {"settings"} -> {"database"} -> {"blocks"}."
                                           WHERE $mode");
    $sth -> execute($arg) or
        die_log($self -> {"cgi"} -> remote_host(), "new_module: Unable to execute query: ". $self -> {"dbh"} -> errstr);

    my $modrow = $sth -> fetchrow_hashref();

    # If we have a block row, return an instance of the module for it
    return $self -> new_module_byid($modrow -> {"module_id"},
                                    $modrow -> {"args"})
        if($modrow);

    return undef;
}


## @method $ new_module_byblockid($blockid)
# Given a block id, create an instance of the module that implements that block. This
# will look in the blocks table to obtain the module id that implements the block, and
# then create an instance of that module.
#
# @param blockid The id of the block to generate an instance for.
# @return An instance of the module, or undef on error.
sub new_module_byblockid {
    my $self      = shift;
    my $blockid   = shift;

    my $sth = $self -> {"dbh"} -> prepare("SELECT * FROM ".$self -> {"settings"} -> {"database"} -> {"blocks"}."
                                           WHERE id = ?");
    $sth -> execute($blockid) or
        die_log($self -> {"cgi"} -> remote_host(), "new_module_byblockid: Unable to execute query: ". $self -> {"dbh"} -> errstr);

    my $modrow = $sth -> fetchrow_hashref();

    # If we have a block row, return an instance of the module for it
    return $self -> new_module_byid($modrow -> {"module_id"},
                                    $modrow -> {"args"})
        if($modrow);

    return undef;
}


## @method $ new_module_byname($modname, $argument)
# Load a module based on its name in the modules table. This allows direct creation
# of a module from the modules table rather than the normal indirect route via
# new_module() or new_module_byblockid().
#
# @note In most cases, you do not want to use this function - you want to use
#       new_module() instead. Only use this if you know what you are doing.
#
# @param modname  The name of the module to load.
# @param argument Argument to pass to the module constructor.
# @return An instance of the module, or undef on error.
sub new_module_byname {
    my $self      = shift;
    my $modname   = shift;
    my $argument = shift;

    return $self -> _new_module_internal("WHERE name LIKE ?",
                                         $modname,
                                         $argument);
}


## @method $ new_module_byid($modid, $argument)
# Load a module based on its id in the modules table. This allows direct creation
# of a module from the modules table rather than the normal indirect route via
# new_module() or new_module_byblockid().
#
# @note In most cases, you do not want to use this function - you want to use
#       new_module_byblockid() instead. Only use this if you know what you are doing.
#
# @param modid    The id of the module to load.
# @param argument Argument to pass to the module constructor.
# @return An instance of the module, or undef on error.
sub new_module_byid {
    my $self      = shift;
    my $modid     = shift;
    my $argument = shift;

    return $self -> _new_module_internal("WHERE module_id = ?",
                                         $modid,
                                         $argument);
}


## @method private $ _new_module_internal($where, $argument, $modargs)
# Create an instance of a module. This uses the where and argument parameters as part of a database
# query to determine what the actual name of the module is, and then load and instantiate it.
#
# @param where    The WHERE clause to add to the module select query.
# @param argument The argument for the select query.
# @param modargs  The argument to pass to the module.
# @return A new object, or undef if a problem occured or the module is disabled.
sub _new_module_internal {
    my $self     = shift;
    my $where    = shift;
    my $argument = shift;
    my $modarg   = shift;

    my $modh = $self -> {"dbh"} -> prepare("SELECT * FROM ".$self -> {"settings"} -> {"database"} -> {"modules"}." $where");
    $modh -> execute($argument)
        or die_log($self -> {"cgi"} -> remote_host(), "Unable to execute module resolve query: ".$self -> {"dbh"} -> errstr);

    my $modrow = $modh -> fetchrow_hashref();

    # bomb if the mofule record is not found, or the module is inactive
    return $self -> self_error("Unable to locate module $argument using $where, or module is inactive.") if(!$modrow || !$modrow -> {"active"});

    my $name = $modrow -> {"perl_module"};

    return $self -> load_module($name, id => $modrow -> {"module_id"}, args => $modarg);
}


## @method $ load_module($name, %args)
# Load a module, and initialise it with the specified parameters and the
# values set in the Modules object. This loads the named class and calls
# its new() function, passing it a hash containing the id, modarg, any
# arguments specified in the call to this function, and the values set
# if the Modules object this is called on.
#
# @param name The name of the perl module to load, without trailing .pm
# @param args A hash of additional arguments to pass to the module
#               constructor.
# @return A reference to an instance of the module, or undef. If this
#         returns undef, inspect $self -> {"errstr"}
sub load_module {
    my $self   = shift;
    my $name   = shift;
    my %args   = @_;

    no strict "refs"; # must disable strict references to allow named module loading.
    eval { load $name };
    die "Unable to load module $name: $@" if($@);

    $args{"module"} = $self; # Allow the created object to invoke the module loader too

    # Copy $self's settings over
    foreach my $key (keys(%{$self})) {
        $args{$key} = $self -> {$key} if(!defined($args{$key}));
    }

    # Render unto us a new instance of thyself!
    my $modobj = $name -> new(%args)
        or $self -> self_error("Unable to load module: ".$Block::errstr);
    use strict;

    return $modobj;
}


## @method $ build_sidebar($side, $page)
# Generate the contents of a sidebar. This will load the modules listed as appearing on the specified
# side of the page, and call on their block_display() functions, concatenating the results into one
# large string.
#
# @deprecated This function is considered deprecated, and should not be used
#             in new code (unless you find a real use for it...) The same
#             behaviour can generally be implemented more natually by loading
#             sidebar generation blocks inside block implementations.
#
# @param side The side to generate the blocks for. Must be 'left' or 'right'.
# @param page An optional page ID (corresponding to the module currently shown on in the core of the
#             page) that can be used to filter the blocks shown in the sidebar.
# @return A string containing the sidebar HTML, or undef if there was an error.
sub build_sidebar {
    my $self = shift;
    my $side = shift;
    my $page = shift || 0;

    # Bomb with an error is side is not valid
    return $self -> self_error("build_sidebar called with an illegal value for side: $side")
        unless($side eq "left" || $side eq "right");

    # If a page is specified, we need to filter on it, or zero. OTherwise we'll be filtering on just 0
    my $filter = $page ? "(filter = ? OR filter = 0)" : "filter = ?";

    # Pull out blocks that match the specified side type, filtering them so that only 'always show' or blocks
    # that show on the current page are shown.
    my $sth = $self -> {"dbh"} -> prepare("SELECT * FROM ".$self -> {"settings"} -> {"database"} -> {"blocks"}."
                                           WHERE TYPE = ? AND $filter
                                           ORDER BY position");
    $sth -> execute($side, $page) or
        die_log($self -> {"cgi"} -> remote_host(), "build_sidebar: Unable to execute query: ". $self -> {"dbh"} -> errstr);

    my $result = "";
    while(my $row = $sth -> fetchrow_hashref()) {
        # Load the block module
        my $headerobj = $self -> new_module_byid($row -> {"module_id"},
                                                 $row -> {"args"});

        # If we have an object, ask it do generate its block display.
        $result .= $headerobj -> block_display() if($headerobj);
    }

    return $result;
}


# ============================================================================
#  Block identification support

## @method $ get_block_id($blockname)
# Obtain the id of a block given its unique name. This will, hopefully, allow templates
# to include references to modules without hard-coding IDs (ironically, hard coding
# the module names seems so much less nasty... weird...)
#
# @param blockname The name of the block to obtain the id for.
# @return The block id, or undef if the name can not be located.
sub get_block_id {
    my $self = shift;
    my $blockname = shift;

    my $blockh = $self -> {"dbh"} -> prepare("SELECT id FROM ".$self -> {"settings"} -> {"database"} -> {"blocks"}."
                                              WHERE name LIKE ?");
    $blockh -> execute($blockname)
        or die_log($self -> {"cgi"} -> remote_host(), "get_block_id: Unable to execute query: ". $self -> {"dbh"} -> errstr);

    # Do we have the block?
    my $blockr = $blockh -> fetchrow_arrayref();

    # If we have the block id return it, otherwise return undef.
    return $blockr ? $blockr -> [0] : undef;
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

    return undef;
}

1;
