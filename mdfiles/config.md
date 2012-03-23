Configuration                                                        {#config}
=============

All web applications need some degree of configuration information to operate.
The webperl framework uses the ConfigMicro class to load a single global config
file, the information in that file is then used to initialise the rest of the
system - if you use the Application class, the configuration file must include
the information about the database the web application will work with, and
how to map 'internal' table names to the actual names of tables in the database.
