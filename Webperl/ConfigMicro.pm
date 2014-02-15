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
# along with this program.  If not, see http://www.gnu.org/licenses/.

## @class
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
package Webperl::ConfigMicro;

use strict;
use base qw(Webperl::SystemModule); # Extend SystemModule to get error handling
use DBI;


# ============================================================================
#  Constructor and basic file-based config functions

## @cmethod $ new($filename, %args)
# Create a new Webperl::ConfigMicro object. This creates an object that provides functions
# for loading and saving configurations, and pulling config data from a database.
# Meaningful options for args are:
#
# - `quote_values` If set to a non-empty string, this string is used to quote values
#                  written as part of as_text() or write(). The default is '"'. If
#                  this is set to an empty string, values are not quoted.
# - `inline_comments` If true (the default), comments may be included in values. If
#                  this is set to false, # and ; in values are treated as literals and
#                  not as comments.
#
# @param filename The name of the configuration file to read initial settings from. This
#                 is optional, and if not specified you will get an empty object back.
# @param args A hash of key, value pairs to initialise the object with.
# @return A new Webperl::ConfigMicro object, or undef if a problem occured.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $filename = shift;
    my $self     = $class -> SUPER::new(minimal         => 1, # minimal tells SystemModule to skip object checks
                                        quote_values    => '"',
                                        inline_comments => 1,
                                        @_)
        or return undef;

    # Return here if we have no filename to load from
    return $self if(!$filename);

    # Otherwise, try to read the file
    return $self if($self -> read($filename));

    # Get here and things have gone wahoonie-shaped
    return Webperl::SystemModule::set_error($self -> {"errstr"});
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
    my $filename = shift or return $self -> self_error("No file name provided");

    # The current section, default it to '_' in case there is no leading [section]
    my $section = "_";

    # TODO: should this return the whole name? Possibly a security issue here
    return $self -> self_error("Failed to open '$filename': $!")
        if(!open(CFILE, "<:utf8", $filename));

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
		} elsif($line =~ /^\s*(.*?\w)\s*=\s*\"([^\"]+)\"/ ) {
			$self -> {$section} -> {$1} = $2;

        # Handle attributes without quoted values - # or ; at any point will mark comments
		} elsif(!$self -> {"inline_comments"} && $line =~ /^\s*(.*?\w)\s*=\s*(.+)$/ ) {
            my $key = $1;
			$self -> {$section} -> {$key} = $2;
            $self -> {$section} -> {$key} =~ s/^\s*(.*?)\s*$/$1/;

		} elsif($self -> {"inline_comments"} && $line =~ /^\s*(.*?\w)\s*=\s*([^;#]+)/ ) {
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

    # Store the filename for later use
    $self -> {"filename"} = $filename;

    return 1;
}


## @method $ as_text(@skip)
# Create a text version of the configuration stored in this ConfigMicro object.
# This creates a string representation of the configuration suitable for writing to
# an ini file or otherwise printing.
#
# @param skip If you specify one or more section names, the sections will not be
#             added to the string generated by this function.
# @return A string representation of this ConfigMicro's config settings.
sub as_text {
    my $self = shift;
    my @skip = @_;
    my $result;

    my ($key, $skey);
    foreach $key (sort(keys(%$self))) {
        # Skip the internal settings
        next unless(ref($self -> {$key}) eq "HASH");

        # If we have any sections to skip, and the key is one of the ones to skip... skip!
        next if(scalar(@skip) && grep($key, @skip));

        # Otherwise, we want to start a new section. Entries in the '_' section go out
        # with no section header.
        $result .= "[$key]\n" if($key ne "_");

        my $fieldwidth = $self -> _longest_key($self -> {$key});
        if($fieldwidth) {
            # write out all the key/value pairs in the current section
            foreach $skey (sort(keys(%{$self -> {$key}}))) {
                $result .= $skey.(" " x (($fieldwidth - length($skey)) + 1))."= ";
                $result .= $self -> {"quote_values"} if($self -> {"quote_values"});
                $result .= $self -> {$key} -> {$skey};
                $result .= $self -> {"quote_values"} if($self -> {"quote_values"});
                $result .= "\n";
            }
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
    my $filename = shift || $self -> {"filename"};
    my @skip     = @_;

    return $self -> self_error("Write failed: no filename available.")
        if(!$filename);

    return $self -> self_error("Failed to open '$filename' for writing: $!")
        if(!open(CFILE, ">:utf8", $filename));

    print CFILE $self -> as_text(@skip)
        or return $self -> self_error("Write to '$filename' failed: $!");

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


## @method $ set_db_config($name, $value, $dbh, $table, $namecol, $valuecol, $section)
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
#  Private functions

## @method private $ _longest_key($hashref)
# Determine the length of the longest key string in the specified hashref.
#
# @param hashref A reference to a hash to get the longest key length for
# @return The longest key length, 0 if the hashref is empty
sub _longest_key {
    my $self    = shift;
    my $hashref = shift;
    my $longest = 0;

    foreach my $key (keys(%{$hashref})) {
        $longest = length($key)
            if(length($key) > $longest);
    }

    return $longest;
}

1;
