## @file
# This file contains the implementation of the template engine.
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
# A simple Template class with internationalisation support. Note that
# this class does not cache templates or any fancy stuff like that - it
# just provides a simple interface to generate content based on
# replacing markers in files. For security, executable content in
# templates is not permitted - this admittedly makes some forms of
# templating more difficult, but not insurmountably. If you really
# need executable code in templates, you can add it by making
# process_template() look for code markers (say `{E_[ ... code ...]}`)
# in templates, and eval()ing the contents of the block (although note
# that, quite aside from having security implications, this will also
# be pretty slow).
#
# Replacement markers
# -------------------
# When setting up template files, you are free to use whatever value
# replacement markers you see fit: to date, the author has used `***name***`
# (replacing `name` with the name of the marker), but any sequence
# of characters unlikely to appear in normal text will work just as
# well (for example, `{V_name}` would be fine, too). When calling
# load_template() or process_template(), you simply pass it a hash
# of replacement markers and values. eg:
#
#     load_template("templatename.tem", { "***foo***" => $value,
#                                         "{V_bar}"   => "wibble" });
#
# This will load `templatename.tem` from the current theme directory
# (which will default to `templates/default` - see new() for more
# information), replace any occurrences of `***foo***` with the
# contents of the $value variable, replace any occurrences of `{V_bar}`
# with the string `wibble`, and then return a string containing the
# 'filled-in' template.
#
# Note that, when loading a template, you do not need to provide a
# hash that contains replacements for all markers in the template. You
# can call load_template() with replacements for zero or more markers,
# and then later call process_template() to replace any remaining
# markers. This is useful for pre-loading templates before entering
# loops that may need to use the same template repeatedly.
#
# (Also, as you may have gathered, you do not even need to use a
# single marker style in your templates - you're free to set up the
# replacements as you see fit).
#
# I18N and language replacement
# -----------------------------
# The template engine also supports language variables and automatic
# replacement of language markers in template files. These are more
# rigidly defined: in template files, language markers take the form
# `{L_varname}` where `{L_` marks the start of the language variable
# substitution marker, `varname` defines the name of the language
# variable to use, and `}` closes the marker.
#
# Language variables are defined in lang files, any number of which
# may be stored in the `langdir`/`lang`/ directory defined when
# creating a new Template object. Each lang file can contain any
# number of language variable definitions, and definitions are made
# using the syntax:
#
#     VARIABLE_NAME = contents of the variable here
#
# Language variable names are usually uppercase, but this is a stylistic
# issue, and case is not enforced (although it is important to note
# that the system is case sensitive! Variable_Name and VARIABLE_NAME are
# NOT the same!) The contents of each language variable may contain
# HTML formatting, but you are strongly discouraged from using this
# facility for anything beyond basic character formatting - if you need
# to do anything involving layout, it should be being done in the
# templates.
#
# Block name replacement
# ----------------------
# The template engine will recognise and replace `{B_[blockname]}` markers
# with the appropriate block name or id. The `blockname` specified in
# the marker corresponds to the value in the `name` field in the `blocks`
# table. Usually your templates will include content like
#
#     ... href="index.cgi?block={B_[somename]}...etc...
#
# System variable replacement
# ---------------------------
# Sometimes templates need to include values set in the configuration. This
# can be done using the `{V_[varname]}` syntax, where `varname` is the name
# of the configuration variable to show. Note that, as this would be a
# serious security risk if any configuration variable could be used, the
# system only converts specific variable markers. At present, the following
# are supported:
#
# - `{V_[scriptpath]}` is replaced by the value of the scriptpath variable in
#    the configuration. This will always have a trailing '/', even when the
#    scriptpath is empty (so, an empty scriptpath will result in this marker
#    being replaced by "/".
# - `{V_[templatepath]}` is replaced by the path from the base of the web
#    application to the template directory (useful for image and other resource
#    paths inside the template). This will always have a trailing '/'.
# - `{V_[templateurl]}` like templatepath, but including the full URL.
# - `{V_[commonpath]}` is replaced by the path from the base of the web
#    application to the common template directory (useful for image and other resource
#    paths inside the common template). This will always have a trailing '/'.
# - `{V_[sitename]}` is replaced by the name of the site in the 'site_name'
#    configuration value.
# - `{V_[admin_email]}` is replaced by the site admin email address.
package Webperl::Template;

use experimental qw(smartmatch);
use POSIX qw(strftime);
use Webperl::Utils qw(path_join superchomp);
use Carp qw(longmess carp);
use HTML::WikiConverter;
use HTML::Entities;
use v5.12;

use strict;

our ($errstr, $utfentities, $entities, $entitymap, @timescales);

