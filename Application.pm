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
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

## @class
# Provide the core functionality required to initialise and run a web application
# based on the webperl framework. This class is effectively a bootstrapper,
# allowing the core of a web application to be created with minimal code - all
# the developer needs to do is:
#
#     use lib "/path/to/webperl";
#     use lib "modules";
#     use Application;
#     use AppUser::MySystem; # Implemented in modules/AppUser/MySystem.pm
#
#     my $app = Application -> new(appuser => AppUser::MySystem -> new());
#     $app -> run();
#
# In general, you will also want to load CGI::Carp and set it up, to handle
# problems with fatals. Note that using this module is not required to use
# the webperl modules - you can load the modules individually and set them
# up as needed, this just simplifies the process. See the @ref overview Overview
# documentation for more details about the operation of this class.
#
# @todo Web applications created using the Application class use the default
#       language and template settings - i18n and template selection need to
#       be added after the session handler has been started. See bug FS#68.
package Application;

use strict;

# System modules
use DBI;
use Encode;
use Module::Load;
use Time::HiRes qw(time);

# Webperl modules
use Auth;
use ConfigMicro;
use Logging qw(start_log end_log die_log);
use Template;
use SessionHandler;
use Modules;
use Utils qw(path_join is_defined_numeric get_proc_size);

our $errstr;

BEGIN {
	$errstr = '';
}


# ============================================================================
#  Constructor

