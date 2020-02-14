Configuration                                                        {#config}
=============

The webperl framework includes a basic configuration file reader and writer in
the form of the ConfigMicro class. The ConfigMicro class provides methods for
loading simple '.ini style' configuration files, supporting sections and key-value
pairs, eg:

    [sectionA]
    keyA = valueA
    keyB = valueB

    [sectionB]
    keyC = valueC

When using the Application class as the basis of a web application, you need to
provide a configuration file (the name of which defaults to 'config/site.cfg',
but you can change this via the `config` argument to Application::new())
containing, minimally, the following:

    [database]
    database = DBI:mysql:DATABASE
    username = USERNAME
    password = PASSWORD

    # Standard webperl tables
    auth_methods   = rev_auth_methods
    auth_params    = rev_auth_methods_params
    blocks         = rev_blocks
    keys           = rev_session_keys
    modules        = rev_modules
    sessions       = rev_sessions
    settings       = rev_settings

the `database` section must be present in the configuration at some point - you
may include other sections if you wish, but `database` must be present. The
`database` section must include the keys `database`, `username`, and `password`
providing the credentials that should be used to connect to the webapp's
database. Most of the webperl code has only been tested with MySQL, other
databases may or may not work well with it.

The `database` section should also contain the mapping from internal table
names to actual table names, often this will be a matter of sticking on a
prefix, as shown above, or possibly even straight duplication. Unfortunately
there is no support currently for automatic generation of these aliases,
so each table you use should have an entry in the `database` section.

Once the configuration has been loaded, and the connection to the database
established, the contents of the `settings` table are loaded into the
`config` section of the configuration object.

Blocks invoked via Application are passed the configuration in the "settings"
reference, and can access the sections of the configuration using code like

    $self -> {"settings"} -> {"database"} -> {"auth_methods"}
    $self -> {"settings"} -> {"config"} -> {"base"}

If your code updates values in the `config` section values, you should use
ConfigMicro::save_db_config() or ConfigMicro::set_db_config() to make your
changes persistent.

As noted above, the configuration file may contain more sections than just
the `database` section, so it is perfectly valid to do things like

    [database]
    ... as above...

    [foo]
    bar  = wibble
    quux = fred

And your blocks may access the additional section via, for example,

    $self -> {"settings"} -> {"foo"} -> {"bar"}