BEGIN {
	$errstr = '';

    $utfentities = { '\xC2\xA3'     => '&pound;',
                     '\xE2\x80\x98' => '&lsquo;',
                     '\xE2\x80\x99' => '&rsquo;',
                     '\xE2\x80\x9C' => '&ldquo;',
                     '\xE2\x80\x9D' => '&rdquo;',
                     '\xE2\x80\x93' => '&ndash;',
                     '\xE2\x80\x94' => '&mdash;',
                     '\xE2\x80\xA6' => '&hellip;',
    };

    $entities = {'\x91' => '&lsquo;',  # 0x91 (145) and 0x92 (146) are 'smart' singlequotes
                 '\x92' => '&rsquo;',
                 '\x93' => '&ldquo;',  # 0x93 (147) and 0x94 (148) are 'smart' quotes
                 '\x94' => '&rdquo;',
                 '\x96' => '&ndash;',  # 0x96 (150) and 0x97 (151) are en and emdashes
                 '\x97' => '&mdash;',
                 '\x88' => '&hellip;', # 0x88 (133) is an ellisis
    };

    $entitymap = { '&ndash;'  => '-',
                   '&mdash;'  => '-',
                   '&rsquo;'  => "'",
                   '&lsquo;'  => "'",
                   '&ldquo;'  => '"',
                   '&rdquo;'  => '"',
                   '&hellip;' => '...',
                   '&gt;'     => '>',
                   '&lt;'     => '<',
                   '&amp;'    => '&',
                   '&nbsp;'   => ' ',
                   '&#x200B;' => '',
                   '\xE2\x80\x93' => '-',
                   '\xE2\x80\x94' => '-',
                   '\xE2\x80\xA6' => '...'
    };

    @timescales = ( { "seconds" => 31557600, "scale" => 31557600, past => {"singular" => "TIMES_YEAR"   , "plural" => "TIMES_YEARS"   }, future => {"singular" => "FUTURE_YEAR"   , "plural" => "FUTURE_YEARS"   }, },
                    { "seconds" =>  2629800, "scale" =>  2629800, past => {"singular" => "TIMES_MONTH"  , "plural" => "TIMES_MONTHS"  }, future => {"singular" => "FUTURE_MONTH"  , "plural" => "FUTURE_MONTHS"  }, },
                    { "seconds" =>   604800, "scale" =>   604800, past => {"singular" => "TIMES_WEEK"   , "plural" => "TIMES_WEEKS"   }, future => {"singular" => "FUTURE_WEEK"   , "plural" => "FUTURE_WEEKS"   }, },
                    { "seconds" =>    86400, "scale" =>    86400, past => {"singular" => "TIMES_DAY"    , "plural" => "TIMES_DAYS"    }, future => {"singular" => "FUTURE_DAY"    , "plural" => "FUTURE_DAYS"    }, },
                    { "seconds" =>     3600, "scale" =>     3600, past => {"singular" => "TIMES_HOUR"   , "plural" => "TIMES_HOURS"   }, future => {"singular" => "FUTURE_HOUR"   , "plural" => "FUTURE_HOURS"   }, },
                    { "seconds" =>       60, "scale" =>       60, past => {"singular" => "TIMES_MINUTE" , "plural" => "TIMES_MINUTES" }, future => {"singular" => "FUTURE_MINUTE" , "plural" => "FUTURE_MINUTES" }, },
                    { "seconds" =>       15, "scale" =>        1, past => {"singular" => "TIMES_SECONDS", "plural" => "TIMES_SECONDS" }, future => {"singular" => "FUTURE_SECONDS", "plural" => "FUTURE_SECONDS" }, },
                    { "seconds" =>        0, "scale" =>        1, past => {"singular" => "TIMES_JUSTNOW", "plural" => "TIMES_JUSTNOW" }, future => {"singular" => "FUTURE_JUSTNOW", "plural" => "FUTURE_JUSTNOW" }, },
    );
}


# ============================================================================
#  Constructor and language loading

## @cmethod $ new(%args)
# Create a new Template object. This will create a new Template object that will
# allow templates to be loaded into strings, or printed to stdout. Meaningful
# arguments to this constructor are:
#
# - `basedir`   The directory containing template themes, relative to the app root. Defaults to "templates".
# - `langdir`   The directory containing language files. Defaults to "lang". Set this
#               to undef or an empty string to disable language file loading.
# - `lang`      The language file to use. Defaults to "en"
# - `theme`     The theme to use. Defaults to "default"
# - `fallback`  The fallback theme to use if a template file is not found in `theme`. Defaults to "common".
# - `timefmt`   The time format string, strftime(3) format, with the extension %o
#               to mark the location of an ordinal specifier. %o is ignored if it
#               does not immediately follow a digit field. Defaults to "%a, %d %b %Y %H:%M:%S"
# - `blockname` If set, allow blocks to be specified by name rather than id.
# - `usecache`  If true, template files are cached as they are loaded. This will increase memory use, but
#               can make template operations faster in situations where the same template needs to be used
#               repeatedly, but explicity preloading can't be performed. Template files are reloaded if the
#               file mtime has changed since the last load to avoid stale cache entries. This defaults to true.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;

    # Object constructors don't get much more minimal than this...
    my $self = { "basedir"      => "templates",
                 "lang"         => "en",
                 "fallbacklang" => "en",
                 "theme"        => "default",
                 "fallback"     => "common",
                 "timefmt"      => '%a, %d %b %Y %H:%M:%S',
                 "mailfmt"      => '%a, %d %b %Y %H:%M:%S %z',
                 "mailcmd"      => '/usr/sbin/sendmail -t -f chris@starforge.co.uk',#pevesupport@cs.man.ac.uk', # Change -f as needed!
                 "entities"     => $entities,
                 "utfentities"  => $utfentities,
                 "entitymap"    => $entitymap,
                 "blockname"    => 0,
                 "usecache"     => 1,
                 "replacelimit" => 5,
                 @_,
    };

    # Force date formats to sane values.
    $self -> {"timefmt"} = '%a, %d %b %Y %H:%M:%S' unless($self -> {"timefmt"});
    $self -> {"mailfmt"} = '%a, %d %b %Y %H:%M:%S %z' unless($self -> {"mailfmt"});

    my $obj = bless $self, $class;

    # Update the theme and paths
    $self -> set_template_dir($self -> {"theme"});

    return $obj;
}


## @method void DESTROY()
# Destructor method to prevent a circular list formed from a reference to the modules
# hash from derailing normal destruction.
sub DESTROY {
    my $self = shift;

    $self -> {"modules"} = undef;
}


## @method void set_module_obj($modules)
# Store a reference to the module handler object so that the template loader can
# do block name replacements.
#
# @param modules A reference to the system module handler object.
sub set_module_obj {
    my $self = shift;

    $self -> {"modules"} = shift;
}


# ============================================================================
#  Templating functions

## @method void set_language($lang)
# Set the current language to the specified value.
#
# @param lang The new language directory to load language files from. If set to
#             `undef` or `''`, this will clear the language data loaded already.
sub set_language {
    my $self = shift;
    $self -> {"lang"} = shift;
}


