## @file
# This file contains the implementation of the base Block class.
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
# The Block class serves as the base class for all plugin block modules in
# the system. It provides the basic constructor required to initialise a
# plugin properly, stub functions for the two key content generation
# functions that plugins can override to provide meaningful output, and a
# number of general utility functions usefil for all blocks.
#
# Block subclasses may provide two different 'views': an inline block fragment
# that is intended to be embedded within a page generated by another block
# (for example, sidebar menu contents); or the complete contents of a page
# which may be generated solely by the Block subclass, or by the subclass
# loading other Blocks and using their inline block fragments to construct the
# overall page content.
package Webperl::Block;
use strict;
use base qw(Webperl::SystemModule);

use Webperl::HTMLValidator;
use Webperl::Utils qw(is_defined_numeric);
use Encode;
use HTML::Entities;


# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Create a new Block object and store the provided objects in the new object's data. id and
# args are optional, all the remaining arguments must be provided. The arguments should be
# a hash of parameters, valid key names are:
#
# - `modid`    The module id set for the block module's entry in the database.
# - `args`     Any arguments passed to the plugin at runtime, usually pulled from the database.
# - `cgi`      A reference to the script's CGI object.
# - `dbh`      A database handle to talk to the database through.
# - `template` A template engine module object to load templates through.
# - `settings` The global configuration hashref.
# - `session`  A reference to the current session object
# - `module`   The module handler object, used to load other blocks on demand.
# - `logtable` A string containing the name of the table to use for logging. See the log() function.
# - `logger`   A reference to a logger object.
#
# @param args     A hash containing key/value pairs used to set up the module.
# @return A newly created Block object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new("logtable" => "",
                                        "formats"  => {"url"   => '^https?://[-\w]+(?:\.[-\w]+)+(?:/(?:[-.\w]+/)*[-.\w]*(?:\?(?:[-\w~!\$+|.,*:;]|%[a-f\d]{2,4})+=(?:[-\w~!\$+|.,*:]|%[a-f\d]{2,4})*(?:&(?:[-\w~!\$+|.,*:;]|%[a-f\d]{2,4})+=(?:[-\w~!\$+|.,*:]|%[a-f\d]{2,4})*)*)?(?:\#(?:[-\w~!\$+|&.,*:;=]|%[a-f\d]{2,4})*)?)?$',
                                                      },
                                        @_)
        or return undef;

    # Set up the logger, if needed (Application usually does this long before the Block constructor
    # gets called, but even if it has, doing it again won't hurt anything).
    $self -> {"logger"} -> init_database_log($self -> {"dbh"}, $self -> {"logtable"})
        if($self -> {"logtable"});

    return $self;
}


# ===========================================================================
#  Enum field support

## @method $ get_enum_values($table, $column)
# Obtain an array of enum values for a table column. This will attempt to pull
# the valid enumeration values out of a table column description and return a
# reference to an array of values.
#
# @return A reference to an array of enum values, or an error message string.
sub get_enum_values {
    my $self   = shift;
    my $table  = shift;
    my $column = shift;

    my $colh = $self -> {"dbh"} -> prepare("DESCRIBE $table $column");
    $colh -> execute()
        or return $self -> {"template"} -> replace_langvar("BLOCK_ERROR_BADENUM", {"***table***"  => $table,
                                                                                   "***col***"    => $column,
                                                                                   "***errstr***" => $self -> {"dbh"} -> errstr});
    my $unitsdata = $colh -> fetchrow_hashref();

    # Check that this really is an enum column
    return $self -> {"template"} -> replace_langvar("BLOCK_ERROR_NOTENUM", {"***table***" => $table,
                                                                            "***col***"   => $column})
        if($unitsdata -> {"Type"} !~ /^enum/i);

    # pull out the middle bit of the string, dropping the 'enum(' and ')'
    my $units = substr($unitsdata -> {'Type'}, 5, -1);

    # Nuke the 's as they're not needed
    $units =~ s/','/,/g;
    $units =~ s/^'(.*)'$/$1/;

    # Split the string into a usable form
    my @unitlist = split(/,/,$units);

    # Send back a reference to the array
    return \@unitlist;
}


# ===========================================================================
#  Parameter validation support functions

