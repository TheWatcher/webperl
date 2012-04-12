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
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

## @class Template
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
# @bug See bug FS#70 for issues related to default language variables and
#      langvar sharing between translations.
#
# Block name replacement
# ----------------------
# The template engine will recognise and replace `{B_[blockname]}` markers
# with the appropriate block name or id. The `blockname` specified in
# the marker corresponds to the value in the `name` field in the `blocks`
# table. Usually your templates will include content like
#
#     ... href="index.cgi?block={B_[somename]}...etc...
package Template;

use POSIX qw(strftime);
use Utils qw(path_join superchomp);
use strict;

our ($errstr, $utfentities, $entities, $ords);

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
    $ords = {1 => "st",
             2 => "nd",
             3 => "rd",
             21 => 'st',
             22 => 'nd',
             23 => 'rd',
             31 => 'st'
    };
}


# ============================================================================
#  Constructor and language loading

## @cmethod $ new(%args)
# Create a new Template object. This will create a new Template object that will
# allow templates to be loaded into strings, or printed to stdout. Meaningful
# arguments to this constructor are:
#
# * basedir   - The directory containing template themes. Defaults to "templates".
# * langdir   - The directory containing language files. Defaults to "lang". Set this
#               to undef or an empty string to disable language file loading.
# * lang      - The language file to use. Defaults to "en"
# * theme     - The theme to use. Defaults to "default"
# * fallback  - The fallback theme to use if a template file is not found in `theme`. Defaults to "common".
# * timefmt   - The time format string, strftime(3) format, with the extension %o
#               to mark the location of an ordinal specifier. %o is ignored if it
#               does not immediately follow a digit field. Defaults to "%a, %d %b %Y %H:%M:%S"
# * blockname - If set, allow blocks to be specified by name rather than id.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;

    # Object constructors don't get much more minimal than this...
    my $self = { "basedir"     => "templates",
                 "langdir"     => "lang",
                 "lang"        => "en",
                 "theme"       => "default",
                 "fallback"    => "common",
                 "timefmt"     => '%a, %d %b %Y %H:%M:%S',
                 "mailfmt"     => '%a, %d %b %Y %H:%M:%S %z',
                 "mailcmd"     => '/usr/sbin/sendmail -t -f chris@starforge.co.uk',#pevesupport@cs.man.ac.uk', # Change -f as needed!
                 "entities"    => $entities,
                 "utfentities" => $utfentities,
                 "blockname"   => 0,
                 @_,
    };

    # Force date formats to sane values.
    $self -> {"timefmt"} = '%a, %d %b %Y %H:%M:%S' unless($self -> {"timefmt"});
    $self -> {"mailfmt"} = '%a, %d %b %Y %H:%M:%S %z' unless($self -> {"mailfmt"});

    my $obj = bless $self, $class;

    # Load the language definitions
    $obj -> load_language() or return undef
        if($self -> {"langdir"} && $self -> {"lang"});

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

## @method $ set_language($lang)
# Set the current language to the specified value. This will update the language
# variables loaded in the system to the values set in the language files in the
# specified language directory. This *will not erase* any previously loaded language
# definitions - if you need to do that, call this with `lang` set to `undef` first, and
# then call it with the new language.
#
# @param lang The new language directory to load language files from. If set to
#             `undef` or `''`, this will clear the language data loaded already.
# @return true if the language files were loaded successfully, false otherwise.
sub set_language {
    my $self = shift;
    $self -> {"lang"} = shift;

    # If the lang name has been cleared, drop the words hash.
    if(!$self -> {"lang"}) {
        $self -> {"words"} = {};
        return 1;
    }

    # Otherwise, load the new language...
    return $self -> load_language(1); # force overwite, we expect it to happen now.
}


