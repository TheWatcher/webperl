# @file Simple.pm
#
# @author Chris Page &lt;chris@starforge.co.uk&gt;

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

## @class MediaWiki::Simple
# This module is a simplified wrapper around MediaWiki::API, allowing access to a
# subset of the MediaWiki API facilities through a simple interface. It should be
# noted that this *not* intended as a replacement for more comprehensive higher-level
# interfaces to the API like MediaWiki::Bot - instead, it is intended to provide
# simple and easy access to the most commonly used and needed API facilities
# without the overhead of a large number of functions you'll probably never use.
#
# If you need access to any API features not provided by this bot, but do not
# need the full features of MediaWiki::Bot, you can obtain a reference to a
# MediaWiki::API object to issue API requests directly to by calling the wiki()
# function.
package MediaWiki::Simple;

use v5.12;
use base qw(SystemModule);
use Data::Dumper;
use MediaWiki::API;
use Utils qw(path_join);

# ============================================================================
#  Constructor

## @cmethod MediaWiki::Simple new(%args)
# Create a new MediaWiki api wrapper object. This will create an object that may be
# used to interact with a MediaWiki system through a simplified interface. The
# specified args may contain any of the arguments that can be passed to the
# MediaWiki::API::new() method, with the exception of upload_url (which is stripped
# as it is pointless and obsolete).
#
# @param args A hash of arguments to initialise the object with.
# @return A new MediaWiki::Simple object on success, undef on error.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(minimal    => 1,
                                        warningstr => { "badfilename"            => "The filename has been changed to '%a'",
                                                        "filetyle-unwanted-type" => "The file specified an unwanted file type",
                                                        "large-file"             => "The file submitted was too large",
                                                        "emptyfile"              => "The file submitted was empty",
                                                        "exists"                 => "The filename specified already exists",
                                                        "duplicate"              => "The file submitted is a duplicate of %a",
                                        },
                                        @_);
    return undef if(!$self);

    # Make a new MediaWiki::API object to perform operations through. Since there's
    # no indication of what happens if the constructor fails, hopefully the eval will
    # handle anything unexpected.
    $self -> {"wikih"} = eval { MediaWiki::API -> new($self); };
    return SystemModule::set_error("Unable to initialise MediaWiki API module.")
        if($@ || !$self -> {"wikih"});

    return $self;
}


# ============================================================================
#  Login/out functions

## @method $ login($username, $password)
# Log the specified user into the wiki. Note that, unless you are logging in locally,
# you probably want to make sure that the API is using https, otherwise the credentials
# will be sent in plain text in a POST body (you don't want this to happen).
#
# @param username The username of the user to log into the wiki.
# @param password The password for the user.
# @return true on successful login, false if an error has occurred - in which case, call
#         errstr() to find out what went wrong.
sub login {
    my $self     = shift;
    my $username = shift;
    my $password = shift;

    $self -> clear_error();

    my $login = $self -> {"wikih"} -> login({ lgname     => $username,
                                              lgpassword => $password })
        or $self -> self_error("Unable to log into the wiki. Error from the API was: ".$self -> {"wikih"} -> {"error"} -> {"code"}.': '.$self -> {"wikih"} -> {"error"} -> {"details"});

    return (defined($login -> {"lgusername"}) && ($login -> {"lgusername"} eq $username) &&
            defined($login -> {"result"})     && ($login -> {"result"} eq 'Success'));
}


## @method void logout()
# Log the user out of the wiki, destroying any cookie or tokens associated with the
# current session. This can be safely called even if login hasn't actually been called
# yet (in which case, it does nothing).
sub logout {
    my $self = shift;

    # Logout is always successful.
    $self -> {"wikih"} -> logout();
}


# ============================================================================
#  Editing/updating

## @method $ edit($title, $content, $summary)
# Edit the specified wiki page with the provided content. This replaces the text of
# the specified page (or creates it if it does not exist) with the provided content,
# handling all issued with edit tokens and so on for you.
#
# @param title   The title of the page to edit/create.
# @param content The wiki text to set for the page.
# @param summary An optional summary of the edit.
# @return true if the page was edited successfully, undef on error.
sub edit {
    my $self    = shift;
    my $title   = shift;
    my $content = shift;
    my $summary = shift;

    my $args = { action => 'edit',
                 title  => $title,
                 text   => $content,
                 bot    => 1};
    $args -> {"summary"} = $summary if($summary);

    my $result = $self -> {"wikih"} -> edit($args)
        or $self -> self_error("Unable to edit page '$title'. Error from the API was: ".$self -> {"wikih"} -> {"error"} -> {"code"}.': '.$self -> {"wikih"} -> {"error"} -> {"details"});

    return (defined($result -> {"edit"} -> {"result"}) && $result -> {"edit"} -> {"result"} eq "Success");
}