## @method @ validate_string($param, $settings)
# Determine whether the string in the named cgi parameter is set, clean it
# up, and apply various tests specified in the settings. The settings are
# stored in a hash, the recognised contents are as below, and all are optional
# unless noted otherwise:
#
# required   - If true, the string must have been given a value in the form.
# default    - The default string to use if the form field is empty. This is not
#              used if required is set!
# nicename   - The required 'human readable' name of the field to show in errors.
# minlen     - The minimum length of the string.
# maxlen     - The maximum length of the string.
# chartest   - A string containing a regular expression to apply to the string. If this
#              <b>matches the field</b> the validation fails!
# chardesc   - Must be provided if chartest is provided. A description of why matching
#              chartest fails the validation.
# formattest - A string containing a regular expression to apply to the string. If the
#              string <b>does not</b> match the regexp, validation fails.
# formatdesc - Must be provided if formattest is provided. A description of why not
#              matching formattest fails the validation.
# encode     - if set to true, html characters are escaped, otherwise they are passed
#              back 'as is'. Defaults to true. DO NOT set this to false without a
#              very good reason and without taking care to escape anything that might
#              be sent back to the browser.
#
# @param param    The name of the cgi parameter to check.
# @param settings A reference to a hash of settings to control the validation
#                 done to the string.
# @return An array of two values: the first contains the text in the parameter, or
#         as much of it as can be salvaged, while the second contains an error message
#         or undef if the text passes all checks.
sub validate_string {
    my $self     = shift;
    my $param    = shift;
    my $settings = shift;

    # Grab the parameter value, fall back on the default if it hasn't been set.
    my $text = $self -> {"cgi"} -> param($param) // $self -> {"cgi"} -> url_param($param);
    $text = Encode::decode("utf8", $text) if(!Encode::is_utf8($text));

    # Handle the situation where the parameter has not been provided at all
    if(!defined($text) || $text eq '' || (!$text && $settings -> {"nonzero"})) {
        # If the parameter is required, return empty and an error
        if($settings -> {"required"}) {
            return ("", $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_NOTSET", {"***field***" => $settings -> {"nicename"}}));
        # Otherwise fall back on the default.
        } elsif(!$settings -> {"default"}) {
            return ("", undef);
        } else {
            $text = $settings -> {"default"};
        }
    }

    # If there's a test regexp provided, apply it
    my $chartest = $settings -> {"chartest"};
    return ($text, $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_BADCHARS", {"***field***" => $settings -> {"nicename"},
                                                                                        "***desc***"  => $settings -> {"chardesc"}}))
        if($chartest && $text =~ /$chartest/);

    # Is there a format check provided, if so apply it
    my $formattest = $settings -> {"formattest"};
    return ($text, $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_BADFORMAT", {"***field***" => $settings -> {"nicename"},
                                                                                         "***desc***"  => $settings -> {"formatdesc"}}))
        if($formattest && $text !~ /$formattest/);

    # Convert all characters in the string to safe versions
    $text = encode_entities($text)
        unless(defined($settings -> {"encode"}) && !$settings -> {"encode"});

    # Convert horrible smart quote crap from windows
    foreach my $char (keys(%{$self -> {"template"} ->{"entities"}})) {
        $text =~ s/$char/$self->{template}->{entities}->{$char}/g;
    }

    # Now trim spaces
    $text =~ s/^\s+//;
    $text =~ s/\s+$//;

    # Get here and we have /something/ for the parameter. If the maximum length
    # is specified, does the string fit inside it? If not, return as much of the
    # string as is allowed, and an error
    return (substr($text, 0, $settings -> {"maxlen"}), $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_TOOLONG", {"***field***"  => $settings -> {"nicename"},
                                                                                                                               "***maxlen***" => $settings -> {"maxlen"}}))
        if($settings -> {"maxlen"} && (length($text) > $settings -> {"maxlen"}));

    # Is the string too short? If so, store it and return an error.
    return ($text, $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_TOOSHORT", {"***field***"  => $settings -> {"nicename"},
                                                                                        "***minlen***" => $settings -> {"minlen"}}))
        if($settings -> {"required"} && $settings -> {"minlen"} && (length($text) < $settings -> {"minlen"}));

    # Get here and all the tests have been passed or skipped
    return ($text, undef);
}


