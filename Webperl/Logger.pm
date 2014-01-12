## @file
# This file contains the implementation of a simple logging system like that
# provided in Logging, except that this supports verbosity control.
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
# A class to handle logging operations throughout a system. This collects
# together the various functions needed for displaying log messages and errors
# at various levels of verbosity, in an attempt to cut down on duplicate
# parameter passing throughout the rest of the system.
package Webperl::Logger;

use strict;
use Sys::Syslog qw(:standard :macros);
require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT    = qw(warn_log die_log);
our @EXPORT_OK = qw(start_log end_log);

use constant WARNING       => 0;
use constant NOTICE        => 1;
use constant DEBUG         => 2;
use constant MAX_VERBOSITY => 2;

# This will store a singleton instance of the logger to use if functions
# are called through the functional interface.
our $log_singleton;
BEGIN {
    undef $log_singleton;
}

# ============================================================================
#  Constructor
#

## @cmethod $ new(%args)
# Create a new Logging object for use around the system. This creates an object
# that provides functions for printing or storing log information during script
# execution. Meaningful options for this are:
#
# verbosity   - One of the verbosity level constants, any messages over this will
#               not be printed. If this is not specified, it defaults to DEBUG
#               (the highest supported verbosity)
# fatalblargh - If set to true, any calls to the blargh function kill the
#               script immediately, otherwise blarghs produce warning messages.
#               Defaults to false.
# logname     - If set, messages sent to warn_log and die_log will be appended
#               to the specified log file. See start_log below for more details.
# syslog      - If set to true, messages are copied into syslog.
#
# @param args A hash of key, value pairs with which to initialise the object.
# @return A new Logging object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;

    my $self = {
        "verbosity"   => DEBUG,
        "fatalblargh" => 0,
        "outlevels"   => [ "WARNING", "NOTICE", "DEBUG" ],
        "syslog"      => 0,
        @_,
    };

    my $obj = bless $self, $class;

    $obj -> start_log($self -> {"logname"}) if($self -> {"logname"});

    # Set up syslog if needed. If open fails, disable syslog again
    if($obj -> {"syslog"}) {
        eval { openlog($$, "ndelay,pid", LOG_DAEMON); };
        if($@) {
            $obj -> {"syslog"} = 0;
            $obj -> warn_log(undef, "Unable to conenct to syslog: $@");
        } else {
            syslog(LOG_INFO, "Syslog started");
        }
    }

    # Store as the singleton, just in case
    $log_singleton = $obj;

    return $obj;
}


## @method void set_verbosity($newlevel)
# Set the verbosity level of this logging object to the specified level. If the
# newlevel argument is not specified, or it is out of range, the object is set
# to the maximum supported verbosity.
#
# @param newlevel The new verbosity level for this logger.
sub set_verbosity {
    my ($self, $newlevel) = self_or_default(@_);

    $newlevel = MAX_VERBOSITY if(!defined($newlevel) || $newlevel < 0 || $newlevel > MAX_VERBOSITY);

    $self -> {"verbosity"} = $newlevel;
}


## @method void start_log($filename, $progname)
# Start logging warnings and errors to a file. If logging is already enabled,
# this will close the currently open log before opening the new one. The log
# file is appended to rather than truncated.
#
# @warning THIS SHOULD NOT BE CALLED IN PRODUCTION! This function should be used
#          for testing only, otherwise you may run into <i>all kinds of fun</i>
#          with attempts to concurrently append to the log file. If you decide
#          to ignore this, don't complain to me when things blow up in your face.
#
# @param filename The name of the file to log to.
# @param progname A optional program name to show in the log. Defaults to $0
sub start_log {
    my ($self, $filename, $progname) = self_or_default(@_);

    $progname = $0 unless(defined($progname));

    # Close the logfile if it has been opened already
    $self -> end_log($progname) if($self -> {"logfile"});

    my $logfile;

    # Open in append mode
    open($logfile, ">> $filename")
        or die "Unable to open log file $filename: $!";

    my $tm = scalar localtime;
    print $logfile "\n----------= Starting $progname [pid: $$] at $tm =----------\n";
    $self -> {"logfile"} = $logfile;
    $self -> {"logtime"} = time();
}