# ============================================================================
#  Retrieval and parsing

## @method $ get($title, $transclude, $prestrip)
# Retrieve the wiki text for the specified page in the wiki. This will attempt to
# fetch the content for the specified wiki page, and if transclude is set it will
# expand any templates present in the page.
#
# @param title      The title of the page to retrieve.
# @param transclude If true, any templates in the page are processed into expanded
#                   wiki text. Defaults to false (page is returned without any
#                   template expansions).
# @param prestrip   A reference to an array of regular expression strings to strip
#                   from the page before processing (does nothing if transclude is
#                   false.
# @return The wiki page content, in wiki text form, on success (note that the page
#         may exist, but have no contents, in which case this returns an empty string).
#         undef on error.
sub get {
    my $self       = shift;
    my $title      = shift;
    my $transclude = shift;
    my $prestrip   = shift;

    $self -> clear_error();

    return $self -> self_error("Unable to get wiki page: no title specified")
        unless($title);

    # First stage is to determine whether the page exists and has content
    my $page = $self -> {"wikih"} -> get_page({ title => $title } )
        or return $self -> self_error("Unable to fetch page '$title'. Error from the API was: ".$self -> {"wikih"} -> {"error"} -> {"code"}.': '.$self -> {"wikih"} -> {"error"} -> {"details"});

    # Do we have any content? If not, return an error...
    return $self -> self_error("Unable to fetch content for page '$title': page is missing")
        if($page -> {"missing"});

    my $content = $page -> {"*"} || '';

    # Return right here if we are not transcluding, no point doing more work than we need.
    return $content if(!$transclude || !$content);

    # strip out any unwanted content, if needed
    foreach my $strip (@{$prestrip}) {
        $content =~ s|$strip||gis;
    }

    # Break any transclusions inside <nowiki></nowiki> - they maybe be included in the page
    # as examples, and should not be expanded.
    while($content =~ s|(<nowiki>.*?)\{\{([^<]+?)\}\}(.*?</nowiki>)|$1\{\(\{$2\}\)\}$3|is) { };

    # recursively process any remaining transclusions
    $content =~ s/(\{\{.*?\}\})/$self->transclude($title, $1)/ges;

    # revert the breakage done above
    while($content =~ s|(<nowiki>.*?)\{\(\{([^<]+?)\}\)\}(.*?</nowiki>)|$1\{\{$2\}\}$3|is) { };

    # We should be able to return the page now
    return $content;
}


## @method $ parse($title, $text)
# Convert the contents of the specified wiki text to (x)html using the mediawiki parser. This
# parses the text, expanding templates and other markers, acting as if the the specified text
# is in the page with the specified title.
#
# @param title The page title to use when processing the text.
# @param text  The wiki text to process, if not specified the contents of the page with
#              the title specified are parsed and returned.
# @return A string containing the processed (x)html on success, undef on error.
sub parse {
    my $self  = shift;
    my $title = shift;
    my $text  = shift;

    $self -> clear_error();

    return $self -> self_error("Unable to parse wiki text: no title specified")
        unless($title);

    my $args = { action => 'parse' };

    # If text has been specified, parse the text
    if($text) {
        # Append the <references/> if any <ref>s occur in the text, and no <references/> is set
        # This ensures that we always have an anchor for refs
        $text .= "\n<references/>\n"
            if($text =~ /<ref>/ && $text !~ /<references\/>/);

        $args -> {"title"} = $title;
        $args -> {"text"}  = $text;

    # Otherwise fetch the contents of the page.
    } else {
        $args -> {"page"} = $title;
    }

    my $response = $self -> {"wikih"} -> api($args)
        or return $self -> self_error("Unable to process content in page $title. Error from the API was: ".$self -> {"wikih"} -> {"error"} -> {"code"}.': '.$self -> {"wikih"} -> {"error"} -> {"details"});

    # Might get a response with no parsed content, so check and handle that
    return $self -> self_error("No content returned when parsing text for $title")
        if(!$response -> {"parse"} -> {"text"} -> {"*"});

    return $response -> {"parse"} -> {"text"} -> {"*"};
}