## @method @ validate_numeric($param, $settings)
# Determine whether the number in the named cgi parameter is set, and if so whether
# it is within the required range. Note that, if specified, min must be less than,
# or equal to, max: get them the wrong way around, and this will reject all numbers!
#
# required   - If true, the value must have been set in the form.
# default    - The default string to use if the form field is empty. If any errors
#              are encountered, this is the value returned. If not provided, this
#              defaults to 0.
# intonly    - If true, only integer values are supported.
# nicename   - The required 'human readable' name of the field to show in errors.
# min        - Optional minimum value allowed for the number (inclusive).
# max        - Optional maximum value allowed for the number (inclusive).
#
# @param param    The name of the cgi parameter to check.
# @param settings A reference to a hash of settings to control the validation
#                 done to the number.
# @return An array of two values: the first contains the number in the parameter, or
#         as much of it as can be salvaged, while the second contains an error message
#         or undef if the number passes all checks.
sub validate_numeric {
    my $self     = shift;
    my $param    = shift;
    my $settings = shift;

    # Force a default in all situations.
    $settings -> {"default"} = 0
        if(!defined($settings -> {"default"}));

    # Grab the parameter value, fall back on the default if it hasn't been set.
    my $value = $self -> {"cgi"} -> param($param) // $self -> {"cgi"} -> url_param($param);
    $value = Encode::decode("utf8", $value) if(!Encode::is_utf8($value));
    if(!defined($value) || $value eq "") {
        if($settings -> {"required"}) {
            return ($settings -> {"default"}, $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_NOTSET", {"***field***" => $settings -> {"nicename"}}));
        } else {
            return ($settings -> {"default"}, undef);
        }
    }

    # Is this really a number?
    my $pattern = '-?\d+'.($settings -> {"intonly"} ? '' : '(\.\d+)?');
    return ($settings -> {"default"}, $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_NOTNUMBER", {"***field***" => $settings -> {"nicename"}}))
        unless($value =~ /^$pattern$/);

    # Check minimum and maximum if needed
    return ($settings -> {"min"}, $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_RANGEMIN", {"***field***" => $settings -> {"nicename"},
                                                                                                           "***min***"   => $settings -> {"min"}}))
        if(defined($settings -> {"min"}) && $value < $settings -> {"min"});

    return ($settings -> {"max"}, $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_RANGEMAX", {"***field***" => $settings -> {"nicename"},
                                                                                                           "***max***"   => $settings -> {"max"}}))
        if(defined($settings -> {"max"}) && $value > $settings -> {"max"});

    # Value should be good to go now
    return ($value, undef);
}


