## @file
# This file contains the implementation of a compact, simple congifuration
# loading and saving class.
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

## @class ConfigMicro
# A simple configuration class intended to allow ini files to be read and saved. This
# class reads the contents of an .ini style file, and stores the sections and
# key/value pairs in the object's hash. A typical configuration file could look like
#
#     ; comments can start with semicolons
#     # or with U+0023
#     [sectionA]
#     keyA = valueA  # hash comments can appear after values, too
#     keyB = valueB
#
#     [sectionB]
#     keyA = valueC
#     keyC = "  example with spaces  ";
#
# Leading and trailing spaces are removed from values (so the value for keyA above
# will be 'valueA', without the leading and trailing spaces). Values may be enclosed
# in quotes "", in which case any spaces within the "" are left untouched - keyC's
# value will retain the two leading and trailing spaces, for example.
#
# Note also that keys in different sections may have the same name, but different
# values. If two keys with the same name appear in the same section, the value for
# the second copy of the key will overwrite any value set for the first. Keys and
# sections are case sensitive: `SectionA` and `sectionA` would be different sections.
# Similarly, if 'keyA' and 'KeyA' appear in the same section, they will be treated
# as different keys!
#
# If the above example is saved as 'foo.cfg', it can be loaded and accessed using
# code like:
#
#     use ConfigMicro;
#     my $cfg = ConfigMicro -> new('foo.cfg');
#
#     # Print out the value of keyB in sectionA
#     print "keyA in sectionA = '",$cfg -> {"sectionA"} -> {"keyA"},"'\n";
#     print "keyA in sectionB = '",$cfg -> {"sectionB"} -> {"keyA"},"'\n";
#
# The ConfigMicro class provides three functions for pulling configuration data in
# from a database, in addition to (or even instead of) from a file. Calling the
# load_db_config() method in any ConfigMicro object allows a table containing key/value
# pairs to be read into a configuration section. save_db_config() and set_db_config()
# allow modifications made to configuration settings to be saved back into the table.
package ConfigMicro;

require 5.005;
use DBI;
use strict;

our $errstr;

BEGIN {
	$errstr = '';
}

# ============================================================================
#  Constructor and basic file-based config functions

## @cmethod $ new(%args)
# Create a new ConfigMicro object. This creates an object that provides functions
# for loading and saving configurations, and pulling config data from a database.
# Meaningful options for this are:
# filename - The name of the configuration file to read initial settings from. This
#            is optional, and if not specified you will get an empty object back.
# You may also pass in one or more initial configuration settings.
# @param args A hash of key, value pairs to initialise the object with.
# @return A new ConfigMicro object, or undef if a problem occured.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $filename = shift;

    # Object constructors don't get much more minimal than this...
    my $self = { "__privdata" => { "modified" => 0 },
                 @_,
    };

    my $obj = bless $self, $class;

    # Return here if we have no filename to load from
    return $obj if(!$filename);

    # Otherwise, try to read the file
    return $obj if($obj -> read($filename));

    # Get here and things have gone wahoonie-shaped
    return set_error($obj -> {"errstr"});
}