## @fn $ transclude($pagename, $templatestr)
# Call on the mediawiki api to convert the specified template string, doing any
# transclusion necessary.
#
# @param pagename    The title of the page the transclusion appears on
# @param templatestr The unescaped transclusion string, including the {{ }}
# @return A string containing the transcluded content on success, undef otherwise.
sub transclude {
    my $self        = shift;
    my $pagename    = shift;
    my $templatestr = shift;

    $self -> clear_error();

    my $response = $self -> {"wikih"} -> api({ action => 'expandtemplates',
                                               title  => $pagename,
                                               prop   => 'revisions',
                                               text   => $templatestr} )
        or return $self -> self_error("Unable to process transclusion in page $pagename. Error from the API was: ".$self -> {"wikih"} -> {"error"} -> {"code"}.': '.$self -> {"wikih"} -> {"error"} -> {"details"});

    # Fall over if the query returned nothing. This probably shouldn't happen - the only situation I can
    # think of is when the target of the transclusion is itself empty, and we Don't Want That anyway.
    return $self -> self_error("Unable to obtain any content for transclusion in page $pagename")
        if(!$response -> {"expandtemplates"} -> {"*"});

    return $response -> {"expandtemplates"} -> {"*"};
}


# ============================================================================
#  Media/image related

## @method $ media_url($title)
# Attempt to obtain the URL of the media file with the given title. This will assume
# the media file can be accessed via the Image: namespace, and any namespace given
# will be stripped before making the query
#
# @param title The title of the media file to obtain the URL for
# @return The URL to the media file, and empty string if it does not exist, or undef
#         on error.
sub media_url {
    my $self = shift;
    my $title = shift;

    $self -> clear_error();

    # strip any existing namespace, if any
    $title =~ s/^.*?://;

    # Ask for the image information for this file
    my $ref = $self -> {"wikih"} -> api({ "action" => 'query',
                                          "titles" => "Image:$title",
                                          "prop"   => 'imageinfo',
                                          "iiprop" => 'url' } )
        or return $self -> self_error("Unable to obtain image information from wiki. API error was: ".$self -> {"wikih"} -> {"error"} -> {"code"}.": ".$self -> {"wikih"} -> {"error"} -> {"details"});

    # get the page id and the page hashref with title and revisions
    my ($pageid, $pageref) = each %{ $ref -> {"query"} -> {"pages"} };

    # if the page is missing then return an empty string
    return '' if(defined($pageref -> {"missing"}));

    return $self -> self_error("Unable to obtain a URL for image $title: No imageinfo available") if(!$pageref -> {"imageinfo"});
    return $self -> self_error("Unable to obtain a URL for image $title: imageinfo is empty") if(!scalar(@{$pageref -> {"imageinfo"}}));
    return $self -> self_error("Unable to obtain a URL for image $title: imageinfo missing URL - ".Dumper($pageref)) if(!@{$pageref -> {"imageinfo"}}[0] -> {"url"});

    my $url = @{$pageref -> {"imageinfo"}}[0] -> {"url"};

    # Handle relative paths 'properly'...
    unless($url =~ /^http\:\/\//) {
        return $self -> self_error("The API returned a relative path for the URL for '$title'. You must provide a value for the files_url argument and try again.")
            if(!$self -> {"wikih"} -> {"config"} -> {"files_url"});

        $url = path_join($self -> {"wikih"} -> {"config"} -> {"files_url"}, $url);
    }

    return $url;
}


## @method @ media_size($title)
# Attempt to obtain the width and height of the media file with the given title.
# This will assume the media file can be accessed via the Image: namespace, and
# any namespace given will be stripped before making the query
#
# @param title The title of the media file to obtain the URL for
# @return The width and height of the media, (0, 0) if it does not exist, undef
#         on error.
sub media_size {
    my $self  = shift;
    my $title = shift;

    $self -> clear_error();

    # strip any existing namespace, if any
    $title =~ s/^.*?://;

    # Ask for the image information for this file
    my $ref = $self -> {"wikih"} -> api({ "action" => 'query',
                                          "titles" => "Image:$title",
                                          "prop"   => 'imageinfo',
                                          "iiprop" => 'size' } )
        or return ($self -> self_error("Unable to obtain image information from wiki. API error was: ".$self -> {"wikih"} -> {"error"} -> {"code"}.": ".$self -> {"wikih"} -> {"error"} -> {"details"}), undef);

    # get the page id and the page hashref with title and revisions
    my ($pageid, $pageref) = each %{ $ref -> {"query"} -> {"pages"} };

    # if the page is missing then return an empty string
    return (0, 0) if(defined($pageref -> {"missing"}));

    my $width  = @{$pageref -> {"imageinfo"}}[0] -> {"width"};
    my $height = @{$pageref -> {"imageinfo"}}[0] -> {"height"};

    # If both are zero, assume they are unobtainable
    return (undef, undef) if(!$width && !$height);

    # Otherwise return what we've got
    return ($width, $height);
}


