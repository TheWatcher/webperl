## @file
# This file contains the implementation of the webperl application class.
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

## @class Webperl::Application
# Provide the core functionality required to initialise and run a web application
# based on the webperl framework. This class is effectively a bootstrapper,
# allowing the core of a web application to be created with minimal code - all
# the developer needs to do is:
#
#     use lib "/path/to/webperl";
#     use lib "/your/webapp/modules";
#     use Webperl::Application;
#     use Webperl::AppUser::MySystem; # Implemented in modules/Webperl/AppUser/MySystem.pm
#
#     my $app = Application -> new(appuser => Webperl::AppUser::MySystem -> new());
#     $app -> run();
#
# In general, you will also want to load CGI::Carp and set it up, to handle
# problems with fatals. Note that using this module is not required to use
# the webperl modules - you can load the modules individually and set them
# up as needed, this just simplifies the process. See the @ref overview Overview
# documentation for more details about the operation of this class.
#
package Webperl::Application;

use strict;

# System modules
use DBI;
use Encode;
use Module::Load;
use Time::HiRes qw(time);

# Webperl modules
use Webperl::Auth;
use Webperl::BlockSelector;
use Webperl::ConfigMicro;
use Webperl::Logger;
use Webperl::Template;
use Webperl::SessionHandler;
use Webperl::Modules;
use Webperl::Message::Queue;
use Webperl::Utils qw(path_join is_defined_numeric get_proc_size);

our $errstr;

BEGIN {
	$errstr = '';
}


# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Create a new Webperl::Application object. This will create a Webperl::Application
# object that can be used to generate the pages of a web application. Supported
# arguments are:
#
# - `config`, the location of the application config file, defaults to `config/site.cfg`.
#   If a relative path is provided, it is assumed to be relative to the index.cgi
# - `scriptpath`, the path to the directory containing index.cgi. This is needed for
#   scripts running inside mod_perl that may not have cwd set correctly.
# - `appuser`, a reference to a Webperl::AppUser subclass object to do application-specific
#   user tasks during auth.
# - `auth`, an optional reference to an auth object. If not specified, a Webperl::Auth
#    object is made for you.
# - `block_selector`, an optional reference to a Webperl::BlockSelector subclass. If not
#   specified, the default Webperl::BlockSelector is used instead to provide standard
#   block selection behaviour.
# - `system`, an optional reference to a Webperl::System object. If specified, the init()
#   method in this module is called with a hash of arguments containing the database handle,
#   cgi object, settings, session handler, template handler, and module loader.
# - `upload_hook`, an optional reference to a function to use as a CGI upload hook.
# - `post_max`, the maximum size of uploaded data in MB. If not set, the default is to
#   limit posts to 128MB.
#
# @param args A hash of arguments to initialise the Webperl::Application object with.
# @return A new Webperl::Application object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = {
        config    => "config/site.cfg",
        post_max  => 128,
        @_,
    };

    # Make the config file absolute if possible, if it isn't already
    $self -> {"config"} = path_join($self -> {"scriptpath"}, $self -> {"config"})
        if($self -> {"scriptpath"} && $self -> {"config"} !~ m|^/|);

    return bless $self, $class;
}


# ============================================================================
#  Interface code