## @method @ validate_options($param, $settings)
# Determine whether the value provided for the specified parameter is valid. This will
# either look for the value specified in an array, or in a database table, depending
# on the value provided for source in the settings hash. Valid contents for settings are:
#
# required  - If true, the option can not be "".
# default   - A default value to return if the option is '' or not present, and not required.
# source    - The source of the options. If this is a reference to an array, the
#             value specified for the parameter is checked agains the array. If this
#             if a string, the option is checked against the table named in the string.
# where     - The 'WHERE' clause to add to database queries. Required when source is a
#             string, otherwise it is ignored.
# nicename  - Required, human-readable version of the parameter name.
#
# @param param    The name of the cgi parameter to check.
# @param settings A reference to a hash of settings to control the validation
#                 done to the parameter.
# @return An array of two values: the first contains the value in the parameter, or
#         as much of it as can be salvaged, while the second contains an error message
#         or undef if the parameter passes all checks.
sub validate_options {
    my $self     = shift;
    my $param    = shift;
    my $settings = shift;

    my $value = $self -> {"cgi"} -> param($param) // $self -> {"cgi"} -> url_param($param);
    $value = Encode::decode("utf8", $value) if(!Encode::is_utf8($value));

    # Bomb if the value is not set and it is required.
    return ($settings -> {"default"}, $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_NOTSET", {"***field***" => $settings -> {"nicename"}}))
        if($settings -> {"required"} && (!defined($value) || $value eq ''));

    # If the value not specified and not required, we can just return immediately
    return ($settings -> {"default"}, undef) if(!defined($value) || $value eq "");

    # Determine how we will check it. If the source is an array reference, we do an array check
    if(ref($settings -> {"source"}) eq "ARRAY") {
        # Fix to lowercase if case sensitivity is off
        $value = lc($value) if($settings -> {"nocase"});

        foreach my $check (@{$settings -> {"source"}}) {
            my $val = $check;
            $val = $check -> {"value"} if(ref($check) eq "HASH");

            # Fix to lowercase if case sensitivity is off
            $val = lc($val) if($settings -> {"nocase"});

            return ($value, undef) if($val eq $value);
        }

    # If the source is not a reference, we assue it is the table name to check
    } elsif(not ref($settings -> {"source"})) {
        my $checkh = $self -> {"dbh"} -> prepare("SELECT *
                                                  FROM `".$settings -> {"source"}."`
                                                       ".$settings -> {"where"});
        # Check for the value in the table...
        $checkh -> execute($value)
            or return ($settings -> {"default"}, $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_DBERR", {"***field***" => $settings -> {"nicename"},
                                                                                                                   "***dberr***" => $self -> {"dbh"} -> errstr}));
        my $checkr = $checkh -> fetchrow_arrayref();

        # If we have a match, the value is valid
        return ($value, undef) if($checkr);
    }

    # Get here and validation has failed. We can't rely on the value at all, so return
    # the default, and an error
    return ($settings -> {"default"}, $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_BADOPT", {"***field***" => $settings -> {"nicename"}}));
}


## @method @ validate_htmlarea($param, $settings)
# Attempt to validate the contents of a html area. This is an excessively complicated
# job and is, ultimately, never going to be 100% secure - the code needs to be put through
# filters and validation by a html validator before we can be be even remotely sure it
# is vaguely safe. Even then, there is a small possibility that a malicious user can
# carefully craft something to bypass the checks.
#
# @param param    The name of the textarea to check.
# @param settings A reference to a hasn containing settings to control the validation.
sub validate_htmlarea {
    my $self     = shift;
    my $param    = shift;
    my $settings = shift;

    # first we need the textarea contents...
    my $text = $self -> {"cgi"} -> param($param) // $self -> {"cgi"} -> url_param($param);
    $text = Encode::decode("utf8", $text) if(!Encode::is_utf8($text));

    # Convert anything that might cause problems to html entities.
    encode_entities($text, '^\n\x20-\x7e');

    # Get a copy of the input with no tags at all so that it can be checked for length
    my $scrubber = HTML::Scrubber -> new();
    my $nohtml = $scrubber -> scrub($text);

    $nohtml =~ s/(\s|&nbsp;)//g; # Kill some kinds of whitespace that may be left by scrubber that will confuse length checks.

    # If the text area is empty, deal with the whole default/required malarky
    if(!defined($nohtml) || !$nohtml) {
        # If the parameter is required, return empty and an error
        if($settings -> {"required"}) {
            return ("", $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_NOTSET", {"***field***" => $settings -> {"nicename"}}));
        # Otherwise fall back on the default.
        } else {
            $text = $settings -> {"default"} || "";
        }
    }
    # Don't bother doing anything if the text is empty at this point
    return ("", undef) if(!$text || length($text) == 0);

    # Is the string too short? If so, store it and return an error.
    return ($text, $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_TOOSHORT", {"***field***"  => $settings -> {"nicename"},
                                                                                        "***minlen***" => $settings -> {"minlen"}}))
        if($settings -> {"required"} && $settings -> {"minlen"} && (length($nohtml) < $settings -> {"minlen"}));

    # Now we get to the actual validation and stuff. Begin by scrubbing any tags
    # and other crap we don't want out completely. As far as I can tell, this should
    # always generate a result of some kind...
    $text = scrub_html($text, $settings -> {"allow_tags"}, $settings -> {"tag_rules"}, $settings -> {"scrub_defaults"});

    # ... but check, just in case
    return ("",  $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_SCRUBFAIL", {"***field***" => $settings -> {"nicename"}}))
        if(!defined($text));

    # Explicitly nuke any CDATA sections that might have got through, as they have
    # no bloody business being there at all
    $text =~ s{<![CDATA[.*?]]>}{}gio;

    # Load the text into the testing hardness now, so it appears like a valid chunk of html
    # to tidy and the validator...
    my $xhtml = $self -> {"template"} -> load_template("validator_harness.tem", {"***body***" => $text});

    # Throw the xhtml through tidy to make sure it is actually xhtml
    # This will result in undef if tidy failed catastrophically...
    my $tidied = tidy_html($xhtml);
    return ("", , $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_TIDYFAIL", {"***field***" => $settings -> {"nicename"}}))
        if(!$tidied);

    # Tidy will stick in spurious list elements, remove them
    $tidied =~ s|<li style="list-style: none"></li>\n||g;

    # Now we can go ahead and check with the validator to see whether the tidied
    # code is valid xhtml
    my $valid = check_xhtml($tidied);

    # Strip out the harness
    $tidied =~ s{^.*<body>\s*(.*)\s*</body>\s*</html>\s*$}{$1}is;

    # Zero indicates that there were no errors - the html is valid
    if($valid == 0) {
        return ($tidied, undef);

    # If the return from check_xhtml is one or more digits, it is an error count
    } elsif($valid =~ /^\d+:/) {
        $valid =~ s/^\d+://;
        return ($tidied, $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_CHKERRS", {"***field***" => $settings -> {"nicename"},
                                                                                             "***error***" => $valid}));

    # Otherwise it should be a failure message
    } else {
        return ($tidied, $self -> {"template"} -> replace_langvar("BLOCK_VALIDATE_CHKFAIL", {"***field***" => $settings -> {"nicename"},
                                                                                             "***error***" => $valid}));
    }
}