## @method $ read($filename)
# Read a configuration file into a hash. This will process the file identified by
# the specified filename, attempting to load its contents into a hash. Any key/value
# pairs that occur before a [section] header are added to the '_' section.
#
# @param filename The name of the file to read the config data from.
# @return True if the configuration has been loaded sucessfully, false otherwise. If
#         this returns false, $obj -> {"errstr"} will contain the reason why.
sub read {
    my $self     = shift;
    my $filename = shift or return set_error("No file name provided");

    # The current section, default it to '_' in case there is no leading [section]
    my $section = "_";

    # TODO: should this return the whole name? Possibly a security issue here
    return $self -> self_error("Failed to open '$filename': $!")
        if(!open(CFILE, "< $filename"));

    my $counter = 0;
    while(my $line = <CFILE>) {
        chomp($line);
        ++$counter;

        # Skip comments and empty lines
        next if($line =~ /^\s*(\#|;|\z)/);

		# Handle section headers, allows for comments after the ], but [foo #comment] will
        # treat the section name as 'foo #comment'!
        if($line =~ /^\s*\[([^\]]+)\]/) {
            $section = $1;

        # Attribues with quoted values. value can contain anything other than "
		} elsif($line =~ /^\s*([\w\-]+)\s*=\s*\"([^\"]+)\"/ ) {
			$self -> {$section} -> {$1} = $2;

        # Handle attributes without quoted values - # or ; at any point will mark comments
		} elsif($line =~ /^\s*([\w\-]+)\s*=\s*([^\#;]+)/ ) {
            my $key = $1;
			$self -> {$section} -> {$key} = $2;
            $self -> {$section} -> {$key} =~ s/^\s*(.*?)\s*$/$1/;
        # bad input...
		} else {
            close(CFILE);
            return $self -> self_error("Syntax error on line $counter: '$line'");
        }
	}

    close(CFILE);

    return 1;
}


## @method $ text_config(@skip)
# Create a text version of the configuration stored in this ConfigMicro object.
# This creates a string representation of the configuration suitable for writing to
# an ini file or otherwise printing.
#
# @param skip If you specify one or more section names, the sections will not be
#             added to the string generated by this function.
# @return A string representation of this ConfigMicro's config settings.
sub text_config {
    my $self = shift;
    my @skip = @_;
    my $result;

    my ($key, $skey);
    foreach $key (sort(keys(%$self))) {
        # Skip the internal settings
        next if($key eq "__privdata");

        # If we have any sections to skip, and the key is one of the ones to skip... skip!
        next if(scalar(@skip) && grep($key, @skip));

        # Otherwise, we want to start a new section. Entries in the '_' section go out
        # with no section header.
        $result .= "[$key]\n" if($key ne "_");

        # write out all the key/value pairs in the current section
        foreach $skey (sort(keys(%{$self -> {$key}}))) {
            $result .= $skey." = \"".$self -> {$key} -> {$skey}."\"\n";
        }
        $result .= "\n";
    }
    return $result;
}


## @method $ write($filename, @skip)
# Save a configuration hash to a file. Writes the contents of the configuration to
# a file, formatting the output as an ini-style file.
#
# @param filename The file to save the configuration to.
# @param skip     An optional list of names of sections to ignore when writing the
#                 configuration.
# @return true if the configuration was saved successfully, false if a problem
#         occurred.
sub write {
    my $self     = shift;
    my $filename = shift or return set_error("No file name provided");
    my @skip     = @_;

    # Do nothing if the config has not been modified.
    return 0 if(!$self -> {"__privdata"} -> {"modified"});

    return $self -> self_error("Failed to save '$filename': $!")
        if(!open(CFILE, "> $filename"));

    print CFILE $self -> text_config(@skip);

    close(CFILE);

    return 1;
}


# ============================================================================
#  Database config functions

## @method $ load_db_config($dbh, $table, $namecol, $valuecol, $section)
# Load settings from a database table. This will pull name/value pairs from the
# named database table, storing them in the ConfigMicro object in the specified
# section. Note that if the section exists, and contains key/value pairs, any
# keys with the same name read from the database will overwrite those already
# in the configuration section in memory.
#
# @param dbh      A database handle to issue queries through.
# @param table    The name of the table containing key/value pairs.
# @param namecol  Optional name of the table column for the key name, defaults to `name`
# @param valuecol Optional name of the table column for the value, defaults to `value`
# @param section  Optional name of the section to load key/value pairs into, defaults to `config`.
# @return true if the configuration table was read into the config object, false
#         if a problem occurred.
sub load_db_config {
    my $self     = shift;
    my $dbh      = shift or return $self -> self_error("No database handle provided");
    my $table    = shift or return $self -> self_error("Settings table name not provided");
    my $namecol  = shift || "name";
    my $valuecol = shift || "value";
    my $section  = shift || "config";

    my $confh = $dbh -> prepare("SELECT * FROM $table");
    $confh -> execute()
       or return $self -> self_error("Unable to execute SELECT query - ".$dbh -> errstr);

    my $row;
    while($row = $confh -> fetchrow_hashref()) {
        $self -> {$section} -> {$row -> {$namecol}} = $row -> {$valuecol};
    }

    # store the information about where the configuration data came from
    $self -> {"__privdata"} -> {"dbconfig"} = { "dbh"      => $dbh,
                                                "table"    => $table,
                                                "namecol"  => $namecol,
                                                "valuecol" => $valuecol,
                                                "section"  => $section };
    return 1;
}


## @method $ save_db_config($dbh, $table, $namecol, $valuecol, $section)
# Save the database configuration back into the database table. This will write the
# key/value pairs inside the key/value pairs in the specified section back into the
# specified table in the database. If no database, table, or other arguments are
# provided, this will attempt to use the database, table, and other settings provided
# when load_db_config() was called. If this is called without arguments, and
# load_db_config() has not yet been called, this returns false.
#
# @param dbh      Optional database handle to issue queries through.
# @param table    Optional name of the table containing key/value pairs.
# @param namecol  Optional name of the table column for the key name.
# @param valuecol Optional name of the table column for the value.
# @param section  Optional name of the section to save key/value pairs from.
# @return true if the configuration table was updated from the config object, false
#         if a problem occurred.
sub save_db_config {
    my $self     = shift;
    my $dbh      = shift;
    my $table    = shift;
    my $namecol  = shift;
    my $valuecol = shift;
    my $section  = shift;

    # Try to pull values out of the dbconfig settings if not specified
    $dbh      = $self -> {"__privdata"} -> {"dbconfig"} -> {"dbh"}      if(!defined($dbh)      && defined($self -> {"__privdata"} -> {"dbconfig"} -> {"dbh"}));
    $table    = $self -> {"__privdata"} -> {"dbconfig"} -> {"table"}    if(!defined($table)    && defined($self -> {"__privdata"} -> {"dbconfig"} -> {"table"}));
    $namecol  = $self -> {"__privdata"} -> {"dbconfig"} -> {"namecol"}  if(!defined($namecol)  && defined($self -> {"__privdata"} -> {"dbconfig"} -> {"namecol"}));
    $valuecol = $self -> {"__privdata"} -> {"dbconfig"} -> {"valuecol"} if(!defined($valuecol) && defined($self -> {"__privdata"} -> {"dbconfig"} -> {"valuecol"}));
    $section  = $self -> {"__privdata"} -> {"dbconfig"} -> {"section"}  if(!defined($section)  && defined($self -> {"__privdata"} -> {"dbconfig"} -> {"section"}));

    # Give up unless everything needed is available.
    return $self -> self_error("database configuration data missing in save_db_config()")
        unless($dbh && $table && $namecol && $valuecol && $section);

    my $confh = $dbh -> prepare("UPDATE $table SET `$valuecol` = ? WHERE `$namecol` = ?");

    foreach my $key (keys(%{$self -> {$section}})) {
        $confh -> execute($self -> {$section} -> {$key}, $key)
            or return $self -> self_error("Unable to execute UPDATE query - ".$dbh -> errstr);
    }

    return 1;
}


## @method $ set_db_config($name, $value, $dbh, $table, $namecol, $valcol, $section)
# Set the named configuration variable to the specified value. This updates the
# settings variable with the specified name to the value provided in both the
# database and in the ConfigMicro object. Use this function if you only need to
# update a small number of configuration values, otherwise consider updating the
# configuration section yourself and using save_db_config() to bulk-save the options.
# If no database, table, or later arguments are provided, this will attempt to use
# the database, table, and other settings provided when load_db_config() was called.
# If this is called without arguments, and load_db_config() has not yet been called,
# this returns false.
#
# @param name     The name of the variable to update.
# @param value    The value to change the variable to.
# @param dbh      Optional database handle to issue queries through.
# @param table    Optional name of the table containing key/value pairs.
# @param namecol  Optional name of the table column for the key name.
# @param valuecol Optional name of the table column for the value.
# @param section  Optional name of the section to save key/value pairs from.
# @return true if the config variable was changed, false otherwise.
sub set_db_config {
    my $self     = shift;
    my $name     = shift;
    my $value    = shift;
    my $dbh      = shift;
    my $table    = shift;
    my $namecol  = shift;
    my $valuecol = shift;
    my $section  = shift;

    # Catch potential problems with the API change, and make name and value safer anyway.
    die "ConfigMicro::set_db_config: name must be a scalar value" if(ref($name));
    die "ConfigMicro::set_db_config: value must be a scalar value" if(ref($value));

    # Try to pull values out of the dbconfig settings if not specified
    $dbh      = $self -> {"__privdata"} -> {"dbconfig"} -> {"dbh"}      if(!defined($dbh)      && defined($self -> {"__privdata"} -> {"dbconfig"} -> {"dbh"}));
    $table    = $self -> {"__privdata"} -> {"dbconfig"} -> {"table"}    if(!defined($table)    && defined($self -> {"__privdata"} -> {"dbconfig"} -> {"table"}));
    $namecol  = $self -> {"__privdata"} -> {"dbconfig"} -> {"namecol"}  if(!defined($namecol)  && defined($self -> {"__privdata"} -> {"dbconfig"} -> {"namecol"}));
    $valuecol = $self -> {"__privdata"} -> {"dbconfig"} -> {"valuecol"} if(!defined($valuecol) && defined($self -> {"__privdata"} -> {"dbconfig"} -> {"valuecol"}));
    $section  = $self -> {"__privdata"} -> {"dbconfig"} -> {"section"}  if(!defined($section)  && defined($self -> {"__privdata"} -> {"dbconfig"} -> {"section"}));

    # Give up unless everything needed is available.
    return $self -> self_error("database configuration data missing in set_db_config()")
        unless($dbh && $table && $namecol && $valuecol && $section);

    my $confh = $dbh -> prepare("UPDATE $table SET `$valuecol` = ? WHERE `$namecol` = ?");
    $confh -> execute($value, $name)
        or return $self -> self_error("Unable to execute UPDATE query - ".$dbh -> errstr);

    $self -> {$section} -> {$name} = $value;

    return 1;
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
