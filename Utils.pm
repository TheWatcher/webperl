## @file
# System-wide utility functions. The functions in this file may be useful at
# any point throughout the system, so they are collected here to prevent the
# need for multiple copies around various modules.
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

## @mainpage
#
# @section Introduction
#
# The perl modules described here are the support modules used widely
# throughout my web applications. They are generally used in a very specific
# framework, but they provide features that may be useful in a standalone
# environment.
#
# @todo The documentation for the modules is still a work in progress: some
#       areas need to be fleshed out substantially, and the addition of
#       examples or test cases would be very helpful.

## @class
# System-wide utility functions. The functions in this file may be useful at
# any point throughout the system, so they are collected here to prevent the
# need for multiple copies around various modules.
package Utils;
require Exporter;
use POSIX qw(strftime);
use strict;

our @ISA       = qw(Exporter);
our @EXPORT    = qw();
our @EXPORT_OK = qw(path_join superchomp trimspace is_defined_numeric rfc822_date title_case sentence_case get_proc_size blind_untaint);


## @fn $ path_join(@fragments)
# Take an array of path fragments and concatenate them together. This will
# concatenate the list of path fragments provided using '/' as the path
# delimiter (this is not as platform specific as might be imagined: windows
# will accept / delimited paths). The resuling string is trimmed so that it
# <b>does not</b> end in /, but nothing is done to ensure that the string
# returned actually contains a valid path.
#
# @param fragments The path fragments to join together.
# @return A string containing the path fragments joined with forward slashes.
sub path_join {
    my @fragments = @_;

    my $result = "";

    # We can't easily use join here, as fragments might end in /, which
    # would result in some '//' in the string. This may be slower, but
    # it will ensure there aren't stray slashes around.
    foreach my $fragment (@fragments) {
        $result .= $fragment;
        # append a slash if the result doesn't end with one
        $result .= "/" if($result !~ /\/$/);
    }

    # strip the trailing / if there is one
    return substr($result, 0, length($result) - 1) if($result =~ /\/$/);
    return $result;
}


## @fn void superchomp($line)
# Remove any white space or newlines from the end of the specified line. This
# performs a similar task to chomp(), except that it will remove <i>any</i> OS
# newline from the line (unix, dos, or mac newlines) regardless of the OS it
# is running on. It does not remove unicode newlines (U0085, U2028, U2029 etc)
# because they are made of spiders.
#
# @param line A reference to the line to remove any newline from.
sub superchomp(\$) {
    my $line = shift;

    $$line =~ s/(?:[\s\x{0d}\x{0a}\x{0c}]+)$//o;
}


## @fn $ trimspace($data)
# Remove whitespace from the start and end of the specified string, and
# return the stripped string.
#
# @param data The string to remove leading and trailing whitespace from.
# @return The stripped string.
sub trimspace {
    my $data = shift;

    $data =~ s/^[\s\x{0d}\x{0a}\x{0c}]+//o;
    $data =~ s/[\s\x{0d}\x{0a}\x{0c}]+$//o;

    return $data;
}


## @fn $ is_defined_numeric($cgi, $param)
# Determine whether the specified cgi parameter is purely numeric and return it
# if it is. If the named parameter is not entirely numeric, this returns undef.
#
# @param cgi   The cgi handle to check the parameter through.
# @param param The name of the cgi parameter to check.
# @return The numeric value in the parameter, or undef if it is not purely numeric.
sub is_defined_numeric {
    my ($cgi, $param) = @_;

    if(defined($cgi -> param($param)) && $cgi -> param($param) !~ /\D/) {
        return $cgi -> param($param);
    }

    return undef;
}


## @fn $ rfc822_date($timestamp)
# Convert a unix timestamp into a rfc822-formatted date string. This is guaranteed
# to generate a RFC822 date string (unlike strftime, which could generate week and
# month names in another language in other locales)
#
# @param timestamp The unix timestamp to convert to rfc822 format
# @return The rfc822 time string
sub rfc822_date {
    my $timestamp = shift;

    # set up constants we'll need
    my @days = ("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat");
    my @mons = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec");

    my @ts = localtime($timestamp);

    return sprintf("%s, %02d %s %4d %02d:%02d:%02d %s",
                   $days[$ts[6]], $ts[3], $mons[$ts[4]], $ts[5] + 1900,
                   $ts[2], $ts[1], $ts[0],
                   strftime("%Z", @ts));
}


## @fn void title_case($strref, $punc_border)
# Convert the words in the provided string to titlecase. This will process all the
# words in the string referred to by the argument into titlecase, to avoid situations
# where allcaps/alllower input has been provided for a string that does not look
# good that way.
#
# @param strref      A reference to the string to convert.
# @param punc_border If true, punctuation is treated as boundary character, otherwise
#                    only the start or end of the string or space is treated as a
#                    word boundary.
sub title_case(\$$) {
    my $strref = shift;
    my $punc_border = shift;

    if($punc_border) {
        $$strref =~ s/\b(.*?)\b/ucfirst(lc($1))/ge;
    } else {
        $$strref =~ s/(^|\s)((?:\S|\z)+)/$1.ucfirst(lc($2))/gem;
    }

    # Fix up entities
    $$strref =~ s/(&[a-z]+;)/lc($1)/ge;
}

## @fn void sentence_case($strref)
# Convert the words in the provided string to sentence case. This will process all the
# words in the string referred to by the argument to convert the string to sentence case,
# to avoid situations where allcaps/alllower input has been provided for a string that
# does not look good that way.
#
# @param strref A reference to the string to convert.
sub sentence_case(\$) {
    my $strref = shift;

    $$strref = ucfirst(lc($$strref));

}


## @fn $ get_proc_size()
# Determine how much memory the current process is using. This examines the process'
# entry in proc, it's not portable, but frankly I don't care less about that.
#
# @return The process virtual size, in bytes, or -1 if it can not be determined.
sub get_proc_size {

    # We don't need no steenking newlines
    my $nl = $/;
    undef $/;

    # Try to open and read the process' stat file
    open(STAT, "/proc/$$/stat")
        or die "Unable to read stat file for current process ($$)\n";
    my $stat = <STAT>;
    close(STAT);

    # Now we need to pull out the vsize field
    my ($vsize) = $stat =~ /^[-\d]+ \(.*?\) \w+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ [-\d]+ ([-\d]+)/;

    return $vsize || -1;
}


## @fn $ blind_untaint($str)
# Untaint the specified string blindly. This should generally only be used in
# situations where the string is guaranteed to be safe, it just needs to be
# untainted.
#
# @param str The string to untaint
# @return The untainted string
sub blind_untaint {
    my $str = shift;

    my ($untainted) = $str =~ /^(.*)$/;
    return $untainted;
}

1;