## @method void end_log($progname)
# Stop logging warnings and errors to a file. This will write an indicator
# that logging is stopping to the file and then close it.
#
# @param progname A optional program name to show in the log. Defaults to $0
sub end_log {
    my ($self, $progname) = self_or_default(@_);

    $progname = $0 unless(defined($progname));

    if($self -> {"logfile"}) {
        my $logfile = $self -> {"logfile"};

        my $tm = scalar localtime;
        my $elapsed = time() - $self -> {"logtime"};

        print $logfile "----------= Completed $progname [pid: $$] at $tm, execution time $elapsed seconds =----------\n";
        close($logfile);

        # Make sure this is undefed so that we don't try to repeat close it.
        $self -> {"logfile"} = undef;
    }
}


# ============================================================================
#  Database logging
#

## @method void init_database_log($dbh, $tablename)
# Initialise database logging. This allows the log() function to be called and
# have some effect.
#
# @param dbh       The database handle to issue logging queries through.
# @param tablename The name of the table to log events into
sub init_database_log {
    my $self = shift;

    $self -> {"dbh"} = shift;
    $self -> {"logtable"} = shift;
}


## @method void log($type, $user, $ip, $data)
# Create an entry in the database log table with the specified type and data.
# This will add an entry to the log table in the database, storing the time,
# user, and type and data supplied. It expects a table of the following structure
# @verbatim
# CREATE TABLE `log` (
# `id` INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY ,
# `logtime` INT UNSIGNED NOT NULL COMMENT 'The time the logged event happened at',
# `user_id` INT UNSIGNED NULL DEFAULT NULL COMMENT 'The id of the user who triggered the event, if any',
# `ipaddr` VARCHAR(16) NULL DEFAULT NULL COMMENT 'The IP address the event was triggered from',
# `logtype` VARCHAR( 64 ) NOT NULL COMMENT 'The event type',
# `logdata` VARCHAR( 255 ) NULL DEFAULT NULL COMMENT 'Any data that might be appropriate to log for this event'
# )
# @endverbatim
#
# @param type The log event type, may be any string up to 64 characters long.
# @param user The ID of the user to log as the event triggerer, use 0 for unknown/internal.
# @param ip   The IP address of the user, defaults to "unknown" if not supplied.
# @param data The event data, may be any string up to 255 characters.
sub log {
    my $self = shift;
    my $type = shift;
    my $user = shift;
    my $ip   = shift || "unknown";
    my $data = shift;

    # Do nothing if there is no log table set.
    return if(!$self -> {"logtable"});

    my $eventh = $self -> {"dbh"} -> prepare("INSERT INTO ".$self -> {"logtable"}."
                                              (logtime, user_id, ipaddr, logtype, logdata)
                                              VALUES(UNIX_TIMESTAMP(), ?, ?, ?, ?)");
    $eventh -> execute($user, $ip, $type, $data)
        or $self -> die_log($ip, "FATAL: Unable to insert log entry for $user ('$type', '$data')");
}


# ============================================================================
#  log printing
#

## @method $ fatal_setting($newstate)
# Get (and optionally set) the value that determines whether calls to blargh
# are fatal. If newstate is provided, the current state of blargh severity is
# set to the new state.
#
# @param newstate If specified, change the value that determines whether calls
#                 to blargh are fatal: if set to true, calls to blargh will exit
#                 the script immediately with an error, if set to 0 calls to
#                 blargh will generate warning messages.
# @return The current state of blargh fatality.
sub fatal_setting {
    my ($self, $newstate) = self_or_default(@_);

    $self -> {"fatalblargh"} = $newstate if(defined($newstate));

    return $self -> {"fatalblargh"};
}


## @method void print($level, $message, $newline)
# If the specified level is less than, or equal to, the current verbosity level,
# print the specified message to stdout. If the level is over the verbosity
# level the message is discarded.
#
# @param level   The level of the message, should be one of WARNING, NOTICE, or DEBUG.
# @param message The message to print.
# @param newline Print a newline after the message. If set to falce, this will suppress
#                the automatic addition of a newline after the message (although the
#                message may still contain its own newlines). If set to true, or omitted,
#                a newline is printed after the message.
sub print {
    my ($self, $level, $message, $newline) = self_or_default(@_);

    $newline = 1 if(!defined($newline));
    my $logfile = $self -> {"logfile"};

    if($level <= $self -> {"verbosity"}) {
        print $self -> {"outlevels"} -> [$level],": $message",($newline ? "\n" : "");
        print $logfile $self -> {"outlevels"} -> [$level],": $message",($newline ? "\n" : "") if($logfile);

        syslog(lc($self {"outlevels"} -> [$level]), $message)
            if(!$self -> {"syslog"});

        # flush stdout if needed to avoid log update delays
        select((select(STDOUT), $| = 1)[0]) if($newline);
    }
}


## @method void blargh($message)
# Generate a message indicating that a serious problem has occurred. If the logging
# object is set up such that blargh()s are fatal, this function will die with the
# specified message, otherwise the message will be printed as a warning.
#
# @param message The message to print.
sub blargh {
    my ($self, $message) = self_or_default(@_);

    if($self -> {"fatalblargh"}) {
        die "FATAL: $message\n";
    } else {
        $self -> print(WARNING, $message);
    }
}


## @method void warn_log($ip, $message)
# Write a warning message to STDERR and to a log file if it is opened. Warnings
# are prepended with the process ID and an optional IP address, and entries
# written to the log file are timestamped.
#
# @note This method completely ignores all verbosity controls (unlike print()),
#       it is not intended for use in situations where the user has control over
#       verbosity levels.
#
# @param ip      The IP address to log with the message. Defaults to 'unknown'
# @param message The message to write to the log
sub warn_log {
    my ($self, $ip, $message) = self_or_default(@_);
    $ip = "unknown" unless(defined($ip));

    my $logfile = $self -> {"logfile"};

    print $logfile scalar(localtime)," [$$:$ip]: $message\n"
        if($logfile);

    syslog(LOG_WARNING, $message)
        if(!$self -> {"syslog"});

    $self -> log("warning", 0, $ip, $message);

    warn "[$$:$ip]: $message\n";
}


## @method void die_log($ip, $message)
# Write an error message a log file if it is opened, and then die. Errors
# are prepended with the process ID and an optional IP address, and entries
# written to the log file are timestamped.
#
# @note This method completely ignores all verbosity controls (unlike print()),
#       it is not intended for use in situations where the user has control over
#       verbosity levels.
#
# @param ip      The IP address to log with the message. Defaults to 'unknown'
# @param message The message to write to the log
sub die_log {
    my ($self, $ip, $message) = self_or_default(@_);
    $ip = "unknown" unless(defined($ip));

    my $logfile = $self -> {"logfile"};

    print $logfile scalar(localtime)," [$$:$ip]: $message\n"
        if($logfile);

    syslog(LOG_ERR, $message)
        if(!$self -> {"syslog"});

    $self -> log("fatal", 0, $ip, $message);

    die "[$$:$ip]: $message\n";
}


# ============================================================================
#  Scary internals
#

## @fn private @ self_or_default()
# Support function to allow Logger functions to be called using functional or
# OO methods. This will act as a pass-through if called by a function that has
# itself been called using OO, otherwise it will modify the argument list to
# insert a singleton instance of the Logger. This code is based on a function
# of the same name in CGI.pm
#
# @return Either the argument list, or a reference to a singleton Logger if
#         the caller expects a reference rather than a list.
sub self_or_default {
    # Called as 'Logger' -> something.
    return @_ if(defined($_[0]) && (!ref($_[0])) && ($_[0] eq 'Webperl::Logger'));

    # If not called as a Logger object, shove the singleton into the argument list
    unless(defined($_[0]) && (ref($_[0]) eq 'Webperl::Logger' || UNIVERSAL::isa($_[0], 'Webperl::Logger'))) {
        # Make a new singleton if one hasn't been made already
        $log_singleton = Webperl::Logger -> new() unless(defined($log_singleton));

        unshift(@_, $log_singleton);
    }

    return wantarray ? @_ : $log_singleton;
}

1;
