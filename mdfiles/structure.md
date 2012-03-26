Web App Structure                                            {#appstructure}
=================

The framework assumes that a specific files and directories are present in
order to work correctly. Note that you can easily change these if you handle
the initialisation of the various modules in the framework yourself, but if
you use the Application module to handle all the setup for you, you must
follow the structure given in this documentation.

Structure overview
------------------

This diagram shows a typical web application's directory hierarchy. Notes
follow the diagram

![directory structure](filestructure.png)

<dl><dt>blocks</dt>
<dd>Contains subclasses of Block that implement the actual functionality of
your web application. Further subdirectories may be present, if more complex
class hierarchies are needed. See the @ref blocks "Blocks" information for more details.</dd>
</dl>

<dl><dt>config</dt>
<dd>Contains the global site.cfg file, protected by .htaccess. You can easily
place the configuration file outside the web tree if you want, by using the
`config` argument to Application::new(). See the @ref config "Configuration" information for
more about the config file, and how configuration information is stored and
passed to your Block implementations.</dd>
</dl>

<dl><dt>index.cgi</dt>
<dd>The front-end script for the application (or, potentially, one of them).
If you are using the Application class to handle all the framework setup for
you, this will usually contain very little code indeed - potentially only
the 6 lines shown in the Application documentation!</dd>
</dl>

<dl><dt>lang</dt>
<dd>Contains subdirectories containing language files. Each subdirectory should be
a language name, and can contain any number of files that define the language
variables for the template engine. If langauge file handling is disabled in the
template engine, this directory can be omitted.</dd>
</dl>

<dl><dt>modules</dt>
<dd>If you have any application-specific non-Block modules, you may wish to
add them to a separate directory tree for clarity (remember to add `use lib qw(modules)`
to the index.cgi file if you do this). The modules directory can contain any
modules you need, and by calling Modules::add_load_path() you can even use the
dynamic module loading facility to load modules from this directory too.</dd>
</dl>

<dl><dt>templates</dt>
<dd>The templates directory contains the templates for the application, each
set of templates is arranged in its own theme directory - you will generally
need to provide at least the  'default' template directory.</dd>
</dl>