## @method $ replace_langvar($varname, $default, $varhash)
# Replace the specified language variable with the appropriate text string. This
# takes a language variable name and returns the value stored for that variable,
# if there is one. If there is no value available, and the default is provided,
# that is returned. If all else fails this just returns "&lt;$varname&gt;"
#
# @param varname The name of the language variable to obtain a value for.
# @param default An optional default value.
# @param varhash An optional reference to a hash containing key-value pairs, any
#                occurance of the key in the text string is replaced with the value.
# @return The value for the language variable, or the default if the value is not
#         available. If the default is not available either this returns the
#         variable name in angled brackets.
sub replace_langvar {
    my $self    = shift;
    my $varname = shift;
    my $default = shift;
    my $varhash = shift;

    # Fix up the arguments - if default is a reference, then it's really the varhash
    # and default was omitted
    if(ref($default) eq "HASH") {
        $varhash = $default;

        # Make the default value be the variable name in red to hilight problems
        $default = "<span style=\"color: red\">&lt;$varname&gt;</span>";
    } elsif(!defined($default)) {
        $default = "<span style=\"color: red\">&lt;$varname&gt;</span>";
    }

    # strip the leadin L_ if present
    $varname =~ s/^L_//o;

    if($self -> {"settings"} -> {"database"} -> {"language"}) {
        my $langh = $self -> {"dbh"} -> prepare("SELECT message FROM ".$self -> {"settings"} -> {"database"} -> {"language"}."
                                                 WHERE name LIKE ?
                                                 AND lang LIKE ?");

        # Try looking for the language variable in both the active language, and the fallback
        foreach my $lang ($self -> {"lang"}, $self -> {"fallbacklang"}) {
            if(!$langh -> execute($varname, $lang)) {
                $self -> {"logger"} -> log("error", 0, "", "Langvar lookup failed: ".$self -> {"dbh"} -> errstr);
                return $default;
            }

            # If a matching language variable has been found, process it and return it
            my $row = $langh -> fetchrow_arrayref();
            if($row) {
                my $txtstr = $row -> [0];

                # If we have a hash of variables to substitute, do the substitute
                if($varhash) {
                    foreach my $key (keys(%$varhash)) {
                        my $value = defined($varhash -> {$key}) ? $varhash -> {$key} : ""; # make sure we get no undefined problems...
                        $txtstr =~ s/\Q$key\E/$value/g;
                    }
                }

                $self -> fix_variables(\$txtstr);

                return $txtstr;
            }
        } # foreach my $lang ($self -> {"lang"}, $self -> {"fallbacklang"}) {
    } # if($self -> {"settings"} -> {"database"} -> {"language"}) {

    return $default;
}


# ============================================================================
#  Templating functions

## @method void set_template_dir($theme)
# Set the template theme directory. This updates the directory from which
# load_template() attempts to load template files. It does not modify the
# fallback theme - that can only be done on Template creation.
#
# @param theme The new theme directory to use. Note that theme directories
#              must be inside the base template directory (usually `templates`).
sub set_template_dir {
    my $self = shift;
    $self -> {"theme"} = shift;

    # Internal base path
    $self -> {"basepath"} = path_join($self -> {"settings"} -> {"config"} -> {"base"}, $self -> {"basedir"});

    # Work out the scriptpath and templatepath
    $self -> {"scriptpath"} = $self -> {"settings"} -> {"config"} -> {"scriptpath"} || "/";
    $self -> {"scriptpath"} .= "/" unless($self -> {"scriptpath"} =~ m|/$|); # Scriptpath must have trailing slash

    # work out the current template path
    $self -> {"templatepath"} = path_join($self -> {"scriptpath"}, $self -> {"basedir"}, $self -> {"theme"});
    $self -> {"templatepath"} .= "/" unless($self -> {"templatepath"} =~ m|/$|); # templatepath must have trailing slash

    # work out the javascript and css paths
    my $dirid = $self -> {"settings"} -> {"config"} -> {"jsdirid"} ? "_".$self -> {"settings"} -> {"config"} -> {"jsdirid"} : "";

    $self -> {"jspath"} = path_join($self -> {"templatepath"}, "js".$dirid);
    $self -> {"jspath"} .= "/" unless($self -> {"jspath"} =~ m|/$|); # jspath must have trailing slash

    $self -> {"csspath"} = path_join($self -> {"templatepath"}, "css".$dirid);
    $self -> {"csspath"} .= "/" unless($self -> {"csspath"} =~ m|/$|); # csspath must have trailing slash

    # The URL...
    $self -> {"templateurl"} = path_join($self -> {"cgi"} -> url(-base => 1), $self -> {"templatepath"})."/"
        if($self -> {"cgi"});

    # And the common path, if possible
    if($self -> {"fallback"}) {
        $self -> {"commonpath"} = path_join($self -> {"scriptpath"}, $self -> {"basedir"}, $self -> {"fallback"});
        $self -> {"commonpath"} .= "/" unless($self -> {"commonpath"} =~ m|/$|); # commonpath must have trailing slash
    } else {
        $self -> {"commonpath"} = $self -> {"templatepath"};
    }
}


## @method $ replace_blockname($blkname, $default)
# Replace a block name with the internal ID for the block. This will replace
# a block name with the equivalent block ID and it can cope with the name
# being embedded in B_[...] strings.
#
# @param blkname The name of the block to replace with a block id.
# @param default Optional default id to use if the block is not found.
# @return The id that corresponds to the specified block name.
sub replace_blockname {
    my $self    = shift;
    my $blkname = shift;
    my $default = shift || "0";

    # Strip the B_[ ] if present
    $blkname =~ s/^B_\[(.*)\]$/$1/;

    # If the system supports named blocks, pass the name back unchanged.
    return $blkname if($self -> {"blockname"} && $blkname);

    # Otherwise, look up the block id
    my $modid = $self -> {"modules"} -> get_block_id($blkname);

    return defined($modid) ? $modid : $default;
}


## @method $ load_template($name, $varmap, $nocharfix)
# Load a template from a file and replace the tags in it with the values given
# in a hashref, return the string containing the filled-in template. The first
# argument should be the filename of the template, the second should be the
# hashref containing the key-value pairs. The keys should be the tags in the
# template to replace, the values should be the text to replace those keys
# with. Tags can be any format and may contain regexp reserved chracters.
#
# @param name      The name of the template to load.
# @param varmap    A reference to a hash containing values to replace in the template.
# @param nocharfix If set, character fixes will not be applied to the templated string.
#                  This defaults to true if not specified.
# @return The template with replaced variables and language markers.
sub load_template {
    my $self      = shift;
    my $name      = shift;
    my $varmap    = shift;
    my $nocharfix = shift;
    my $errs      = shift;

    # Default the nocharfix if needed.
    $nocharfix = 1 unless(defined($nocharfix));

    # Try to load the file from
    foreach my $theme ($self -> {"theme"}, $self -> {"fallback"}) {
        my $filename = path_join($self -> {"basepath"}, $theme, $name);

        # Don't bother even attempting to open the file if it doesn't exist or isn't readable.
        if(!-f $filename || !-r $filename) {
            $errs .= " ".path_join($theme, $name).": does not exist.";
            next;
        }

        my $filemtime = (stat($filename))[9];

        # If caching is enabled, and the times match, the file has been loaded before
        return $self -> process_template($self -> {"cache"} -> {$name} -> {"template"}, $varmap, $nocharfix)
            if($self -> {"usecache"} && $self -> {"cache"} -> {$name} && $self -> {"cache"} -> {$name} -> {"mtime"} == $filemtime);

        # Try the load and process the template...
        if(open(TEMPLATE, "<:utf8", $filename)) {
            undef $/;
            my $lines = <TEMPLATE>;
            $/ = "\n";
            close(TEMPLATE);

            # Cache the template if needed.
            $self -> {"cache"} -> {$name} = { "template" => $lines, "mtime" => $filemtime }
                if($self -> {"usecache"});

            # Do variable substitution
            $self -> process_template(\$lines, $varmap, $nocharfix);

            return $lines;
        } else {
            $errs .= " ".path_join($theme, $name).": $!";
        }
    }

    return "<span class=\"error\">load_template: unable to load $name: $errs</span>";
}


## @method $ process_template($text, $varmap, $nocharfix)
# Perform variable substitution on the text. This will go through each key in the
# provided hashref and replace all occurances of the key in the text with the value
# set in the hash for that key.
#
# The following pre-defined markers are recognised and processed by this function:
#
# - `{L_varname}` is used to indicate a language marker, and it will be replaced by
#   the contents of the `varname` language variable, or an error marker if no
#   corrsponding variable exists.
# - `{B_[somename]}` is used to indicate a block name marker, and it will be replaced
#   by the appropriate block name or id. This is largely redundant at this point - you
#   can use use the literal block name in most situations.
# - `{V_[varname]}` is used to indicate a config variable marker, and will be replaced
#   by the corresponding config variable value, if permitted. See the class docs for
#   more on this.
#
# @todo This function loops until it has no language variables or markers left to
#       replace. It will iterate over the variable map at least once more than it
#       actually needs to in order to confirm that all possible replacements have
#       been made. Try to find some way to optimise this (see bug FS#72)
#
# @param text      The text to process. If this is a reference, the replacement is
#                  done in-place, otherwise the modified string is returned.
# @param varmap    A reference to a hash containing variable names as keys, and the
#                  values to substitute for the keys.
# @param nocharfix If set, character fixes will not be applied to the templated string.
# @return undef if text was a reference, otherwise a copy of the modified string.
sub process_template {
    my $self      = shift;
    my $text      = shift;
    my $varmap    = shift;
    my $nocharfix = shift;

    carp("No text passed to process_template")
        unless($text);

    # If text is a reference already, we can just use it. Otherwise we need
    # to make a reference to the text to simplify the code in the loop below.
    my $textref = ref($text) ? $text : \$text;

    carp("No text passed to process_template")
        unless($$textref);

    # replace all the keys in the text with the appropriate value.
    my ($key, $value, $count);
    my $limit = 0;
    do {
        $count = 0;

        foreach $key (keys %$varmap) {
            # pull out the value if it is defined, blank otherwise - avoids "Use of uninitialized value in substitution" problems
            $value = defined($varmap -> {$key}) ? $varmap -> {$key} : "";
            $count += $$textref =~ s/\Q$key\E/$value/g;
        }

        # Do any language marker replacements
        $count += $$textref =~ s/{L_(\w+?)}/$self->replace_langvar($1)/ge;

        ++$limit;
    } while($count && $limit < $self -> {"replacelimit"});

    warn "process_template aborted template replace after $limit passes.\nContent:$$textref\n"
        if($limit == $self -> {"replacelimit"});

    $self -> fix_variables($textref);

    unless($nocharfix) {
        # Convert some common utf-8 characters
        foreach my $char (keys(%$utfentities)) {
            $$textref =~ s/$char/$utfentities->{$char}/g;
        }

        # Convert horrible smart quote crap from windows
        foreach my $char (keys(%$entities)) {
            carp("Error replacing entitiy: $char, no replacement.")
                if(!$char || !$entities -> {$char});

            $$textref =~ s/$char/$entities->{$char}/g;
        }
    }

    # Return nothing if the text was a reference to begin with, otherwise
    # return the text itself.
    return ref($text) ? undef : $text;
}


## @method $ fix_variables($textref)
# Fix up {V_[name]} and {B_[name]} markers in the specified text. This will replace
# the variable and block markers in the specified text with the expanded equivalents.
#
# @param textref A reference to a string to process.
sub fix_variables {
    my $self = shift;
    my $textref = shift;

    # Fix 'standard' variables
    my $email = $self->{settings}->{config}->{"Core:admin_email"};
    $$textref =~ s/{V_\[scriptpath\]}/$self->{scriptpath}/g;
    $$textref =~ s/{V_\[templatepath\]}/$self->{templatepath}/g;
    $$textref =~ s/{V_\[templateurl\]}/$self->{templateurl}/g;
    $$textref =~ s/{V_\[jspath\]}/$self->{jspath}/g;
    $$textref =~ s/{V_\[csspath\]}/$self->{csspath}/g;
    $$textref =~ s/{V_\[commonpath\]}/$self->{commonpath}/g;
    $$textref =~ s/{V_\[sitename\]}/$self->{settings}->{config}->{site_name}/g;
    $$textref =~ s/{V_\[admin_email\]}/$email/g;

    # Do any module marker replacements if we can
    if($self -> {"modules"}) {
        $$textref =~ s/{B_\[(\w+?)\]}/$self->replace_blockname($1)/ge;
    }
}


# ============================================================================
#  Higher-level templating functions

## @method $ message_box($title, $type, $summary, $longdesc, $additional, $boxclass, $buttons)
# Create a message box block to include in a page. This generates a templated
# message box to include in a page. It assumes the presence of messagebox.tem
# in the template directory, containing markers for a title, type, summary,
# long description and additional data. The type argument should correspond
# to an image in the {template}/images/messages/ directory without an extension.
#
# @param title      The title of the message box.
# @param type       The message type.
# @param summary    A summary version of the message.
# @param longdesc   The full message body
# @param additional Any additional content to include in the message box.
# @param boxclass   Optional additional classes to add to the messagebox container.
# @param buttons    Optional reference to an array of hashes containing button data. Each
#                   hash in the array should contain three keys: `colour` which specifies
#                   the button colour; `action` which should contain javascript to run
#                   when the button is clicked; and `message` which should be the message
#                   to show in the button.
# @return A string containing the message box.
sub message_box {
    my ($self, $title, $type, $summary, $longdesc, $additional, $boxclass, $buttons) = @_;
    my $buttonbar = "";

    # Has the caller specified any buttons?
    if($buttons) {
        my $buttem = $self -> load_template("messagebox_button.tem");

        # Build the list of buttons...
        my $buttonlist = "";
        for my $button (@{$buttons}) {
            $buttonlist .= $self -> process_template($buttem, {"***colour***"  => $button -> {"colour"},
                                                               "***onclick***" => $button -> {"action"},
                                                               "***message***" => $button -> {"message"}});
        }
        # Shove into the bar
        $buttonbar = $self -> load_template("messagebox_buttonbar.tem", {"***buttons***" => $buttonlist});
    }

    return $self -> load_template("messagebox.tem", { "***title***"      => $title,
                                                      "***icon***"       => $type,
                                                      "***summary***"    => $summary,
                                                      "***longdesc***"   => $longdesc,
                                                      "***additional***" => $additional,
                                                      "***buttons***"    => $buttonbar,
                                                      "***boxclass***"   => $boxclass});
}


## @method $ wizard_box($title, $type, $stages, $stage, $longdesc, $additional)
# Create a wizard box block to include in a page. This generates a templated
# wizard box to include in a page. It assumes the presence of wizardbox.tem
# in the template directory, containing markers for a title, type, path,
# long description and additional data. The type argument should correspond
# to an image in the {template}/images/messages/ directory without an extension.
#
# @param title      The title of the message box.
# @param type       The message type.
# @param stages     A reference to an array of hashes containing stages in the wizard.
# @param stage      The current stage number.
# @param longdesc   The message body to show below the stages.
# @param additional Any additional content to include in the wizard box (forms, etc)
# @return A string containing the wizard box.
sub wizard_box {
    my ($self, $title, $type, $stages, $stage, $longdesc, $additional) = @_;

    # Preload the step template
    my $steptem = $self -> load_template("wizardstep.tem");
    chomp($steptem);

    my $path = "";
    for(my $s = 0; $s < scalar(@$stages); ++$s) {
        # calculate some gubbins to make life easier...
        my $step = $stages -> [$s];
        my $mode;

        if($s < $stage) {
            $mode = "passed";
        } elsif($s > $stage) {
            $mode = "inactive";
        } else {
            $mode = "active";
        }

        # Now we need to generate the stage image, this should be simple...
        $path .= $self -> process_template($steptem, {"***image***"  => $step -> {$mode},
                                                      "***width***"  => $step -> {"width"},
                                                      "***height***" => $step -> {"height"},
                                                      "***alt***"    => $step -> {"alt"}});
    }

    return $self -> load_template("wizardbox.tem", { "***title***"      => $title,
                                                     "***icon***"       => $type,
                                                     "***path***"       => $path,
                                                     "***longdesc***"   => $longdesc,
                                                     "***additional***" => $additional });
}


## @method $ build_optionlist($options, $default, $selectopts)
# Generate a HTML option list based on the contents of the passed options.
# This goes through the entries in the options list provided, processing the
# entries into a list of html options.
#
# @param options    A reference to an array of hashrefs, each hash needs to contain
#                   at least two keys: name and value, corresponding to the option
#                   name and value. You may also optionally include a 'title' in the
#                   hash to use as the option title.
# @param default    The default *value* to select in the list. This can either be a
#                   single scalar, or a reference to an array of selected values.
# @param selectopts Options to set on the select element. If not provided, no select
#                   element is generated. If provided, this should be a reference to
#                   a hash containing select options (supported: name, id, multiple,
#                   size, events). If events is specified, it should be a reference to
#                   a hash containing event names (change, click, blur, etc) as
#                   keys and the javascript operation to invoke as the value.
# @return A string containing the option list, possibly wrapped in a select element.
sub build_optionlist {
    my $self       = shift;
    my $options    = shift;
    my $default    = shift // [];
    my $selectopts = shift;

    # May as well hard-code the option template.
    my $opttem = "<option value=\"***value***\"***sel******title***>***name***</option>\n";

    # Force arrayref for default
    $default = [ $default ] if(defined($default) && ref($default) ne "ARRAY");

    # Convert default to a hash for faster lookup
    my %selected = ();
    foreach my $val (@{$default}) {
        if(!defined($val)) {
            carp "Undefined value in default list.";
            next;
        }
        $selected{$val} = 1;
    }

    # Now build up the option string
    my $optstr = "";
    foreach my $option (@{$options}) {
        my $sel = $selected{$option -> {"value"}} ? ' selected="selected"' : '';

        $optstr .= $self -> process_template($opttem, {"***name***"  => encode_entities($option -> {"name"}),
                                                       "***value***" => encode_entities($option -> {"value"}),
                                                       "***sel***"   => $sel,
                                                       "***title***" => defined($option -> {"title"}) ? ' title="'.encode_entities($option -> {"title"}).'"' : ''});
    }

    # Handle select options, if any.
    if($selectopts) {
        my $select = "<select";
        $select .= ' id="'.$selectopts -> {"id"}.'"' if($selectopts -> {"id"});
        $select .= ' name="'.$selectopts -> {"name"}.'"' if($selectopts -> {"name"});
        $select .= ' size="'.$selectopts -> {"size"}.'"' if($selectopts -> {"size"});
        $select .= ' multiple="'.$selectopts -> {"multiple"}.'"' if($selectopts -> {"multiple"});

        if($selectopts -> {"events"}) {
            foreach my $event (keys(%{$selectopts -> {"events"}})) {
                $select .= ' on'.$event.'="'.$selectopts -> {"events"} -> {$event}.'"';
            }
        }
        $optstr = $select.">\n$optstr</select>\n";
    }

    return $optstr;
}


# ============================================================================
#  Emailing functions

## @method $ email_template($template, $args)
# Load a template and send it as an email to the recipient(s) listed in the arguments.
# This function will load a template from the template directory, fill in the fields
# as normal, and prepend an email header using the to and cc fields in the args (bcc
# is not supported).
#
# @deprecated This function should not be used in new code: it is horribly inflexible,
#             relies heavily on sendmail-based functionality, and is not really part of
#             the template engine's job anyway. New code should use the facilities
#             provided by Webperl::Message::Queue - you should send email by calling
#             Webperl::Message::Queue::queue_message(), using Webperl::Template::load_template()
#             to load and process the message body before passing it into `queue_message()`
#             in the `message` argument.
#
# @param template The name of the template to load and send.
# @param args     A reference to a hash containing values to substitute in the template.
#                 This MUST include 'from', 'to', and 'subject' values!
# @return undef on success, otherwise an error message.
sub email_template {
    my $self     = shift;
    my $template = shift;
    my $args     = shift;
    my $email;

    print STDERR longmess("Call to deprecated Webperl::Template::email_template()");

    # Check we have required fields
    return "No from field specified in email template arguments."    if(!$args -> {"***from***"});
    return "No subject field specified in email template arguments." if(!$args -> {"***subject***"});

    # Build the header first...
    $email  = "From: ".$args -> {"***from***"}."\n";
    $email .= "To: ".$args -> {"***to***"}."\n" if($args -> {"***to***"});
    $email .= "Cc: ".$args -> {"***cc***"}."\n" if($args -> {"***cc***"});
    $email .= "Bcc: ".$args -> {"***bcc***"}."\n" if($args -> {"***bcc***"});
    $email .= "Reply-To: ".$args -> {"***replyto***"}."\n" if($args -> {"***replyto***"});
    $email .= "Subject: ".$args -> {"***subject***"}."\n";
    $email .= "Date: ".strftime($args -> {"***date***"})."\n" if($args -> {"***date***"});
    $email .= "Content-Type: text/plain; charset=\"UTF-8\";\n";
    $email .= "\n";

    # now load and process the template
    $email .= $self -> load_template($template, $args, 1);

    # And send the email
    return $self -> send_email_sendmail($email);
}


## @method $ send_email_sendmail($email)
# Send the specified email using sendmail. This will print the contents of the
# specified email over a pipe to sendmail, sending it to the recipient(s). The
# email should be complete, including any headers.
#
# @deprecated This function should not be used in new code: it is horribly inflexible,
#             relies heavily on sendmail-based functionality, and is not really part of
#             the template engine's job anyway. New code should use the facilities
#             provided by Webperl::Message::Queue - you should send email by calling
#             Webperl::Message::Queue::queue_message(), using Webperl::Template::load_template()
#             to load and process the message body before passing it into `queue_message()`
#             in the `message` argument.
#
# @param email The email to send.
# @return undef if the mail was sent, otherwise an error message is returned.
sub send_email_sendmail {
    my $self = shift;
    my $email = shift;

    print STDERR longmess("Call to deprecated Webperl::Template::send_email_sendmail()");

    open(SENDMAIL, "|".$self -> {"mailcmd"})
        or return "send_email_sendmail: unable to open sendmail pipe: $!";
    print SENDMAIL $email
        or return "send_email_sendmail: error while printing email: $!";
    close(SENDMAIL);

    return undef;
}


# ============================================================================
#  Support functions

## @method $ get_bbcode_path(void)
# Obtain the path to the current template's bbcode translation file. If the path
# does not exist, this returns undef, otherwise it provides the path containing
# the bbcode translations.
#
# @return The filename of the bbcode translation file, or undef if it does not exist.
sub get_bbcode_path {
    my $self = shift;

    my $filename = path_join($self -> {"basepath"}, $self -> {"theme"});

    return (-d $filename) ? $filename : undef;
}


## @fn $ ordinal($val)
# Return the specified value appended with an ordinal suffix.
#
# @param val The value to add a suffix to.
# @return The processed value.
sub ordinal {
    my $val = shift;

    my ($key) = $val =~ /(\d)$/;
    my $ext = "th";
    given($key) {
        when("1") { $ext = "st"; }
        when("2") { $ext = "nd"; }
        when("3") { $ext = "rd"; }
    };

    return $val.$ext;
}


## @method $ format_time($time, $format)
# Given a time un unix timestamp format (seconds since the epoc), create a formatted
# date string. The format string should be in strftime() compatible format, with the
# extension of %o as an ordinal marker (must follow a digit field).
#
# @param time   The time to format.
# @param format Optional format string, if not set the default format is used.
# @return The string containing the formatted time.
sub format_time {
    my $self   = shift;
    my $time   = shift;
    my $format = shift;
    # Fall back on the default if the user has not set a format.
    $format = $self -> {"timefmt"} if(!defined($format));

    my $datestr = strftime($format, localtime($time));
    $datestr =~ s/(\d+)\s*%o/ordinal($1)/ge;

    return $datestr;
}


## @method $ fancy_time($time, $nospan, $allowfuture)
# Generate a string containing a 'fancy' representation of the time - rather than
# explicitly showing the time, this will generate things like "just now", "less
# than a minute ago", "1 minute ago", "20 minutes ago", etc. The real formatted
# time is provided as the title for a span containing the fancy time.
#
# @param time   The time to generate a string for.
# @param nospan Allow the suppression of span generation, in which case only the
#               fancy time string is returned.
# @param allowfuture Support fancy time for future times.
# @return A string containing a span element representing both the fancy time as
#         the element content, and the formatted time as the title. The span has
#         the class 'timestr' for css formatting.
sub fancy_time {
    my $self        = shift;
    my $time        = shift;
    my $nospan      = shift;
    my $allowfuture = shift;
    my $fancytime;

    my $now       = time();
    my $formatted = $self -> format_time($time);

    # If the duration is negative (time is in the future), just use format_time
    my $dur = $now - $time;
    my $isfuture = ($dur < 0) ? "future" : "past";

    if($isfuture eq "future" && !$allowfuture) {
        $fancytime = $formatted;

    # Otherwise, find the largest matching time string
    } else {
        $dur *= -1 if($dur < 0);

        foreach my $scale (@timescales) {
            if($dur >= $scale -> {"seconds"}) {
                $dur = int($dur / $scale -> {"scale"}); # Always going to be positive, so no need for floor() here

                $fancytime = $self -> replace_langvar($dur == 1 ? $scale -> {$isfuture} -> {"singular"} : $scale -> {$isfuture} -> {"plural"}, {"%t" => $dur});
                last;
            }
        }
    }

    return $fancytime if($nospan);

    return '<span class="timestr" title="'.$formatted.'">'.$fancytime.'</span>';
}


## @method $ html_clean($text)
# Process the specified text, converting ampersands, quotes, and angled brakets
# into xml-safe character entity codes.
#
# @param text The text to process.
# @return The text with &, ", < and > replaces with &amp;, $quot;, $lt;, and &gt;
sub html_clean {
    my $self = shift;
    my $text = shift;

    # replace the four common character entities (FIXME: support more entities)
    if($text) {
        $text =~ s/&(?!amp|quot|lt|gt)/&amp;/g; # only replace & if it isn't already prefixing a character entity we know
        $text =~ s/\"/&quot;/g;
        $text =~ s/\</&lt;/g;
        $text =~ s/\>/&gt;/g;
    }

    return $text;
}


## @method $ html_strip($html)
# Strip the html from the specified string, returning the plain text content.
#
# @param html A string containing the HTML to strip the tags from
# @return A string containing the pla
sub html_strip {
    my $self = shift;
    my $html = shift;

    require HTML::TokeParser::Simple;
    my $tokparser = HTML::TokeParser::Simple -> new(string => $html);

    my $text = "";
    while(my $token = $tokparser -> get_token()) {
        next unless $token->is_text();
        $text .= $token -> as_is();
    }

    return $text;
}


## @method $ html_to_markdown($html, $images, $tmplnames, $extramode)
# Convert the specified html into markdown text.
#
# @param html      The HTML to convert to markdown.
# @param images    An optional reference to an array of images.
# @param tmplnames A reference to a hash containing template names.
# @param extramode If true, turn on support for Markdown Extra mode.
# @return The markdown version of the text.
sub html_to_markdown {
    my $self      = shift;
    my $html      = shift;
    my $images    = shift;
    my $tmplnames = shift;
    my $extramode = shift || 0;

    # Handle html entities that are going to break...
    foreach my $entity (keys(%{$self -> {"entitymap"}})) {
        $html =~ s/$entity/$self->{entitymap}->{$entity}/g;
    }

    # Strip gravatar links
    $html =~ s|<img[^>]+src="https://gravatar.com/[^>]+> ||g;

    my $converter = new HTML::WikiConverter(dialect => 'Markdown',
                                            link_style => 'inline',
                                            image_tag_fallback => 0,
                                            md_extra => $extramode,
                                            encoding => 'utf8');
    my $body = $converter -> html2wiki($html);

    # Clean up html the converter misses consistently
    $body =~ s|<br\s*/>|\n|g;
    $body =~ s|&gt;|>|g;

    # WikiConverter's markdown converter knows not about tables
    $body =~ s{</?(table|tr|td)>}{}g;

    # fix title links
    $body =~ s|^(#+\s+)\[ \[.*?\]\(.*?\) \]<>|$1|mg;
    $body =~ s|^(#+\s+)<>|$1|mg;

    # Strip anchors
    $body =~ s|\t\{#.*?\}||g;
    $body =~ s|\[([^\]]+)\]\(#.*?\)|$1|g;

    # Convert titles
    $body =~ s|^(#+)\s+(.*?)$|_markdown_underline($1, $2)|gem;

    # Sometimes there are bizarre <>s left in the content, dunno why...
    $body =~ s|<>||g;

    # Fix underscores in links
    $body =~ s|\[([^\]]+)\]|_fix_link_underscores($1)|ge;

    $body =~ s|\n\n+|\n\n|g;

    my $imglist = "";
    for(my $i = 0; $i < 3; ++$i) {
        next unless($images -> [$i] -> {"location"});

        $imglist .= $self -> load_template($tmplnames -> {"image"}, {"***url***" => $images -> [$i] -> {"location"}});
    }

    my $imageblock = $self -> load_template($tmplnames -> {"images"}, {"***images***" => $imglist})
        if($imglist);

    return $self -> load_template($tmplnames -> {"markdown"}, {"***text***"   => $body,
                                                               "***images***" => $imageblock});
}


## @sub private $ _markdown_underline($level, $title)
# Given a markdown underline level and matching title, generate a
# replacement that uses underscores rather than #, ##, ###, etc
#
# @param level The markdown '#'-style underline level
# @param title The text of the title
# @return A new string containing the title with underscores.
sub _markdown_underline {
    my $level = shift;
    my $title = shift;
    my $type;

    given($level) {
        when("#")   { $type = "-="; }
        when("##")  { $type = "="; }
        when("###") { $type = "-"; }
    }
    return $title if(!$type);

    # Build the underscores - may need additional trimming as 'type' can be multichar
    my $underscore = $type x length($title);
    $underscore = substr($underscore, 0, length($title))
        if(length($underscore) > length($title));

    return $title."\n".$underscore;
}


sub _fix_link_underscores {
    my $text = shift;

    $text =~ s/\\_/_/g;
    return "[".$text."]";
}


## @method $ bytes_to_human($bytes, $long)
# Convenience wrappper around humanise_bytes for backwards compatibility.
#
# @deprecated This function should not be used in new code - use humanise_bytes() instead.
#
# @param bytes The byte count to convert
# @param long  If set to true, use 'Bytes' instead of B in the output. Defaults to false.
# @return A string containing a human-readable version of the byte count.
sub bytes_to_human {
    my $self  = shift;
    my $bytes = shift;
    my $long  = shift;

#    print STDERR "Call to deprecated bytes_to_human"; # Uncomment to enable deprecated code tracing

    return $self -> humanise_bytes($bytes, $long);
}


## @method $ humanise_bytes($bytes, $long)
# Produce a human-readable version of the provided byte count. If $bytes is
# less than 1024 the string returned is in bytes. Between 1024 and 1048576 is
# in KB, between 1048576 and 1073741824 is in MB, over 1073741824 is in GB
#
# @param bytes The byte count to convert
# @param long  If set to true, use 'Bytes' instead of B in the output. Defaults to false.
# @return A string containing a human-readable version of the byte count.
sub humanise_bytes {
    my $self  = shift;
    my $bytes = shift;
    my $long  = shift;

    my $ext = $long ? "ytes" : "";

    if($bytes >= 1073741824) {
        return sprintf("%.2f GB$ext", $bytes / 1073741824);
    } elsif($bytes >= 1048576) {
        return sprintf("%.2f MB$ext", $bytes / 1048576);
    } elsif($bytes >= 1024) {
        return sprintf("%.2f KB$ext", $bytes / 1024);
    } else {
        return "$bytes B$ext";
    }
}


## @method $ humanise_seconds($seconds, $short)
# Convert a number of seconds to days/hours/minutes/seconds. This will take
# the specified number of seconds and output a string containing the number
# of days, hours, minutes, and seconds it corresponds to.
#
# @todo This function outputs English only text. Look into translating?
#
# @param seconds The number of seconds to convert.
# @param short   If set, the generates string uses short forms of 'day', 'hour' etc.
# @return A string containing the seconds in a human readable form
sub humanise_seconds {
    my $self    = shift;
    my $seconds = shift;
    my $short   = shift;
    my ($frac, $mins, $hours, $days);
    my $result = "";

    # Do nothing to non-digit strings.
    return $seconds unless($seconds && $seconds =~ /^\d+(\.\d+)?$/);

    ($frac)  = $seconds =~ /\.(\d+)$/;
    $days    = int($seconds / (24 * 60 * 60));
    $hours   = ($seconds / (60 * 60)) % 24;
    $mins    = ($seconds / 60) % 60;
    $seconds = $seconds % 60;

    if($days) {
        $result .= $days.($short ? "d" : " day").(!$short && $days  > 1 ? "s" : "");
    }

    if($hours) {
        $result .= ", " if($result);
        $result .= $hours.($short ? "h" : " hour").(!$short && $hours > 1 ? "s" : "");
    }

    if($mins) {
        $result .= ", " if($result);
        $result .= $mins.($short ? "m" : " minute").(!$short && $mins  > 1 ? "s" : "");
    }

    if($seconds) {
        $result .= ", " if($result);
        $result .= $seconds.($frac ? ".$frac" : "").($short ? "s" : " second").(!$short && $seconds > 1 ? "s" : "");
    }

    return $result;
}


## @method $ truncate_words($data, $len)
# Truncate the specified string to the nearest word boundary less than the specified
# length. This will take a string and, if it is longer than the specified length
# (or the default length set in the settings, if the length is not given), it will truncate
# it to the nearest space, hyphen, or underscore less than the desired length. If the
# string is truncated, it will have an elipsis ('...') appended to it.
#
# @param data The string to truncate.
# @param len  Optional length in characters. If not specified, this will default to the
#             Core:truncate_length value set in the configuation. If the config value
#             is missing, this function does nothing.
# @return A string that fits into the specified length.
sub truncate_words {
    my $self = shift;
    my $data = shift;
    my $len  = shift || $self -> {"settings"} -> {"config"} -> {"Core:truncate_length"}; # fall back on the default if not set

    # return the string unmodified if it fits inside the truncation length (or one isn't set)
    return $data if(!defined($len) || length($data) <= $len);

    # make space for the elipsis
    $len -= 3;

    my $trunc = substr($data, 0, $len);
    $trunc =~ s/^(.{0,$len})[-_;:\.,\?!\s].*$/$1/;

    return $trunc."...";
}


# ============================================================================
#  Error functions

sub set_error { $errstr = shift; return undef; }

1;
