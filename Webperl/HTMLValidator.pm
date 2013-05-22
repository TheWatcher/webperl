## @file
# HTML validation and checking functions. This file contains functions to
# support the cleaning and checking of html using a combination of
# HTML::Scrubber to do first-stage cleaning, HTML::Tidy to clear up the
# content as needed, and the W3C validator via the WebService::Validator::HTML::W3C
# to ensure that the xhtml generated by HTML::Tidy is valid.
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
package Webperl::HTMLValidator;

require Exporter;
use Encode;
use HTML::Scrubber;
use HTML::Tidy;
use WebService::Validator::HTML::W3C;
use strict;

our @ISA       = qw(Exporter);
our @EXPORT    = qw(scrub_html tidy_html check_xhtml);

# =============================================================================
#  HTML::Scrubber related code

# List of tags we are going to let through, lifted from the security
# discussion on  http://wiki.moxiecode.com/index.php/TinyMCE:Security
# Several tags removed to make xhtml conformance easier and to remove
# deprecated and eyestabbery.
my $default_allow = [
    "a", "b", "blockquote", "br", "caption", "col", "colgroup", "comment",
    "em", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "img", "li", "ol", "p",
    "pre", "small", "span", "strong", "sub", "sup", "table", "tbody", "td",
    "tfoot", "th", "thead", "tr", "tt", "ul"
];

# Explicit rules for allowed tags, required to provide per-tag tweaks to the filter.
my $default_rules = [
    img => {
        src    => qr{^(?:http|https)://}i,
        alt    => 1,
        style  => 1,
        width  => 1,
        height => 1,
        '*'    => 0,
    },
    a => {
        href   => qr{^(?:http|https)://}i,
        name   => 1,
        '*'    => 0,
    },
    table => {
        cellspacing => 1,
        cellpadding => 1,
        style       => 1,
        class       => 1,
        '*'         => 0,
    },
    td => {
        colspan => 1,
        rowspan => 1,
        style   => 1,
        '*'     => 0,
    },
    blockquote => {
        cite  => qr{^(?:http|https)://}i,
        style => 1,
        '*'   => 0,
    },
    span => {
        class => 1,
        style => 1,
        title => 1,
        '*'   => 0,
    },
    div => {
        class => 1,
        style => 1,
        title => 1,
        '*'   => 0,
    },
];

# Default ruleset applied when no explicit rule is found for a tag.
my $default_default = [
    0   =>    # default rule, deny all tags
    {
        'href'  => qr{^(?:http|https)://[-\w]+(?:\.[-\w]+)/}i, # Force basic URL forms
        'src'   => qr{^(?:http|https)://[-\w]+(?:\.[-\w]+)/}i, # Force basic URL forms
        'style' => qr{^((?!expr|java|script|eval|\r|\n|\t).)*$}i, # kill godawful insane dynamic css shit (who the fuck thought this would be a good idea?)
        'name'  => 1,
        '*'     => 0, # default rule, deny all attributes
    }
];


## @fn $ scrub_html($html, $allow, $rules, $default)
# Remove dangerous/unwanted elements and attributes from a html document. This will
# use HTML::Scrubber to remove the elements and attributes from the specified html
# that could be used maliciously. There is still the potential for a clever attacker
# to craft a page that bypasses this, but that exists pretty much regardless once
# html input is permitted...
#
# @param html    The string containing the html to clean up
# @param allow   An optional reference to an array of allowed tags to pass to HTML::SCrubber -> new()
# @param rules   An optional reference to a hash of rules to pass to HTML::SCrubber -> new()
# @param default An optional reference to a hash of defaults to pass to HTML::SCrubber -> new()
# @return A string containing the scrubbed html.
sub scrub_html {
    my $html    = shift;
    my $allow   = shift || $default_allow;
    my $rules   = shift || $default_rules;
    my $default = shift || $default_default;

    # Die immediately if there's a nul character in the string, that should never, ever be there.
    die_log("HACK ATTEMPT", "Hack attempt detected. Sod off.")
        if($html =~ /\0/);

    # First, a new scrubber
    my $scrubber = HTML::Scrubber -> new(allow   => $allow,
                                         rules   => $rules,
                                         default => $default,
                                         comment => 0,
                                         process => 0);

    # fix problems with the parser setup. This is hacky and nasty,
    # but from CPAN's bug tracker, this appears to have been present for
    # the past 3 years at least.
    if(exists $scrubber -> {_p}) {
        # Allow for <img />, <br/>, <p></p>, and so on
        $scrubber -> {_p} -> empty_element_tags(1);

        # Make sure that HTML::Parser doesn't scream about utf-8 from the form
        $scrubber -> {_p} -> utf8_mode(1)
            if($scrubber -> {_p} -> can('utf8_mode'));
    }

    # And throw the html through the scrubber
    return $scrubber -> scrub($html);
}


# ==============================================================================
#  HTML::Tidy related code

## @fn $ tidy_html($html, $options)
# Pass a chunk of html through htmltidy. This should produce well-formed xhtml
# that can be passed on to the validator to check.
#
# @param html    The string containing html to tidy.
# @param options A reference to a hash containing options to pass to HTML::Tidy.
# @return The html generated by htmltidy.
sub tidy_html {
    my $html    = shift;
    my $options = shift;

    # Create a new tidy object
    my $tidy = HTML::Tidy->new($options);
    return $tidy -> clean($html);
}


# ==============================================================================
#  WebService::Validator::HTML::W3C related code

## @fn @ check_xhtml($xhtml, $options)
# Check that the xhtml is valid by passing it through the W3C validator service.
# If this is unable to contact the validation service, it will return the reason,
# otherwise the number of errors will be returned (0 indicates that the xhtml
# passed validation with no errors)
#
# @param xhtml   The xhtml to validate with the W3C validator
# @param options A hash containing options to pass to the validator module.
#                Currently supports 'timeout' and 'uri'.
# @return The number of errors during validation (0 = valid), or a string
#         from the validator module explaining why the validation bombed.
sub check_xhtml {
    my $xhtml   = shift;
    my $options = shift;
    return 0;
    # Create a validator
    my $validator = WebService::Validator::HTML::W3C -> new(http_timeout  => $options -> {"timeout"},
                                                            validator_uri => $options -> {"uri"});
    # Throw the xhtml at the validator
    if($validator -> validate_markup(Encode::encode_utf8($xhtml))) {
        # return 0 to indicate it is valid
        return 0
            if($validator -> is_valid());

        my $errs = "";
        foreach my $err (@{$validator -> errors}) {
            $errs .= $err -> msg." at line ".$err -> line."<br/>";
        }

        # otherwise, the xhtml is not valid, so return the error count
        return $validator -> num_errors().":$errs";
    }

    # Get here and the validation request fell over, return the 'oh shit' result...
    return $validator -> validator_error();
}

1;