## @method void run()
# Run the web application. This will perform all the webapp setup tasks, and invoke
# the appropriate page generation module based on the query string/posted arguments.
# Any errors encountered in this function will abort the script.
sub run {
    my $self = shift;

    $self -> {"starttime"} = time();

    $self -> {"logger"} = Webperl::Logger -> new()
        or die "FATAL: Unable to create logger object";

    # Load the system config
    $self -> {"settings"} = Webperl::ConfigMicro -> new($self -> {"config"})
        or $self -> {"logger"} -> die_log("Not avilable", "Application: Unable to obtain configuration file: ".$Webperl::SystemModule::errstr);

    # Create a new CGI object to generate page content through
    $self -> {"cgi"} = $self -> load_cgi($self -> {"settings"} -> {"setup"} -> {"disable_compression"});

    # Database initialisation. Errors in this will kill program.
    $self -> {"dbh"} = DBI->connect($self -> {"settings"} -> {"database"} -> {"database"},
                                    $self -> {"settings"} -> {"database"} -> {"username"},
                                    $self -> {"settings"} -> {"database"} -> {"password"},
                                    { RaiseError => 0, AutoCommit => 1, mysql_enable_utf8 => 1 })
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Application: Unable to connect to database: ".$DBI::errstr);

    # Pull configuration data out of the database into the settings hash
    $self -> {"settings"} -> load_db_config($self -> {"dbh"}, $self -> {"settings"} -> {"database"} -> {"settings"});

    # Start database logging if available
    $self -> {"logger"} -> init_database_log($self -> {"dbh"}, $self -> {"settings"} -> {"database"} -> {"logging"})
        if($self -> {"settings"} -> {"database"} -> {"logging"});

    # Start doing logging if needed
    $self -> {"logger"} -> start_log($self -> {"settings"} -> {"config"} -> {"logfile"}) if($self -> {"settings"} -> {"config"} -> {"logfile"});

    # Message queue handling
    $self -> {"messages"} = Webperl::Message::Queue -> new(logger   => $self -> {"logger"},
                                                           dbh      => $self -> {"dbh"},
                                                           settings => $self -> {"settings"})
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Application: Unable to create message handler: ".$Webperl::SystemModule::errstr);

    # Create the template handler object
    $self -> {"template"} = Webperl::Template -> new(logger    => $self -> {"logger"},
                                                     dbh       => $self -> {"dbh"},
                                                     cgi       => $self -> {"cgi"},
                                                     basedir   => $self -> {"settings"} -> {"config"} -> {"template_dir"} || "templates",
                                                     timefmt   => $self -> {"settings"} -> {"config"} -> {"timefmt"},
                                                     blockname => 1,
                                                     mailcmd   => '/usr/sbin/sendmail -t -f '.$self -> {"settings"} -> {"config"} -> {"Core:envelope_address"},
                                                     settings  => $self -> {"settings"})
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Application: Unable to create template handling object: ".$Webperl::Template::errstr);

    # Initialise the appuser object
    $self -> {"appuser"} -> init($self -> {"cgi"}, $self -> {"dbh"}, $self -> {"settings"}, $self -> {"logger"});

    # If the auth object is not set, make one
    $self -> {"auth"} = Webperl::Auth -> new() if(!$self -> {"auth"});

    # Initialise the auth object
    $self -> {"auth"} -> init($self -> {"cgi"}, $self -> {"dbh"}, $self -> {"appuser"}, $self -> {"settings"}, $self -> {"logger"});

    # Start the session engine...
    $self -> {"session"} = Webperl::SessionHandler -> new(logger   => $self -> {"logger"},
                                                          cgi      => $self -> {"cgi"},
                                                          dbh      => $self -> {"dbh"},
                                                          auth     => $self -> {"auth"},
                                                          template => $self -> {"template"},
                                                          settings => $self -> {"settings"})
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Application: Unable to create session object: ".$Webperl::SessionHandler::errstr);

    # At this point, there's potentially a real user associated with the session. If appropriate,
    # update the template theme and language
    if(!$self -> {"session"} -> anonymous_session()) {
        my $sessuser = $self -> {"session"} -> get_user_byid();

        if($sessuser) {
            $self -> {"template"} -> set_language($sessuser -> {$self -> {"settings"} -> {"config"} -> {"Core:user_lang_field"}})
                if(!$self -> {"settings"} -> {"config"} -> {"Core:force_lang"} && $self -> {"settings"} -> {"config"} -> {"Core:user_lang_field"} && $sessuser -> {$self -> {"settings"} -> {"config"} -> {"Core:user_lang_field"}});

            $self -> {"template"} -> set_template_dir($sessuser -> {$self -> {"settings"} -> {"config"} -> {"Core:user_theme_field"}})
                if(!$self -> {"settings"} -> {"config"} -> {"Core:force_theme"} && $self -> {"settings"} -> {"config"} -> {"Core:user_theme_field"} && $sessuser -> {$self -> {"settings"} -> {"config"} -> {"Core:user_theme_field"}});
        }
    }

    # And now we can make the module handler
    $self -> {"modules"} = Webperl::Modules -> new(logger   => $self -> {"logger"},
                                                   cgi      => $self -> {"cgi"},
                                                   dbh      => $self -> {"dbh"},
                                                   settings => $self -> {"settings"},
                                                   template => $self -> {"template"},
                                                   session  => $self -> {"session"},
                                                   blockdir => $self -> {"settings"} -> {"paths"} -> {"blocks"} || "blocks",
                                                   system   => $self -> {"system"},
                                                   messages => $self -> {"messages"})
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Application: Unable to create module handling object: ".$Webperl::Modules::errstr);

    $self -> {"messages"} -> set_module_obj($self -> {"modules"});

    if($self -> {"system"}) {
        $self -> {"system"} -> init(logger   => $self -> {"logger"},
                                    cgi      => $self -> {"cgi"},
                                    dbh      => $self -> {"dbh"},
                                    settings => $self -> {"settings"},
                                    template => $self -> {"template"},
                                    session  => $self -> {"session"},
                                    modules  => $self -> {"modules"},
                                    messages => $self -> {"messages"})
            or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Application: Unable to create system object: ".$self -> {"system"} -> errstr());

        $self -> {"appuser"} -> set_system($self -> {"system"}) if($self -> {"appuser"});
    }

    # Has a block selector been specified? If not, make a default one
    $self -> {"block_selector"} = Webperl::BlockSelector -> new()
        if(!defined($self -> {"block_selector"}));

    # Obtain the page moduleid, fall back on the default if this fails
    my $pageblock = $self -> {"block_selector"} -> get_block($self -> {"dbh"}, $self -> {"cgi"}, $self -> {"settings"}, $self -> {"logger"}, $self -> {"session"})
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Application: Unable to determine page block: ".$self -> {"block_selector"} -> errstr());

    # Obtain an instance of the page module
    my $pageobj = $self -> {"modules"} -> new_module($pageblock)
        or $self -> {"logger"} -> die_log($self -> {"cgi"} -> remote_host(), "Application: Unable to load page module $pageblock: ".$self -> {"modules"} -> errstr());

    # And call the page generation function of the page module
    my $content = $pageobj -> page_display();

    print $self -> {"cgi"} -> header(-charset => 'utf-8',
                                     -cookie  => $self -> {"session"} -> session_cookies(),
                                     -expires => "now",
                                     -Cache_Control => "no-cache");

    $self -> {"endtime"} = time();
    my ($user, $system, $cuser, $csystem) = times();
    my $debug = "";

    if($self -> {"settings"} -> {"config"} -> {"debug"}) {
        $debug = $self -> {"template"} -> load_template("debug.tem", {"***secs***"   => sprintf("%.2f", $self -> {"endtime"} - $self -> {"starttime"}),
                                                                      "***user***"   => $user,
                                                                      "***system***" => $system,
                                                                      "***memory***" => $self -> {"template"} -> bytes_to_human(get_proc_size())});
    }

    print Encode::encode_utf8($self -> {"template"} -> process_template($content, {"***debug***" => $debug}));

    # Prevent circular references from messing up shutdown
    $self -> {"template"} -> set_module_obj(undef);
    $self -> {"messages"} -> set_module_obj(undef);
    $self -> {"system"} -> clear() if($self -> {"system"});
    $self -> {"appuser"} -> set_system(undef) if($self -> {"appuser"});

    $self -> {"dbh"} -> disconnect();
    $self -> {"logger"} -> end_log();
}


