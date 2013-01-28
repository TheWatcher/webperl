## @file
# This file contains the implementation of the base class for runtime
# block selection.
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
# The base class for runtime block selection classes. This allows web
# applications to modify the process by which the block used to generate
# a page is chosen, based on the requirements of the application. The
# default implementation provided here simply looks for the 'block'
# argument in the query string, and either uses that if it is present
# and valid, or falls back on a default block id otherwise. Other
# applications may wish to extend this behaviour, or replace it entirely
# by subclassing this class and overriding the get_block() method.
package Webperl::BlockSelector;

use strict;
use base qw(Webperl::SystemModule);


# ============================================================================
#  Constructor

## @cmethod BlockSelector new(%args)
# Create a new BlockSelector object. This will create an BlockSelector object that may be
# passed to the Auth class to provide application-specific user handling.
#
# @param args A hash of arguments to initialise the BlockSelector object with.
# @return A new BlockSelector object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self = $class -> SUPER::new(minimal => 1, # minimal tells SystemModule to skip object checks
                                    @_)
        or return undef;

    return bless $self, $class;
}


# ============================================================================
#  Block Selection

## @method $ get_block($dbh, $cgi, $settings, $logger, $session)
# Determine which block to use to generate the requested page. This will inspect
# the query string looking for a `block` argument, and if present it will return
# that. If the `block` argument is not present, it will fall back on a default
# sepecified in `$settings -> {"config"} -> {"default_block"}`
#
# @param dbh      A reference to the database handle to issue queries through.
# @param cgi      A reference to the system CGI object.
# @param settings A reference to the global settings object.
# @param logger   A reference to the system logger object.
# @param session  A reference to the session object.
# @return The id or name of the block to use to render the page, or undef if
#         an error occurred while selecting the block.
sub get_block {
    my $self     = shift;
    my $dbh      = shift;
    my $cgi      = shift;
    my $settings = shift;
    my $logger   = shift;
    my $session  = shift;

    $self -> self_error("");

    # Simple check of the block argument
    my $block = $cgi -> param("block");

    # Fall back on the default if the block is not set or
    $block = $settings -> {"config"} -> {"default_block"}
        unless($block && $block =~ /^[-\w.]+$/);

    $self -> self_error("No block specified, and unable to find a default to fall back on")
        if(!$block);

    return $block;
}


# ============================================================================
#  Error functions

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