## @method $ download($title, $filename)
# Attempt to download the file identified by the title from the wiki, and save it
# to the specified title.
#
# @param title    The title of the file to download. Any namespace will be stripped!
# @param filename The name of the file to write the contents to.
# @return undef on success, otherwise an error message.
sub download {
    my $self     = shift;
    my $title    = shift;
    my $filename = shift;

    $self -> clear_error();

    # Work out where the image is...
    my $url = $self -> media_url($title);
    return undef if(!defined($url));
    return $self -> self_error("Unable to obtain url for '$title'. This file does not exist in the wiki") if(!$url);

    # And download it
    return $self -> download_direct($url, $filename);
}


## @method $ download_direct($url, $filename)
# Download a file directly from the wiki, bypassing the normal API. This is generally
# needed to obtain thumbnails or generated images (for example, .png files written by
# the math tag). Note that this does not use the MediaWiki::API::download() method, but
# it does borrow its LWP::UserAgent.
#
# @param url      The URL of the file to download. If this is relative, attempts are made
#                 to make it an absolute URL.
# @param filename The name of the file to save the download to.
# @return true on success, undef on error
sub download_direct {
    my $self     = shift;
    my $url      = shift;
    my $filename = shift;

    $self -> clear_error();

    # First, if the url does not start with https?, we need to prepend the server
    if($url !~ m|^https?://|i) {
        # We can't do a thing about dotted relative paths
        return $self -> self_error("Unable to process relative path in direct download request") if($url =~ /^\.\./);

        my ($server) = $self -> {"wikih"} -> {"config"} -> {"api_url"} =~ m|^(https?://[^/]+)|i;
        return $self -> self_error("Unable to obtain server from api url.") if(!$server);

        $url = path_join($server, $url);
    }

    my $response = $self -> {"wikih"} -> {"ua"} -> get($url, ":content_file" => $filename);

    return $self -> self_error("Unable to download $url. Response was: ".$response -> status_line())
        if(!$response -> is_success());

    return 1;
}


## @method $ upload($filename, $title, $comment, $text)
# Upload a file to the wiki. This allows a local file to be sent to the wiki, with
# an optional comment and initial page text. Note that this will ignore warnings,
# so existing files will be overwritten.
#
# @param filename   The file name of the local file to upload.
# @param title      The title to upload the file as to the wiki. If undef, the name part
#                   of the filename is used.
# @param comment    A n optional comment to set on the file. If this is specified, but
#                   text is not, this is also the initial page text.
# @param text       Optional page text to show on the file's page in the wiki.
# @param ignorewarn If set to true (the default), the upload will ignore warnings -
#                   forcing an upload regardless of whether the file already exists
#                   or other non-fatal warnings are present. If set to false, warnings
#                   will prevent upload, even if they are not fatal.
# @return A string containing the page title on success, an empty string if warnings
#         were encountered (in which case the warnings are in errstr). undef on error.
sub upload {
    my $self = shift;
    my $filename   = shift;
    my $title      = shift;
    my $comment    = shift;
    my $text       = shift;
    my $ignorewarn = shift;

    $ignorewarn = 1 unless(defined($ignorewarn));

    # If no title is set, use the name of the file stripping any extension
    ($title = $filename) =~ s|^(?:.*?/)?([^/]+)(\.\w+)?$|$1|
        if(!$title);

    # Query has a few optional bits, so add them as needed
    my $query = { action         => 'upload',
                  filename       => $title,
                  file           => [$filename, $title] };

    $query -> {"ignorewarnings"} = 1 if($ignorewarn);

    $query -> {"comment"} = $comment if($comment);
    $query -> {"text"}    = $text    if($text);

    my $res = $self -> {"wikih"} -> edit($query)
        or return ($self -> self_error("Unable to perform upload. API error was: ".$self -> {"wikih"} -> {"error"} -> {"code"}.": ".$self -> {"wikih"} -> {"error"} -> {"details"}), undef);

    return $self -> self_error("Unable to perform upload: no result defined.");
        unless(defined($res -> {"upload"} -> {"result"}));

    return ("File:".$res -> {"upload"} -> {"filename"})
        if($res -> {"upload"} -> {"result"} eq "Success");

    if($res -> {"upload"} -> {"result"} eq "Warning") {
        $self -> self_error("Warnings prevented upload: ".$self -> warnings_to_str($res -> {"upload"} -> {"warnings"}));
        return '';
    }

    # This should never happen (errors should be caught by the edit call)
    return $self -> self_error("Unable to perform upload.");
}


# ============================================================================
#  Convenience/support

## @method $ wiki()
# A convenience function to obtain a reference to the current MediaWiki::API object.
#
# @return A reference to the MediaWiki::API object used by the MediaWiki::Simple object
sub wiki {
    my $self = shift;

    return $self -> {"wikih"};
}


## @method $ valid_namespace($namespace, $allow_talk, $minid, $maxid)
# Determine whether the specified namespace exists in the wiki. This will return
# true if the namespace exists, false if it does not.
#
# @param namespace  The namespace to look for in the wiki.
# @param allow_talk If true, talk namespaces are allowed. Defaults to false.
# @param minid      Optional lower limit on the namespace ID, inclusive. Defaults to 0.
# @param maxid      Optional upper limit on the namespace ID, inclusive. Defaults to 32767.
# @return The namespace ID if the namespace exists, -100 otherwise, undef on error.
sub valid_namespace {
    my $self       = shift;
    my $namespace  = shift;
    my $allow_talk = shift;
    my $minid      = shift;
    my $maxid      = shift;

    $self -> clear_error();

    # Set defaults as needed
    $minid = 0     if(!defined($minid));
    $maxid = 32767 if(!defined($maxid));

    return $self -> self_error("Maximum namespace ID must be greater than the minimum ID!")
        unless($maxid > $minid);

    my $namespaces = $self -> {"wikih"} -> api({ action => 'query',
                                                 meta   => 'siteinfo',
                                                 siprop => 'namespaces' })
        or return $self -> self_error("Unable to obtain namespace list from wiki. API error was: ".$self -> {"wikih"} -> {"error"} -> {"code"}.": ".$self -> {"wikih"} -> {"error"} -> {"details"});

    # There may not be a response from the server, so it needs to be checked first...
    if($namespaces -> {"query"} -> {"namespaces"}) {

        # As far as I know there's no specific way to ask the wiki if a specific namespace
        # exists, instead all the namespaces need to be checked to see whether one matches
        foreach my $id (keys(%{$namespaces -> {"query"} -> {"namespaces"}})) {
            my $name = $namespaces -> {"query"} -> {"namespaces"} -> {$id} -> {"*"};

            # Check that the name matches, is in ID range, and possibly isn't a talk page
            return $id if($name && ($name eq $namespace) && ($id >= $minid) && ($id <= $maxid) && ($allow_talk || $id % 2 == 0));
        }
    }

    # Can't return 0 on fail, as NS_MAIN is 0. -1 and -2 are SPECIAL and MEDIA, so blegh.
    return -100;
}


# @method $ make_link($title, $name)
# Generate a wiki link for the specified title. This is a simple convenience
# function to wrap the specified title in the brackets needed to make
# it into a link. If the specified title is '' or undef, this returns ''.
#
# @param title The title to convert to a wiki link.
# @param name  An optional name to use instead of the title.
# @return The link to the page with the specified title.
sub make_link {
    my $self  = shift;
    my $title = shift;
    my $name  = shift;

    return $title ? '[['.$title.($name ? "|$name" : "").']]' : '';
}


## @method $ make_anchor($text)
# Convert the specified string into something that can be used as a mediawiki
# anchor string.
#
# @param text The text to convert.
# @return The converted text.
sub make_anchor {
    my $self = shift;
    my $text = shift;

    $text =~ s/ /_/g;
    $text = uri_encode($text, 1);

    # colons are actually allowed
    $text =~ s/%3A/:/gi;

    # Mediawiki uses . rather than % for escaped
    $text =~ s/%/./g;

    return $text;
}


# ============================================================================
#  Ghastly internals


## @method $ warnings_to_str($warnings)
# Given a hash of upload warnings, convert the warnings to a string suitable for
# returning to the user in a human-readable format.
#
# @param warnings A reference to a hash containing the warnings generated by
#                 an upload operation.
# @return A string containing the warning messages (may be an empty string if
#         no warnings are present).
sub warnings_to_str {
    my $self     = shift;
    my $warnings = shift || return ''; # Do nothing if there are no warnings
    my @entries;

    foreach my $warn (keys(%{$warnings})) {
        my $args = "";
        given($warn) {
            when("duplicate")   { $args = join(", ", @{$warnings -> {$warn}}); }
            when("badfilename") { $args = $warnings -> {$warn}; }
        }

        my $msg = $self -> {"warningstr"} -> {$warn};
        $msg =~ s/%a/$args/g;

        push(@entries, $msg);
    }

    return join("; ", @entries);
}

1;