# ============================================================================
#  Internal code

## @method private $ load_cgi($no_compression)
# Dynamically load a module to handle CGI interaction. This will attempt to
# load the best available module for CGI handling based on the modules installed
# on the server: if `CGI::Compress::Gzip` is installed it will use that, otherwise
# it will fall back on plain `CGI`. The interface presented by both classes is the
# same, so the caller should not need to care about which is loaded.
#
# @note In some situations, compression can lead to problems with debugging, and
#       certain sorts of output. If problems are encountered, set the
#       `no_compression` to true to disable compression.
#
# @param no_compression If true, this forces the method to load the uncompressed
#                       version of CGI, even if CGI::Compress::Gzip is available.
#                       This defaults to false (the compressed CGI is used if
#                       it is available).
# @return A reference to a cgi object. This will die on error.
sub load_cgi {
    my $self           = shift;
    my $no_compression = shift;
    my $upload_hook    = shift;
    my $cgi;

    # If the user isn't forcing uncompressed cgi, try to load the compressed version
    if(!$no_compression) {
        # If loading the compressed version of CGI works, use it...
        eval { load CGI::Compress::Gzip };
        $cgi = CGI::Compress::Gzip -> new()
            if(!$@);
    }

    # If the cgi object has not been created yet, try straight CGI
    if(!$cgi) {
        load CGI;
        $cgi = CGI -> new();
    }

    # In either event, fall over if object creation failed
    die "Unable to load cgi" if(!$cgi);

    # Set up post stuff
    $CGI::POST_MAX = $self -> {"post_max"} * 1048576;
    $cgi -> upload_hook($self -> {"upload_hook"}) if($self -> {"upload_hook"});

    return $cgi;
}

1;
