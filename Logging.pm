## @file
# System-wide logging functions. The functions in this file provide logging and
# printing facilities for the whole system.
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
# System-wide logging functions. The functions in this file provide logging and
# printing facilities for the whole system.
#
package Logging;
require Exporter;
use strict;

our @ISA       = qw(Exporter);
our @EXPORT    = qw(warn_log die_log);
our @EXPORT_OK = qw(start_log end_log);

my $logfile; # If defined, this is handle to the file that entries a written to
my $logtime; # The time that the log file was opened


## @fn void warn_log($ip, $message)
# Write a warning message to STDERR and to a log file if it is opened. Warnings
# are prepended with the process ID and an optional IP address, and entries
# written to the log file are timestamped.
#
# @param ip      The IP address to log with the message. Defaults to 'unknown'
# @param message The message to write to the log
sub warn_log {
    my $ip      = shift || "unknown";
    my $message = shift;

    print $logfile scalar(localtime)," [$$:$ip]: $message\n"
        if($logfile);

    warn "[$$:$ip]: $message\n";
}


## @fn void die_log($ip, $message)
# Write an error message a log file if it is opened, and then die. Errors
# are prepended with the process ID and an optional IP address, and entries
# written to the log file are timestamped.
#
# @param ip      The IP address to log with the message. Defaults to 'unknown'
# @param message The message to write to the log
sub die_log {
    my $ip      = shift || "unknown";
    my $message = shift;

    print $logfile scalar(localtime)," [$$:$ip]: $message\n"
        if($logfile);

    die "[$$:$ip]: $message\n";
}


## @fn void start_log($filename, $progname)
# Start logging warnings and errors to a file. If logging is already enabled,
# this will close the currently open log before opening the new one. The log
# file is appended to rather than truncated.
#
# @param filename The name of the file to log to.
# @param progname A optional program name to show in the log. Defaults to $0
sub start_log {
    my $filename = shift;
    my $progname = shift || $0;

    # Close the logfile if it has been opened already
    end_log($progname) if($logfile);

    # Open in append mode
    open($logfile, ">> $filename")
        or die "Unable to open log file $filename: $!";

    my $tm = scalar localtime;
    print $logfile "\n----------= Starting $progname [pid: $$] at $tm =----------\n";
    $logtime = time();
}


## @fn void end_log($progname)
# Stop logging warnings and errors to a file. This will write an indicator
# that logging is stopping to the file and then close it.
#
# @param progname A optional program name to show in the log. Defaults to $0
sub end_log {
    my $progname = shift || $0;

    if($logfile) {
        my $tm = scalar localtime;
        my $elapsed = time() - $logtime;

        print $logfile "----------= Completed $progname [pid: $$] at $tm, execution time $elapsed seconds =----------\n";
        close($logfile);
    }
}

1;