## @cmethod Application new(%args)
# Create a new Application object. This will create an Application object that
# can be used to generate the pages of a web application. Supported arguments
# are:
#
# - `config`, the location of the application config file, defaults to `config/site.cfg`.
# - `use_phpbb`, if set, the phpBB3 support module is loaded (and takes over auth: the
#   `auth` argument is ignored if `use_phpbb` is set).
# - `appuser`, a reference to an AppUser subclass object to do application-specific
#   user tasks during auth. Can be omitted if use_phpbb is set.
# - `auth`, an optional reference to an auth object. If not specified, and `use_phpbb`
#   is not set, an Auth object is made for you.
#
# @param args A hash of arguments to initialise the Application object with.
# @return A new Application object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = {
        config    => "config/site.cfg",
        use_phpbb => 0,
        @_,
    };

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

    # Load the system config
    $self -> {"settings"} = ConfigMicro -> new($self -> {"config"})
        or die_log("Not avilable", "Application: Unable to obtain configuration file: ".$ConfigMicro::errstr);

    # Create a new CGI object to generate page content through
    $self -> {"cgi"} = $self -> load_cgi($self -> {"settings"} -> {"setup"} -> {"disable_compression"});

    # Database initialisation. Errors in this will kill program.
    $self -> {"dbh"} = DBI->connect($self -> {"settings"} -> {"database"} -> {"database"},
                                    $self -> {"settings"} -> {"database"} -> {"username"},
                                    $self -> {"settings"} -> {"database"} -> {"password"},
                                    { RaiseError => 0, AutoCommit => 1, mysql_enable_utf8 => 1 })
        or die_log($self -> {"cgi"} -> remote_host(), "Application: Unable to connect to database: ".$DBI::errstr);

    # Pull configuration data out of the database into the settings hash
    $self -> {"settings"} -> load_db_config($self -> {"dbh"}, $self -> {"settings"} -> {"database"} -> {"settings"});

    # Start doing logging if needed
    start_log($self -> {"settings"} -> {"config"} -> {"logfile"}) if($self -> {"settings"} -> {"config"} -> {"logfile"});

    # Create the template handler object
    $self -> {"template"} = Template -> new(basedir   => path_join($self -> {"settings"} -> {"config"} -> {"base"}, "templates"),
                                            timefmt   => $self -> {"settings"} -> {"config"} -> {"timefmt"},
                                            blockname => 1,
                                            mailcmd   => '/usr/sbin/sendmail -t -f '.$self -> {"settings"} -> {"config"} -> {"Core:envelope_address"})
        or die_log($self -> {"cgi"} -> remote_host(), "Application: Unable to create template handling object: ".$Template::errstr);

    # If phpbb mode is enabled, it takes over auth.
    if($self -> {"use_phpbb"}) {
        load phpBB3;
        $self -> {"phpbb"} = phpBB3 -> new(prefix   => $self -> {"settings"} -> {"database"} -> {"phpbb_prefix"},
                                           cgi      => $self -> {"cgi"},
                                           data_src => $self -> {"settings"} -> {"database"} -> {"phpbb_database"},
                                           username => $self -> {"settings"} -> {"database"} -> {"phpbb_username"},
                                           password => $self -> {"settings"} -> {"database"} -> {"phpbb_password"},
                                           codepath => path_join($self -> {"settings"} -> {"config"} -> {"base"}, "templates", "default"),
                                           url      => $self -> {"settings"} -> {"config"} -> {"forumurl"})
            or die_log($self -> {"cgi"} -> remote_host(), "Unable to create phpbb object: ".$phpBB3::errstr);

        $self -> {"auth"} = $self -> {"phpbb"};

    # phpBB3 is not enabled, initialise the auth modules.
    } else {
        # Initialise the appuser object
        $self -> {"appuser"} -> init($self -> {"cgi"}, $self -> {"dbh"}, $self -> {"settings"});

        # If the auth object is not set, make one
        $self -> {"auth"} = Auth -> new() if(!$self -> {"auth"});

        # Initialise the auth object
        $self -> {"auth"} -> init($self -> {"cgi"}, $self -> {"dbh"}, $self -> {"appuser"}, $self -> {"settings"});
    }

    # Start the session engine...
    $self -> {"session"} = SessionHandler -> new(cgi      => $self -> {"cgi"},
                                                 dbh      => $self -> {"dbh"},
                                                 auth     => $self -> {"auth"},
                                                 template => $self -> {"template"},
                                                 settings => $self -> {"settings"})
        or die_log($self -> {"cgi"} -> remote_host(), "Application: Unable to create session object: ".$SessionHandler::errstr);

    # And now we can make the module handler
    $self -> {"modules"} = Modules -> new(cgi      => $self -> {"cgi"},
                                          dbh      => $self -> {"dbh"},
                                          settings => $self -> {"settings"},
                                          template => $self -> {"template"},
                                          session  => $self -> {"session"},
                                          phpbb    => $self -> {"phpbb"}, # this will handily be undef if phpbb mode is disabled
                                          blockdir => $self -> {"settings"} -> {"paths"} -> {"blocks"} || "blocks",
                                          logtable => $self -> {"settings"} -> {"database"} -> {"logging"})
        or die_log($self -> {"cgi"} -> remote_host(), "Application: Unable to create module handling object: ".$Modules::errstr);

    # Obtain the page moduleid, fall back on the default if this fails
    my $pageblock = $self -> {"cgi"} -> param("block");
    $pageblock = $self -> {"settings"} -> {"config"} -> {"default_block"} if(!$pageblock); # This ensures $pageblock is defined and non-zero

    # Obtain an instance of the page module
    my $pageobj = $self -> {"modules"} -> new_module($pageblock)
        or die_log($self -> {"cgi"} -> remote_host(), "Application: Unable to load page module $pageblock: ".$self -> {"modules"} -> {"errstr"});

    # And call the page generation function of the page module
                   my $content = $pageobj -> page_display();

    print $self -> {"cgi"} -> header(-charset => 'utf-8',
                                     -cookie  => $self -> {"session"} -> session_cookies());

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
    $self -> {"template"} -> set_module_obj(undef);

    $self -> {"dbh"} -> disconnect();
    end_log();
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
    my $cgi;

    # If the user isn't forcing uncompressed cgi, try to load the compressed version
    if(!$no_compression) {
        # If loading the compressed version of CGI works, use it...
        eval { load CGI::Compress::Gzip, '-utf8' };
        $cgi = CGI::Compress::Gzip -> new()
            if(!$@);
    }

    # If the cgi object has not been created yet, try straight CGI
    if(!$cgi) {
        load CGI, '-utf8';
        $cgi = CGI -> new();
    }

    # In either event, fall over if object creation failed
    die "Unable to load cgi" if(!$cgi);

    return $cgi;
}

1;