# ============================================================================
#  Logging functions

## @method void log($type, $data)
# Create an entry in the database log table with the specified type and data.
# This will add an entry to the log table in the database, storing the time,
# user, and type and data supplied.
#
# @param type The log event type, may be any string up to 64 characters long.
# @param data The event data, may be any string up to 255 characters.
sub log {
    my $self = shift;
    my $type = shift;
    my $data = shift;

    # Work out the user
    my $userid = $self -> {"session"} -> {"sessuser"};
    $userid = undef unless($userid); # force undef, even if userid is 0.

    $self -> {"logger"} -> log($type, $userid, $self -> {"cgi"} -> remote_addr(), $data);
}


# ============================================================================
#  Display functions

## @method $ build_password_policy($template)
# Build a string describing the password policy for the current user. This
# interrogates the user's AuthMethod to determine the password policy in place
# for the user (if any), and generates a string describing it in a format
# suitable to present to users.
#
# @param template The name of the template to use for each policy fragment.
# @return A string containing the password policy enforced for the logged-in
#         user. If there is no policy in place, or the user is not logged in,
#         this returns an empty string.
sub build_password_policy {
    my $self     = shift;
    my $template = shift;

    # Anonymous user can have no policy
    return '' if($self -> {"session"} -> anonymous_session());

    my $user = $self -> {"session"} -> get_user_byid()
        or return '';

    # Fetch the policy, and give up if there isn't one.
    my $policy = $self -> {"session"} -> {"auth"} -> get_policy($user -> {"username"})
        or return '';

    my $policystr = "";
    foreach my $name (@{$policy -> {"policy_order"}}) {
        next if(!$policy -> {$name});
        $policystr .= $self -> {"template"} -> load_template($template, {"***policy***" => "{L_LOGIN_".uc($name)."}",
                                                                         "***value***"  => $policy -> {$name}});
    }

    return $policystr;
}


## @method @ build_error_box($message)
# Generate the contents of a system error message to send back to the user.
# This wraps the template message_box() function as a means to make error
# messages easier to show.
#
# @param message The message explaining the problem that triggered the error.
# @return An array of two values. The first is the page title, the second is
#         the text of the error box.
sub build_error_box {
    my $self    = shift;
    my $message = shift;

    my $title    = $self -> {"template"} -> replace_langvar("BLOCK_ERROR_TITLE");
       $message  = $self -> {"template"} -> message_box($self -> {"template"} -> replace_langvar("BLOCK_ERROR_TITLE"),
                                                        'info',
                                                        $self -> {"template"} -> replace_langvar("BLOCK_ERROR_SUMMARY"),
                                                        $self -> {"template"} -> replace_langvar("BLOCK_ERROR_TEXT", {"***error***" => $message}));
    return ($title, $message);
}


## @method $ block_display()
# Produce the string containing this block's 'block fragment' if it has one. By default,
# this will return a string containing an error message. If block fragment content is
# needed, this must be overridden in the subclass.
#
# @return The string containing this block's content fragment.
sub block_display {
    my $self = shift;

    return "<p class=\"error\">".$self -> {"template"} -> replace_langvar("BLOCK_BLOCK_DISPLAY")."</p>";
}


## @method $ page_display()
# Produce the string containing this block's full page content, if it provides one.
# By default, this will return a string containing an error message, override it to
# generate pages in subclasses.
#
# @return The string containing this block's page content.
sub page_display {
    my $self = shift;

    return "<p class=\"error\">".$self -> {"template"} -> replace_langvar("BLOCK_PAGE_DISPLAY")."</p>";
}

1;