## @method $ load_language($force_overwrite)
# Load all of the language files in the appropriate language directory into a hash.
# This will attempt to load all .lang files inside the langdir/lang/ directory,
# attempting to parse VARNAME = string into a hash using VARNAME as the key and string
# as the value. The hash is build up inside the Template object rather than returned.
#
# @param force_overwrite If true, redefinition of language variables will not result
#                        in warning messages in the logs.
# @return true if the language files loaded correctly, undef otherwise.
sub load_language {
    my $self            = shift;
    my $force_overwrite = shift;

    # First work out which directory we are dealing with
    my $langdir = path_join($self -> {"langdir"}, $self -> {"lang"});

    # open it, so we can process files therein
    opendir(LANG, $langdir)
        or return set_error("Unable to open language directory '$langdir' for reading: $!");

    while(my $name = readdir(LANG)) {
        # Skip anything that doesn't identify itself as a .lang file
        next unless($name =~ /\.lang$/);

        my $filename = path_join($langdir, $name);

        # Attempt to open and parse the lang file
        if(open(WORDFILE, "<:utf8", $filename)) {
            while(my $line = <WORDFILE>) {
                superchomp($line);

                # skip comments
                next if($line =~ /^\s*#/);

                # Pull out the key and value, and
                my ($key, $value) = $line =~ /^\s*(\w+)\s*=\s*(.*)$/;
                next unless(defined($key) && defined($value));

                # Unslash any \"s
                $value =~ s/\\\"/\"/go;

                # warn if we are about to redefine a word
                $self -> {"logger"} -> warn_log("Unknown", "$key already exists in language hash!")
                    if($self -> {"words"} -> {$key} && !$force_overwrite);

                $self -> {"words"} -> {$key} = $value;
            }

            close(WORDFILE);
        }  else {
            $self -> {"logger"} -> warn_log("Unknown", "Unable to open language file $filename: $!");
        }
    }

    closedir(LANG);

    # Did we get any language data at all?
    return set_error("Unable to load any lanugage data. Check your language selection!")
        if(!defined($self -> {"words"}));

    return 1;
}


## @method $ replace_langvar($varname, $default, $varhash)
# Replace the specified language variable with the appropriate text string. This
# takes a language variable name and returns the value stored for that variable,
# if there is on. If there is no value available, and the default is provided,
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
        $default = "<span style=\"color: red\">$varname</span>";
    } elsif(!defined($default)) {
        $default = "<span style=\"color: red\">$varname</span>";
    }

    # strip the leadin L_ if present
    $varname =~ s/^L_//o;

    if(defined($self -> {"words"} -> {$varname})) {
        my $txtstr = $self -> {"words"} -> {$varname};

        # If we have a hash of variables to substitute, do the substitute
        if($varhash) {
            foreach my $key (keys(%$varhash)) {
                my $value = defined($varhash -> {$key}) ? $varhash -> {$key} : ""; # make sure we get no undefined problems...
                $txtstr =~ s/\Q$key\E/$value/g;
            }
        }

        # Do any module marker replacements if we can
        if($self -> {"modules"}) {
            $txtstr =~ s/{B_\[(\w+?)\]}/$self->replace_blockname($1)/ge;
        }

        return $txtstr;
    }

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

    # Default the nocharfix if needed.
    $nocharfix = 1 unless(defined($nocharfix));

    # Try to load the file from
    foreach my $theme ($self -> {"theme"}, $self -> {"fallback"}) {
        my $filename = path_join($self -> {"basedir"}, $theme, $name);

        # Don't bother even attempting to open the file if it doesn't exist or isn't readable.
        next if(!-f $filename || !-r $filename);

        # Try the load and process the template...
        if(open(TEMPLATE, "<:utf8", $filename)) {
            undef $/;
            my $lines = <TEMPLATE>;
            $/ = "\n";
            close(TEMPLATE);

            # Do variable substitution
            $self -> process_template(\$lines, $varmap, $nocharfix);

            return $lines;
        }
    }

    return "<span class=\"error\">load_template: error opening $name</span>";
}


## @method $ process_template($text, $varmap, $nocharfix)
# Perform variable substitution on the text. This will go through each key in the
# provided hashref and replace all occurances of the key in the text with the value
# set in the hash for that key.
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

    # If text is a reference already, we can just use it. Otherwise we need
    # to make a reference to the text to simplify the code in the loop below.
    my $textref = ref($text) ? $text : \$text;

    # replace all the keys in the text with the appropriate value.
    my ($key, $value, $count);
    do {
        $count = 0;

        foreach $key (keys %$varmap) {
            # pull out the value if it is defined, blank otherwise - avoids "Use of uninitialized value in substitution" problems
            $value = defined($varmap -> {$key}) ? $varmap -> {$key} : "";
            $count += $$textref =~ s/\Q$key\E/$value/g;
        }

        # Do any language marker replacements
        $count += $$textref =~ s/{L_(\w+?)}/$self->replace_langvar($1)/ge;
    } while($count);

    # Do any module marker replacements if we can
    if($self -> {"modules"}) {
        $$textref =~ s/{B_\[(\w+?)\]}/$self->replace_blockname($1)/ge;
    }

    unless($nocharfix) {
        # Convert some common utf-8 characters
        foreach my $char (keys(%$utfentities)) {
            $$textref =~ s/$char/$utfentities->{$char}/g;
        }

        # Convert horrible smart quote crap from windows
        foreach my $char (keys(%$entities)) {
            $$textref =~ s/$char/$entities->{$char}/g;
        }
    }

    # Return nothing if the text was a reference to begin with, otherwise
    # return the text itself.
    return ref($text) ? undef : $text;
}


# ============================================================================
#  Higher-level templating functions

## @method $ message_box($title, $type, $summary, $longdesc, $additional)
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
# @return A string containing the message box.
sub message_box {
    my ($self, $title, $type, $summary, $longdesc, $additional) = @_;

    return $self -> load_template("messagebox.tem", { "***title***"      => $title,
                                                      "***icon***"       => $type,
                                                      "***summary***"    => $summary,
                                                      "***longdesc***"   => $longdesc,
                                                      "***additional***" => $additional });
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


# ============================================================================
#  Emailing functions

## @method $ email_template($template, $args)
# Load a template and send it as an email to the recipient(s) listed in the arguments.
# This function will load a template from the template directory, fill in the fields
# as normal, and prepend an email header using the to and cc fields in the args (bcc
# is not supported).
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
# @param email The email to send.
# @return undef if the mail was sent, otherwise an error message is returned.
sub send_email_sendmail {
    my $self = shift;
    my $email = shift;

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

    my $filename = path_join($self -> {"basedir"}, $self -> {"theme"});

    return (-d $filename) ? $filename : undef;
}


## @fn $ ordinal($val)
# Return the specified value appended with an ordinal suffix.
#
# @param val The value to add a suffix to.
# @return The processed value.
sub ordinal {
    my $val = shift;

    return $val.($ords -> {$val} ? $ords -> {$val} : "th");
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


## @method $ bytes_to_human($bytes, $long)
# Produce a human-readable version of the provided byte count. If $bytes is
# less than 1024 the string returned is in bytes. Between 1024 and 1048576 is
# in KB, between 1048576 and 1073741824 is in MB, over 1073741824 is in GB
#
# @param bytes The byte count to convert
# @param long  If set to true, use 'Bytes' instead of B in the output. Defaults to false.
# @return A string containing a human-readable version of the byte count.
sub bytes_to_human {
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


## @fn $ humanise_seconds($seconds, $short)
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


# ============================================================================
#  Error functions

sub set_error { $errstr = shift; return undef; }

1;
